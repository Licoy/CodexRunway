import {
  derivedRationale,
  EVENT_KINDS,
} from "./event.mjs";

const PLAN_NAMES = new Set([
  "all",
  "free",
  "plus",
  "pro",
  "team",
  "business",
  "enterprise",
  "unknown",
]);
const WINDOW_NAMES = new Set(["weekly", "five_hour", "unknown"]);
const COMPATIBLE_X_SEARCH_TOOLS = new Set([
  "x_search",
  "x_keyword_search",
  "x_semantic_search",
  "x_user_search",
  "x_thread_fetch",
]);
const COMPATIBLE_TOOL_CALL_TYPES = new Set([
  "custom_tool_call",
  "function_call",
  "tool_call",
]);
const MAX_SEARCH_CALLS = 16;

export class HasResetError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "HasResetError";
    this.code = code;
  }
}

export function parseGrokResponse(response) {
  if (!isCompletedStatus(response?.status)) {
    invalid("Grok response did not complete");
  }
  const output = requireArray(response?.output, "response output");
  const content = findOutputText(output);
  const analysis = parseAnalysis(content.text);
  const searchEvidence = assertSearchEvidence(response, output, content, analysis);
  const citedPostIds = collectCitedPostIds(response, content);

  const seen = new Set();
  const events = analysis.events.map((event) => {
    const normalized = normalizeEvent(event);
    if (seen.has(normalized.source.postId)) {
      invalid("Grok returned the same X post more than once");
    }
    seen.add(normalized.source.postId);
    assertEventCitation(normalized, citedPostIds);
    return normalized;
  });

  return events.sort(compareEvents);
}

function assertSearchEvidence(response, output, content, analysis) {
  const officialCalls = output.filter((item) => item?.type === "x_search_call");
  const compatibleCalls = output.filter((item) => (
    COMPATIBLE_TOOL_CALL_TYPES.has(item?.type)
    && COMPATIBLE_X_SEARCH_TOOLS.has(toolCallName(item))
  ));
  if (output.some(isUnsupportedToolCall)) {
    invalid("Grok returned an unsupported tool call");
  }
  if (officialCalls.length > 0 && compatibleCalls.length > 0) {
    invalid("Grok returned mixed X Search call formats");
  }
  if (officialCalls.length > 0) {
    if (officialCalls.length > MAX_SEARCH_CALLS) {
      invalid("Grok returned too many X Search calls");
    }
    assertCallsCompleted(officialCalls);
    return "tool_call";
  }
  if (compatibleCalls.length > 0) {
    if (compatibleCalls.length > MAX_SEARCH_CALLS) {
      invalid("Grok returned too many X Search calls");
    }
    assertCallsCompleted(compatibleCalls);
    return "tool_call";
  }
  if (hasCitedProxySearchEvidence(response, content)) {
    return "cited_proxy";
  }
  // Standard / proxy Responses APIs often omit tool-call records after executing
  // server-side X Search. An empty result is still useful: no monitored posts.
  if (analysis.events.length === 0) {
    return "empty_proxy";
  }
  invalid("Grok must complete X Search or return cited proxy search evidence");
}

function assertEventCitation(event, citedPostIds) {
  // Official xAI and compatible proxies often cite posts as x.com/i/status/<id>.
  // Event sourceUrl already enforces thsottiaux|i + matching postId.
  if (citedPostIds.has(event.source.postId)) {
    return;
  }

  throw new HasResetError(
    "uncited_source",
    "Grok returned an event without a matching X citation",
  );
}

function isUnsupportedToolCall(item) {
  if (typeof item?.type !== "string" || !item.type.endsWith("_call")) {
    return false;
  }
  if (item.type === "x_search_call") {
    return false;
  }
  if (COMPATIBLE_TOOL_CALL_TYPES.has(item.type)) {
    return !COMPATIBLE_X_SEARCH_TOOLS.has(toolCallName(item));
  }
  return true;
}

