import { validateStatus } from "./validation.mjs";

export function decidePublication({
  previousStatus,
  events = [],
  now = new Date(),
  errorCode = null,
  assetsChanged = false,
}) {
  const timestamp = isoTimestamp(now);
  assertErrorCode(errorCode);
  if (previousStatus !== null) validateStatus(previousStatus);
  const mergedEvents = mergeRecentEvents(
    previousStatus?.events ?? [],
    events,
    now,
  );
  const context = {
    previousStatus,
    mergedEvents,
    timestamp,
    errorCode,
    assetsChanged,
  };
  return errorCode === null
    ? decideSuccessfulPublication(context)
    : decideFailedPublication(context);
}

function decideFailedPublication({
  previousStatus,
  timestamp,
  errorCode,
  assetsChanged,
}) {
  if (previousStatus === null) {
    return degradedResult({
      events: [],
      timestamp,
      lastSuccessfulCheckAt: null,
      errorCode,
      publish: true,
      reason: "initial_degraded",
    });
  }
  if (
    !assetsChanged
    && previousStatus.monitor.status === "degraded"
    && previousStatus.monitor.errorCode === errorCode
  ) {
    return {
      status: previousStatus,
      publish: false,
      degraded: true,
      errorCode,
      reason: "repeated_failure",
    };
  }

  return degradedResult({
    events: previousStatus.events,
    timestamp,
    lastSuccessfulCheckAt: previousStatus.lastSuccessfulCheckAt,
    errorCode,
    publish: true,
    reason: failureReason(previousStatus, assetsChanged),
  });
}

function decideSuccessfulPublication({
  previousStatus,
  mergedEvents,
  timestamp,
  assetsChanged,
}) {
  if (previousStatus === null) {
    return healthyResult({ events: mergedEvents, timestamp, reason: "initial_publish" });
  }
  const stableEvents = preserveNonSemanticFields(previousStatus.events, mergedEvents);
  if (previousStatus.monitor.status === "degraded") {
    return healthyResult({
      events: stableEvents,
      timestamp,
      reason: "recovered",
    });
  }
  if (assetsChanged) {
    return healthyResult({
      events: stableEvents,
      timestamp,
      reason: "site_changed",
    });
  }
  if (stableEvents !== previousStatus.events) {
    return healthyResult({
      events: mergedEvents,
      timestamp,
      reason: "events_changed",
    });
  }
  const sameDay = previousStatus.generatedAt.slice(0, 10) === timestamp.slice(0, 10);
  return sameDay
    ? unchangedResult(previousStatus)
    : healthyResult({
      events: previousStatus.events,
      timestamp,
      reason: "daily_heartbeat",
    });
}

function failureReason(previousStatus, assetsChanged) {
  if (assetsChanged) return "site_changed";
  return previousStatus.monitor.status === "ok" ? "degraded" : "degraded_changed";
}

function preserveNonSemanticFields(previousEvents, mergedEvents) {
  return semanticEvents(previousEvents) === semanticEvents(mergedEvents)
    ? previousEvents
    : mergedEvents;
}

function unchangedResult(previousStatus) {
  return {
    status: previousStatus,
    publish: false,
    degraded: false,
    errorCode: null,
    reason: "unchanged",
  };
}

function assertErrorCode(value) {
  const allowed = new Set([
    null,
    "configuration_error",
    "request_failed",
    "invalid_response",
    "uncited_source",
  ]);
  if (!allowed.has(value)) {
    throw new Error("Unsupported monitor error code");
  }
}

function healthyResult({ events, timestamp, reason }) {
  const status = validateStatus({
    schemaVersion: 1,
    generatedAt: timestamp,
    lastSuccessfulCheckAt: timestamp,
    monitor: { status: "ok", errorCode: null },
    events,
  });
  return {
    status,
    publish: true,
    degraded: false,
    errorCode: null,
    reason,
  };
}

function degradedResult({
  events,
  timestamp,
  lastSuccessfulCheckAt,
  errorCode,
  publish,
  reason,
}) {
  const status = validateStatus({
    schemaVersion: 1,
    generatedAt: timestamp,
    lastSuccessfulCheckAt,
    monitor: { status: "degraded", errorCode },
    events,
  });
  return {
    status,
    publish,
    degraded: true,
    errorCode,
    reason,
  };
}

function semanticEvents(events) {
  return JSON.stringify(events.map((event) => ({
    kind: event.kind,
    announcedAt: event.announcedAt,
    effectiveAt: event.effectiveAt,
    scope: event.scope,
    source: event.source,
  })));
}

function mergeRecentEvents(previousEvents, currentEvents, now) {
  const byPostID = new Map();
  for (const event of currentEvents) {
    byPostID.set(event.source.postId, event);
  }

  const cutoff = now.getTime() - (72 * 60 * 60 * 1_000);
  for (const event of previousEvents) {
    if (!byPostID.has(event.source.postId) && shouldRetain(event, cutoff)) {
      byPostID.set(event.source.postId, event);
    }
  }

  return [...byPostID.values()]
    .sort((left, right) => (
      right.announcedAt.localeCompare(left.announcedAt)
      || right.source.postId.padStart(30, "0").localeCompare(
        left.source.postId.padStart(30, "0"),
      )
    ))
    .slice(0, 50);
}

function shouldRetain(event, cutoff) {
  if (Date.parse(event.announcedAt) >= cutoff) return true;
  return event.kind === "reset_scheduled"
    && event.effectiveAt !== null
    && Date.parse(event.effectiveAt) >= cutoff;
}

function isoTimestamp(value) {
  if (!(value instanceof Date) || Number.isNaN(value.getTime())) {
    throw new Error("now must be a valid Date");
  }
  return value.toISOString();
}
