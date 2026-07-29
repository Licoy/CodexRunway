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
  "x_keyword_search",
  "x_semantic_search",
  "x_user_search",
  "x_thread_fetch",
]);

export class HasResetError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "HasResetError";
    this.code = code;
  }
}

export function parseGrokResponse(response) {
  if (response?.status !== "completed") {
    invalid("Grok response did not complete");
  }
  const output = requireArray(response?.output, "response output");
  const content = findOutputText(output);
  const searchEvidence = assertCompletedXSearch(response, output, content);
  const analysis = parseAnalysis(content.text);
  const citedPostIds = collectCitedPostIds(response, content);

  const seen = new Set();
  const events = analysis.events.map((event) => {
    const normalized = normalizeEvent(event);
    if (seen.has(normalized.source.postId)) {
      invalid("Grok returned the same X post more than once");
    }
    seen.add(normalized.source.postId);
    if (!citedPostIds.has(normalized.source.postId)) {
      throw new HasResetError(
        "uncited_source",
        "Grok returned an event without a matching X citation",
      );
    }
    if (
      searchEvidence === "cited_proxy"
      && !hasExplicitMonitoredCitation(response, content, normalized.source.postId)
    ) {
      throw new HasResetError(
        "uncited_source",
        "Proxy response did not cite the monitored X account for this event",
      );
    }
    return normalized;
  });

  return events.sort(compareEvents);
}

function assertCompletedXSearch(response, output, content) {
  const officialCalls = output.filter((item) => item?.type === "x_search_call");
  const compatibleCalls = output.filter((item) => item?.type === "custom_tool_call");
  if (output.some(isUnsupportedToolCall)) {
    invalid("Grok returned an unsupported tool call");
  }
  if (officialCalls.length > 0 && compatibleCalls.length > 0) {
    invalid("Grok returned mixed X Search call formats");
  }
  if (officialCalls.length > 0) {
    if (officialCalls.length > 2) {
      invalid("Grok must complete one or two X Search calls");
    }
    assertCallsCompleted(officialCalls);
    return "tool_call";
  }

  if (
    compatibleCalls.length > 0
    && compatibleCalls.some((call) => !COMPATIBLE_X_SEARCH_TOOLS.has(call?.name))
  ) {
    invalid("Grok must complete one or two X Search calls");
  }
  if (compatibleCalls.length > 0) {
    assertCallsCompleted(compatibleCalls);
    return "tool_call";
  }
  if (hasCitedProxySearchEvidence(response, output, content)) {
    return "cited_proxy";
  }
  invalid("Grok must complete X Search or return cited proxy search evidence");
}

function isUnsupportedToolCall(item) {
  return typeof item?.type === "string"
    && item.type.endsWith("_call")
    && item.type !== "x_search_call"
    && item.type !== "custom_tool_call";
}

function assertCallsCompleted(calls) {
  if (calls.some((call) => call.status !== "completed")) {
    invalid("Grok did not complete X Search");
  }
}

function hasCitedProxySearchEvidence(response, output, content) {
  const completedReasoning = output.some((item) => (
    item?.type === "reasoning" && item.status === "completed"
  ));
  return completedReasoning && citationURLs(response, content).some((url) => {
    const parsed = parseXURL(url);
    return parsed?.handle === "thsottiaux";
  });
}

function hasExplicitMonitoredCitation(response, content, postId) {
  return citationURLs(response, content).some((url) => {
    const parsed = parseXURL(url);
    return parsed?.handle === "thsottiaux" && parsed.postId === postId;
  });
}

function findOutputText(output) {
  const blocks = output.flatMap((item) => (
    item?.type === "message" && Array.isArray(item.content)
      ? item.content.filter((content) => content?.type === "output_text")
      : []
  ));
  if (blocks.length !== 1 || typeof blocks[0].text !== "string") {
    invalid("Grok response must contain exactly one output_text block");
  }
  return blocks[0];
}

function parseAnalysis(text) {
  let analysis;
  try {
    analysis = JSON.parse(text);
  } catch {
    invalid("Grok output_text is not valid JSON");
  }
  requireExactKeys(analysis, ["events"], "analysis");
  requireArray(analysis.events, "analysis events");
  if (analysis.events.length > 20) {
    invalid("Grok returned too many events");
  }
  return analysis;
}

function normalizeEvent(event) {
  requireExactKeys(event, [
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
  return [
    ...(Array.isArray(response?.citations) ? response.citations : []),
    ...(Array.isArray(outputText.annotations)
      ? outputText.annotations.map((annotation) => annotation?.url)
      : []),
  ];
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

function requireExactKeys(value, keys, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    invalid(`${name} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    invalid(`${name} has an unexpected shape`);
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