function toolCallName(item) {
  if (typeof item?.name === "string") return item.name;
  if (typeof item?.function?.name === "string") return item.function.name;
  return "";
}

function assertCallsCompleted(calls) {
  // Official Responses items may omit status on finished server-side tools.
  // Only reject when a status is present and not completed.
  if (calls.some((call) => call.status && !isCompletedStatus(call.status))) {
    invalid("Grok did not complete X Search");
  }
}

function isCompletedStatus(status) {
  return status === "completed" || status === "complete";
}

function hasCitedProxySearchEvidence(response, content) {
  // Proxies frequently omit x_search_call records and only attach X status URLs
  // as annotations (often under the anonymous /i/status/<id> form).
  return citationURLs(response, content).some((url) => {
    const parsed = parseXURL(url);
    return parsed && ["thsottiaux", "i"].includes(parsed.handle);
  });
}

function findOutputText(output) {
  const blocks = output.flatMap((item) => {
    if (item?.type !== "message") return [];
    if (Array.isArray(item.content)) {
      return item.content.filter((content) => (
        content?.type === "output_text" && typeof content.text === "string"
      ));
    }
    // Some OpenAI-compatible proxies flatten message content to a string.
    if (typeof item.content === "string") {
      return [{ type: "output_text", text: item.content, annotations: item.annotations }];
    }
    return [];
  });
  if (blocks.length < 1) {
    invalid("Grok response must contain an output_text block");
  }
  // Prefer the final assistant text when proxies stream intermediate JSON drafts.
  return blocks.at(-1);
}

function parseAnalysis(text) {
  const payload = extractJSONObject(text);
  let analysis;
  try {
    analysis = JSON.parse(payload);
  } catch {
    invalid("Grok output_text is not valid JSON");
  }
  requireKeys(analysis, ["events"], "analysis");
  requireArray(analysis.events, "analysis events");
  if (analysis.events.length > 20) {
    invalid("Grok returned too many events");
  }
  return analysis;
}

function extractJSONObject(text) {
  if (typeof text !== "string") {
    invalid("Grok output_text is not valid JSON");
  }
  const trimmed = text.trim();
  if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
    return trimmed;
  }
  // Structured output occasionally arrives wrapped in a markdown fence.
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)\s*```/i);
  if (fenced?.[1]) {
    return fenced[1].trim();
  }
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start >= 0 && end > start) {
    return trimmed.slice(start, end + 1);
  }
  invalid("Grok output_text is not valid JSON");
}

function normalizeEvent(event) {
  requireKeys(event, [
    "kind",
    "announcedAt",
    "effectiveAt",
    "plans",
    "windows",
    "postId",
    "sourceUrl",
    "confidence",
  ], "event");

  const kind = normalizeEventKind(event);
  const announcedAt = normalizeDate(event.announcedAt, "announcedAt");
  const effectiveAt = normalizeEffectiveAt(event, kind);
  const postId = normalizePostId(event.postId);
  validateSourceURL(event.sourceUrl, postId);
  const confidence = normalizeConfidence(event.confidence);

  return {
    kind,
    announcedAt,
    effectiveAt,
    scope: {
      plans: normalizeStringSet(event.plans, PLAN_NAMES, "plans"),
      windows: normalizeStringSet(event.windows, WINDOW_NAMES, "windows"),
    },
    source: {
      handle: "thsottiaux",
      postId,
      url: `https://x.com/thsottiaux/status/${postId}`,
    },
    confidence,
    rationale: derivedRationale(kind),
  };
}

function normalizeEventKind(event) {
  if (!EVENT_KINDS.has(event.kind)) {
    invalid("Grok returned an unsupported event kind");
  }
  return event.kind === "reset_scheduled" && event.effectiveAt === null
    ? "uncertain"
    : event.kind;
}

