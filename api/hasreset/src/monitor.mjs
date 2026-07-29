import {
  attachCandidateCitations,
  extractDiscoveryCandidates,
  mergeDiscoveryCandidates,
} from "./discovery.mjs";
import {
  buildClassificationRequest,
  buildDiscoveryRequest,
  buildScheduleReplyDiscoveryRequest,
  buildWebSocketCreateMessage,
  responsesURL,
  responsesWebSocketURL,
} from "./request.mjs";
import { HasResetError, parseGrokResponse } from "./response.mjs";
import { openWebSocket } from "./websocket.mjs";

const MAX_RESPONSE_BYTES = 1_500_000;

export async function fetchGrokEvents({
  baseURL,
  model,
  apiKey,
  now = new Date(),
  fetchImpl = globalThis.fetch,
  openWebSocketImpl = openWebSocket,
  transport = "http",
  timeoutMs = 240_000,
}) {
  const configuration = validateConfiguration({
    baseURL,
    model,
    apiKey,
    fetchImpl,
    openWebSocketImpl,
    transport,
    timeoutMs,
  });

  // Two-phase pipeline:
  // 1) Free-form discovery with x_search + web_search (find post IDs)
  // 2) Structured classification without tools (fast, reliable schema)
  const discoveryTimeout = Math.min(configuration.timeoutMs, 120_000);
  const classifyTimeout = Math.min(configuration.timeoutMs, 90_000);

  const discoveryPayload = await executeRequest({
    configuration,
    request: buildDiscoveryRequest({
      model: configuration.model,
      now,
    }),
    timeoutMs: discoveryTimeout,
  });

  let candidates = extractDiscoveryCandidates(discoveryPayload);

  // Main discovery often stops after the big completed-reset post and misses
  // short schedule-decision replies. Always run a focused follow-up; past
  // "feeling like a limit reset" posts must not suppress this pass.
  try {
    const schedulePayload = await executeRequest({
      configuration,
      request: buildScheduleReplyDiscoveryRequest({
        model: configuration.model,
        now,
      }),
      timeoutMs: Math.min(discoveryTimeout, 120_000),
    });
    candidates = mergeDiscoveryCandidates(
      candidates,
      extractDiscoveryCandidates(schedulePayload),
    );
  } catch {
    // Keep primary discovery results if the follow-up search fails.
  }

  // If UTC today still has no completed-reset candidate, run main discovery
  // once more — X/web search recall is flaky on some proxies.
  const today = now.toISOString().slice(0, 10);
  const hasTodayCompletedGuess = candidates.some((candidate) => (
    String(candidate.kindGuess || "").includes("completed")
    && typeof candidate.announcedAt === "string"
    && candidate.announcedAt.startsWith(today)
  )) || candidates.some((candidate) => (
    /i'?ve reset|have been reset|hello people of sol/i.test(candidate.snippet || "")
    && (
      (typeof candidate.announcedAt === "string" && candidate.announcedAt.startsWith(today))
      || !candidate.announcedAt
    )
  ));
  if (!hasTodayCompletedGuess) {
    try {
      const retryPayload = await executeRequest({
        configuration,
        request: buildDiscoveryRequest({
          model: configuration.model,
          now,
        }),
        timeoutMs: Math.min(discoveryTimeout, 120_000),
      });
      candidates = mergeDiscoveryCandidates(
        candidates,
        extractDiscoveryCandidates(retryPayload),
      );
    } catch {
      // ignore retry failure
    }
  }

  if (candidates.length === 0) {
    // Still useful: no monitored posts in the window.
    return [];
  }

  const classificationPayload = await executeRequest({
    configuration,
    request: buildClassificationRequest({
      model: configuration.model,
      now,
      candidates,
    }),
    timeoutMs: classifyTimeout,
  });

  const citedPayload = attachCandidateCitations(classificationPayload, candidates);
  return filterRecentEvents(parseGrokResponse(citedPayload), now);
}

