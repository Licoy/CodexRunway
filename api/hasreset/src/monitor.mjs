import { buildGrokRequest, responsesURL } from "./request.mjs";
import { HasResetError, parseGrokResponse } from "./response.mjs";

const MAX_RESPONSE_BYTES = 1_000_000;

export async function fetchGrokEvents({
  baseURL,
  model,
  apiKey,
  now = new Date(),
  fetchImpl = globalThis.fetch,
  timeoutMs = 240_000,
}) {
  const configuration = validateConfiguration({
    baseURL,
    model,
    apiKey,
    fetchImpl,
    timeoutMs,
  });
  const request = buildGrokRequest({ model: configuration.model, now });
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), configuration.timeoutMs);

  let response;
  try {
    response = await configuration.fetchImpl(configuration.url.href, {
      method: "POST",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${configuration.apiKey}`,
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
    throw new HasResetError("request_failed", "Grok returned an unsuccessful response");
  }
  const payload = await parseResponseBody(response);
  return filterRecentEvents(parseGrokResponse(payload), now);
}

function filterRecentEvents(events, now) {
  const upperBound = now.getTime();
  const lowerBound = upperBound - (48 * 60 * 60 * 1_000);
  return events.filter((event) => {
    const announcedAt = Date.parse(event.announcedAt);
    return announcedAt >= lowerBound && announcedAt <= upperBound;
  });
}

function validateConfiguration({ baseURL, model, apiKey, fetchImpl, timeoutMs }) {
  if (typeof apiKey !== "string" || apiKey.trim() === "") {
    throw new HasResetError("configuration_error", "GROK_API_KEY is required");
  }
  if (typeof model !== "string" || model.trim() === "") {
    throw new HasResetError("configuration_error", "GROK_MODEL is required");
  }
  if (typeof fetchImpl !== "function") {
    throw new HasResetError("configuration_error", "A fetch implementation is required");
  }
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 240_000) {
    throw new HasResetError("configuration_error", "The request timeout is invalid");
  }
  let url;
  try {
    url = responsesURL(baseURL);
  } catch {
    throw new HasResetError("configuration_error", "GROK_API_BASE_URL is invalid");
  }
  return { url, model: model.trim(), apiKey, fetchImpl, timeoutMs };
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