function normalizeEffectiveAt(event, kind) {
  if (kind === "reset_scheduled") {
    return normalizeDate(event.effectiveAt, "effectiveAt");
  }
  if (kind === "reset_completed") {
    return event.effectiveAt === null
      ? null
      : normalizeDate(event.effectiveAt, "effectiveAt");
  }
  if (event.effectiveAt !== null) {
    invalid("This event kind must not have an effectiveAt time");
  }
  return null;
}

function normalizeDate(value, name) {
  if (typeof value !== "string") {
    invalid(`${name} must be an ISO date-time`);
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    invalid(`${name} must be an ISO date-time`);
  }
  return date.toISOString();
}

function normalizePostId(value) {
  if (typeof value === "number" && Number.isInteger(value) && value >= 0) {
    value = String(value);
  }
  if (typeof value !== "string" || !/^[0-9]{1,30}$/.test(value)) {
    invalid("postId must contain only digits");
  }
  return value;
}

function validateSourceURL(value, postId) {
  const parsed = parseXURL(value);
  if (!parsed || parsed.postId !== postId) {
    throw new HasResetError(
      "uncited_source",
      "Grok source URL does not match its X post ID",
    );
  }
  if (parsed.handle !== "thsottiaux" && parsed.handle !== "i") {
    throw new HasResetError(
      "uncited_source",
      "Grok source URL is not from the monitored X account",
    );
  }
}

function normalizeConfidence(value) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1) {
    invalid("confidence must be between zero and one");
  }
  return value;
}

function normalizeStringSet(value, allowed, name) {
  const values = requireArray(value, name);
  if (values.length < 1 || values.some((item) => !allowed.has(item))) {
    invalid(`${name} contains an unsupported value`);
  }
  return [...new Set(values)].sort();
}

function collectCitedPostIds(response, outputText) {
  return new Set(
    citationURLs(response, outputText)
      .map(parseXURL)
      .filter((item) => item && ["thsottiaux", "i"].includes(item.handle))
      .map((item) => item.postId),
  );
}

function citationURLs(response, outputText) {
  const urls = [];
  for (const value of [
    ...(Array.isArray(response?.citations) ? response.citations : []),
    ...(Array.isArray(response?.sources) ? response.sources : []),
  ]) {
    const url = citationURLValue(value);
    if (url) urls.push(url);
  }
  if (Array.isArray(outputText?.annotations)) {
    for (const annotation of outputText.annotations) {
      const url = citationURLValue(annotation);
      if (url) urls.push(url);
    }
  }
  return urls;
}

function citationURLValue(value) {
  if (typeof value === "string") return value;
  if (!value || typeof value !== "object") return null;
  if (typeof value.url === "string") return value.url;
  if (typeof value.uri === "string") return value.uri;
  if (typeof value.href === "string") return value.href;
  return null;
}

function parseXURL(value) {
  if (typeof value !== "string") return null;
  try {
    const parsed = new URL(value);
    const host = parsed.hostname.toLowerCase().replace(/^www\./, "");
    if (!["x.com", "twitter.com"].includes(host)) return null;
    const match = parsed.pathname.match(/^\/([^/]+)\/status\/([0-9]{1,30})(?:\/|$)/i);
    if (!match) return null;
    return { handle: match[1].toLowerCase(), postId: match[2] };
  } catch {
    return null;
  }
}

function requireKeys(value, keys, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    invalid(`${name} must be an object`);
  }
  for (const key of keys) {
    if (!Object.hasOwn(value, key)) {
      invalid(`${name} is missing required field ${key}`);
    }
  }
}

function requireArray(value, name) {
  if (!Array.isArray(value)) invalid(`${name} must be an array`);
  return value;
}

function compareEvents(left, right) {
  return right.announcedAt.localeCompare(left.announcedAt)
    || right.source.postId.padStart(30, "0").localeCompare(
      left.source.postId.padStart(30, "0"),
    );
}

function invalid(message) {
  throw new HasResetError("invalid_response", message);
}