async function executeRequest({ configuration, request, timeoutMs }) {
  if (configuration.transport === "websocket") {
    return fetchViaWebSocket({
      url: configuration.wsURL,
      apiKey: configuration.apiKey,
      request,
      timeoutMs,
      openWebSocketImpl: configuration.openWebSocketImpl,
    });
  }

  try {
    return await fetchViaHTTP({
      url: configuration.httpURL,
      apiKey: configuration.apiKey,
      request,
      timeoutMs,
      fetchImpl: configuration.fetchImpl,
    });
  } catch (error) {
    // Cloudflare/proxy HTTP gateways often 504 or drop long agentic searches;
    // fall back once to WebSocket when a socket implementation is available.
    if (
      error instanceof HasResetError
      && error.code === "request_failed"
      && typeof configuration.openWebSocketImpl === "function"
    ) {
      return fetchViaWebSocket({
        url: configuration.wsURL,
        apiKey: configuration.apiKey,
        request,
        timeoutMs,
        openWebSocketImpl: configuration.openWebSocketImpl,
      });
    }
    throw error;
  }
}

async function fetchViaWebSocket({
  url,
  apiKey,
  request,
  timeoutMs,
  openWebSocketImpl,
}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  let socket;
  try {
    socket = await openWebSocketImpl(url.href, {
      headers: {
        Authorization: `Bearer ${apiKey}`,
      },
      timeoutMs,
      signal: controller.signal,
    });
  } catch (error) {
    clearTimeout(timeout);
    throw new HasResetError(
      "request_failed",
      websocketFailureMessage(error),
    );
  }

  try {
    const payload = await collectWebSocketResponse(socket, request, controller.signal);
    return payload;
  } finally {
    clearTimeout(timeout);
    try {
      socket.close();
    } catch {
      // ignore
    }
  }
}

function collectWebSocketResponse(socket, request, signal) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let completedResponse = null;

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      offMessage();
      offError();
      offClose();
      if (error) reject(error);
      else resolve(value);
    };

    const offMessage = socket.on("message", (raw) => {
      if (typeof raw !== "string") {
        finish(new HasResetError("invalid_response", "Grok WebSocket frame is not text"));
        return;
      }
      if (Buffer.byteLength(raw, "utf8") > MAX_RESPONSE_BYTES) {
        finish(new HasResetError("invalid_response", "Grok response body is too large"));
        return;
      }

      let event;
      try {
        event = JSON.parse(raw);
      } catch {
        finish(new HasResetError("invalid_response", "Grok WebSocket event is not JSON"));
        return;
      }

      if (event?.type === "error") {
        finish(new HasResetError(
          "request_failed",
          websocketEventErrorMessage(event),
        ));
        return;
      }

      if (event?.type === "response.failed") {
        finish(new HasResetError("request_failed", "Grok response failed"));
        return;
      }

      if (event?.type === "response.completed" && event.response) {
        completedResponse = event.response;
        finish(null, event.response);
        return;
      }

      if (
        event
        && typeof event === "object"
        && !event.type
        && (event.status === "completed" || event.status === "complete")
        && Array.isArray(event.output)
      ) {
        completedResponse = event;
        finish(null, event);
      }
    });

    const offError = socket.on("error", () => {
      finish(new HasResetError("request_failed", "Grok WebSocket failed"));
    });

    const offClose = socket.on("close", () => {
      if (settled) return;
      if (completedResponse) {
        finish(null, completedResponse);
        return;
      }
      finish(new HasResetError(
        "request_failed",
        "Grok WebSocket closed before the response completed",
      ));
    });

    if (signal?.aborted) {
      finish(new HasResetError("request_failed", "Grok WebSocket request timed out"));
      return;
    }
    signal?.addEventListener("abort", () => {
      finish(new HasResetError("request_failed", "Grok WebSocket request timed out"));
    }, { once: true });

    try {
      socket.send(JSON.stringify(buildWebSocketCreateMessage(request)));
    } catch {
      finish(new HasResetError("request_failed", "Grok WebSocket send failed"));
    }
  });
}

async function fetchViaHTTP({ url, apiKey, request, timeoutMs, fetchImpl }) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  let response;
  try {
    response = await fetchImpl(url.href, {
      method: "POST",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(request),
      signal: controller.signal,
    });
  } catch (error) {
    const aborted = error?.name === "AbortError" || /aborted|timed out/i.test(String(error?.message || ""));
    throw new HasResetError(
      "request_failed",
      aborted ? "Grok request timed out" : "Grok request failed",
    );
  } finally {
    clearTimeout(timeout);
  }

  if (!response?.ok) {
    const status = Number.isInteger(response?.status)
      ? response.status
      : "an unsuccessful status";
    throw new HasResetError("request_failed", `Grok returned HTTP ${status}`);
  }
  return parseResponseBody(response);
}

