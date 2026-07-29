import {
  buildGrokRequest,
  buildWebSocketCreateMessage,
  responsesURL,
  responsesWebSocketURL,
} from "./request.mjs";
import { HasResetError, parseGrokResponse } from "./response.mjs";
import { openWebSocket } from "./websocket.mjs";

const MAX_RESPONSE_BYTES = 1_000_000;

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
  const request = buildGrokRequest({ model: configuration.model, now });

  let payload;
  if (configuration.transport === "websocket") {
    payload = await fetchViaWebSocket({
      url: configuration.wsURL,
      apiKey: configuration.apiKey,
      request,
      timeoutMs: configuration.timeoutMs,
      openWebSocketImpl: configuration.openWebSocketImpl,
    });
  } else {
    payload = await fetchViaHTTP({
      url: configuration.httpURL,
      apiKey: configuration.apiKey,
      request,
      timeoutMs: configuration.timeoutMs,
      fetchImpl: configuration.fetchImpl,
    });
  }

  return filterRecentEvents(parseGrokResponse(payload), now);
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

      // Ignore incremental stream noise; only terminal events matter.
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

      // Some proxies emit the final Responses object without an event envelope.
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
  } catch {
    throw new HasResetError("request_failed", "Grok request failed");
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
  // Keep a 72h announcement window to match the search range. Scheduled
  // effectiveAt may still point further ahead and is retained by merge logic.
  const lowerBound = upperBound - (72 * 60 * 60 * 1_000);
  return events.filter((event) => {
    const announcedAt = Date.parse(event.announcedAt);
    return announcedAt >= lowerBound && announcedAt <= upperBound;
  });
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
