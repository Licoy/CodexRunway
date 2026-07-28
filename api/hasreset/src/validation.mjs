import {
  derivedRationale,
  EVENT_KINDS,
} from "./event.mjs";

const ERROR_CODES = new Set([
  "configuration_error",
  "request_failed",
  "invalid_response",
  "uncited_source",
]);

export function validateStatus(status) {
  exactObject(status, [
    "schemaVersion",
    "generatedAt",
    "lastSuccessfulCheckAt",
    "monitor",
    "events",
  ], "status");
  if (status.schemaVersion !== 1) {
    throw new Error("status schemaVersion must be 1");
  }
  requireISO(status.generatedAt, "generatedAt");
  if (status.lastSuccessfulCheckAt !== null) {
    requireISO(status.lastSuccessfulCheckAt, "lastSuccessfulCheckAt");
  }
  validateMonitor(status.monitor, status.lastSuccessfulCheckAt);
  validateEvents(status.events);
  return status;
}

function validateMonitor(monitor, lastSuccessfulCheckAt) {
  exactObject(monitor, ["status", "errorCode"], "monitor");
  if (monitor.status === "ok") {
    if (monitor.errorCode !== null || lastSuccessfulCheckAt === null) {
      throw new Error("A healthy monitor requires a successful check and no error");
    }
    return;
  }
  if (monitor.status !== "degraded" || !ERROR_CODES.has(monitor.errorCode)) {
    throw new Error("A degraded monitor requires a supported error code");
  }
}

function validateEvents(events) {
  if (!Array.isArray(events) || events.length > 50) {
    throw new Error("events must be an array with at most 50 entries");
  }
  const seen = new Set();
  let priorSortKey = null;
  for (const event of events) {
    validateEvent(event);
    if (seen.has(event.source.postId)) {
      throw new Error("events must have unique post IDs");
    }
    seen.add(event.source.postId);
    const sortKey = `${event.announcedAt}:${event.source.postId.padStart(30, "0")}`;
    if (priorSortKey !== null && sortKey > priorSortKey) {
      throw new Error("events must be in descending publication order");
    }
    priorSortKey = sortKey;
  }
}

function validateEvent(event) {
  exactObject(event, [
    "kind",
    "announcedAt",
    "effectiveAt",
    "scope",
    "source",
    "confidence",
    "rationale",
  ], "event");
  if (!EVENT_KINDS.has(event.kind)) throw new Error("event kind is unsupported");
  requireISO(event.announcedAt, "event announcedAt");
  validateEffectiveAt(event);
  validateScope(event.scope);
  validateSource(event.source);
  if (
    typeof event.confidence !== "number"
    || !Number.isFinite(event.confidence)
    || event.confidence < 0
    || event.confidence > 1
  ) {
    throw new Error("event confidence must be between zero and one");
  }
  if (event.rationale !== derivedRationale(event.kind)) {
    throw new Error("event rationale must be the derived explanation for its kind");
  }
}

function validateEffectiveAt(event) {
  if (event.kind === "reset_scheduled") {
    requireISO(event.effectiveAt, "scheduled event effectiveAt");
    return;
  }
  if (event.kind === "reset_completed" && event.effectiveAt !== null) {
    requireISO(event.effectiveAt, "completed event effectiveAt");
    return;
  }
  if (event.effectiveAt !== null) {
    throw new Error("event effectiveAt is not allowed for this kind");
  }
}

function validateScope(scope) {
  exactObject(scope, ["plans", "windows"], "event scope");
  requireStringArray(scope.plans, "event plans");
  requireStringArray(scope.windows, "event windows");
}

function validateSource(source) {
  exactObject(source, ["handle", "postId", "url"], "event source");
  if (source.handle !== "thsottiaux" || !/^[0-9]{1,30}$/.test(source.postId)) {
    throw new Error("event source must identify the monitored X account");
  }
  if (source.url !== `https://x.com/thsottiaux/status/${source.postId}`) {
    throw new Error("event source URL must be canonical");
  }
}

function requireStringArray(value, name) {
  if (
    !Array.isArray(value)
    || value.length < 1
    || value.some((item) => typeof item !== "string" || item === "")
  ) {
    throw new Error(`${name} must be a non-empty string array`);
  }
}

function requireISO(value, name) {
  if (typeof value !== "string") {
    throw new Error(`${name} must be an ISO date-time`);
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString() !== value) {
    throw new Error(`${name} must be a canonical ISO date-time`);
  }
}

function exactObject(value, keys, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${name} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error(`${name} has an unexpected shape`);
  }
}