function filterRecentEvents(events, now) {
  const upperBound = now.getTime();
  const lowerBound = upperBound - (72 * 60 * 60 * 1_000);
  return events.filter((event) => {
    const announcedAt = Date.parse(event.announcedAt);
    return announcedAt >= lowerBound && announcedAt <= upperBound;
  });
}

export function mergeEventsByPostId(...groups) {
  const byPostID = new Map();
  for (const group of groups) {
    if (!Array.isArray(group)) continue;
    for (const event of group) {
      const postId = event?.source?.postId;
      if (typeof postId !== "string" || postId.length === 0) continue;
      const existing = byPostID.get(postId);
      if (!existing || preferEvent(event, existing)) {
        byPostID.set(postId, event);
      }
    }
  }
  return [...byPostID.values()].sort((left, right) => (
    right.announcedAt.localeCompare(left.announcedAt)
    || right.source.postId.padStart(30, "0").localeCompare(
      left.source.postId.padStart(30, "0"),
    )
  ));
}

export function needsFullWindowBackfill(events, now = new Date()) {
  if (!Array.isArray(events) || events.length === 0) return true;
  const today = now.toISOString().slice(0, 10);
  return !events.some((event) => (
    event?.kind === "reset_completed"
    && typeof event.announcedAt === "string"
    && event.announcedAt.slice(0, 10) === today
  ));
}

function preferEvent(candidate, existing) {
  const kindScore = (kind) => ({
    reset_completed: 5,
    reset_scheduled: 4,
    banked_reset: 3,
    limit_increase: 2,
    uncertain: 1,
  }[kind] ?? 0);
  const kindDelta = kindScore(candidate.kind) - kindScore(existing.kind);
  if (kindDelta !== 0) return kindDelta > 0;
  if (candidate.confidence !== existing.confidence) {
    return candidate.confidence > existing.confidence;
  }
  return candidate.announcedAt.localeCompare(existing.announcedAt) > 0;
}

function validateConfiguration({
  baseURL,
  model,
  apiKey,
  fetchImpl,
  openWebSocketImpl,
  transport,
  timeoutMs,
}) {
  if (typeof apiKey !== "string" || apiKey.trim() === "") {
    throw new HasResetError("configuration_error", "GROK_API_KEY is required");
  }
  if (typeof model !== "string" || model.trim() === "") {
    throw new HasResetError("configuration_error", "GROK_MODEL is required");
  }
  if (transport !== "websocket" && transport !== "http") {
    throw new HasResetError("configuration_error", "Unsupported Grok transport");
  }
  if (transport === "http" && typeof fetchImpl !== "function") {
    throw new HasResetError("configuration_error", "A fetch implementation is required");
  }
  if (transport === "websocket" && typeof openWebSocketImpl !== "function") {
    throw new HasResetError("configuration_error", "A WebSocket implementation is required");
  }
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 240_000) {
    throw new HasResetError("configuration_error", "The request timeout is invalid");
  }
  let httpURL;
  let wsURL;
  try {
    httpURL = responsesURL(baseURL);
    wsURL = responsesWebSocketURL(baseURL);
  } catch {
    throw new HasResetError("configuration_error", "GROK_API_BASE_URL is invalid");
  }
  return {
    httpURL,
    wsURL,
    model: model.trim(),
    apiKey,
    fetchImpl,
    openWebSocketImpl,
    transport,
    timeoutMs,
  };
}

async function parseResponseBody(response) {
  let text;
  try {
    text = await response.text();
  } catch {
    throw new HasResetError("invalid_response", "Grok response body could not be read");
  }
  if (Buffer.byteLength(text, "utf8") > MAX_RESPONSE_BYTES) {
    throw new HasResetError("invalid_response", "Grok response body is too large");
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new HasResetError("invalid_response", "Grok response body is not JSON");
  }
}

function websocketFailureMessage(error) {
  const message = typeof error?.message === "string" ? error.message : "";
  if (/HTTP \d{3}/.test(message)) {
    return `Grok WebSocket upgrade failed (${message.match(/HTTP \d{3}/)[0]})`;
  }
  if (/timed out|aborted/i.test(message)) {
    return "Grok WebSocket request timed out";
  }
  return "Grok WebSocket request failed";
}

function websocketEventErrorMessage(event) {
  const code = event?.error?.code || event?.status;
  if (code) return `Grok WebSocket error (${code})`;
  return "Grok WebSocket error";
}
