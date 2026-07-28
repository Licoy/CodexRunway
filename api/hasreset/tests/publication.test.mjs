import assert from "node:assert/strict";
import test from "node:test";

import { decidePublication } from "../src/index.mjs";

const resetEvent = {
  kind: "reset_completed",
  announcedAt: "2026-07-28T11:55:00.000Z",
  effectiveAt: null,
  scope: { plans: ["all"], windows: ["five_hour", "weekly"] },
  source: {
    handle: "thsottiaux",
    postId: "200",
    url: "https://x.com/thsottiaux/status/200",
  },
  confidence: 0.98,
  rationale: "Explicit Codex quota reset announcement.",
};

test("decidePublication creates a healthy feed on the first successful check", () => {
  const result = decidePublication({
    previousStatus: null,
    events: [resetEvent],
    now: new Date("2026-07-28T12:00:00.000Z"),
  });

  assert.equal(result.publish, true);
  assert.equal(result.degraded, false);
  assert.equal(result.errorCode, null);
  assert.equal(result.reason, "initial_publish");
  assert.deepEqual(result.status, {
    schemaVersion: 1,
    generatedAt: "2026-07-28T12:00:00.000Z",
    lastSuccessfulCheckAt: "2026-07-28T12:00:00.000Z",
    monitor: { status: "ok", errorCode: null },
    events: [resetEvent],
  });
});

test("decidePublication does not publish same-day confidence changes", () => {
  const previousStatus = {
    schemaVersion: 1,
    generatedAt: "2026-07-28T10:00:00.000Z",
    lastSuccessfulCheckAt: "2026-07-28T10:00:00.000Z",
    monitor: { status: "ok", errorCode: null },
    events: [resetEvent],
  };
  const nextEvent = {
    ...resetEvent,
    confidence: 0.91,
  };

  const result = decidePublication({
    previousStatus,
    events: [nextEvent],
    now: new Date("2026-07-28T12:00:00.000Z"),
  });

  assert.equal(result.publish, false);
  assert.equal(result.reason, "unchanged");
  assert.deepEqual(result.status, previousStatus);
});

test("decidePublication publishes at most one successful heartbeat per UTC day", () => {
  const previousStatus = {
    schemaVersion: 1,
    generatedAt: "2026-07-28T23:17:00.000Z",
    lastSuccessfulCheckAt: "2026-07-28T23:17:00.000Z",
    monitor: { status: "ok", errorCode: null },
    events: [resetEvent],
  };

  const result = decidePublication({
    previousStatus,
    events: [{ ...resetEvent, confidence: 0.91 }],
    now: new Date("2026-07-29T00:17:00.000Z"),
  });

  assert.equal(result.publish, true);
  assert.equal(result.reason, "daily_heartbeat");
  assert.equal(result.status.generatedAt, "2026-07-29T00:17:00.000Z");
  assert.equal(result.status.lastSuccessfulCheckAt, "2026-07-29T00:17:00.000Z");
  assert.deepEqual(result.status.events, [resetEvent]);
});

test("decidePublication publishes semantic changes while retaining recent events", () => {
  const previousStatus = {
    schemaVersion: 1,
    generatedAt: "2026-07-29T00:17:00.000Z",
    lastSuccessfulCheckAt: "2026-07-29T00:17:00.000Z",
    monitor: { status: "ok", errorCode: null },
    events: [resetEvent],
  };
  const scheduledEvent = {
    ...resetEvent,
    kind: "reset_scheduled",
    announcedAt: "2026-07-29T00:45:00.000Z",
    effectiveAt: "2026-07-29T02:00:00.000Z",
    source: {
      ...resetEvent.source,
      postId: "300",
      url: "https://x.com/thsottiaux/status/300",
    },
    rationale: "Explicit Codex quota reset schedule.",
  };

  const result = decidePublication({
    previousStatus,
    events: [scheduledEvent],
    now: new Date("2026-07-29T01:17:00.000Z"),
  });

  assert.equal(result.publish, true);
  assert.equal(result.reason, "events_changed");
  assert.deepEqual(result.status.events, [scheduledEvent, resetEvent]);
});

test("decidePublication publishes a safe degraded feed for a first-run failure", () => {
  const result = decidePublication({
    previousStatus: null,
    events: [],
    now: new Date("2026-07-29T01:17:00.000Z"),
    errorCode: "configuration_error",
  });

  assert.equal(result.publish, true);
  assert.equal(result.degraded, true);
  assert.equal(result.errorCode, "configuration_error");
  assert.equal(result.reason, "initial_degraded");
  assert.deepEqual(result.status, {
    schemaVersion: 1,
    generatedAt: "2026-07-29T01:17:00.000Z",
    lastSuccessfulCheckAt: null,
    monitor: {
      status: "degraded",
      errorCode: "configuration_error",
    },
    events: [],
  });
});

test("decidePublication does not publish repeated identical failures", () => {
  const previousStatus = {
    schemaVersion: 1,
    generatedAt: "2026-07-28T12:17:00.000Z",
    lastSuccessfulCheckAt: "2026-07-28T11:17:00.000Z",
    monitor: {
      status: "degraded",
      errorCode: "request_failed",
    },
    events: [resetEvent],
  };

  const result = decidePublication({
    previousStatus,
    events: [],
    now: new Date("2026-07-29T12:17:00.000Z"),
    errorCode: "request_failed",
  });

  assert.equal(result.publish, false);
  assert.equal(result.degraded, true);
  assert.equal(result.reason, "repeated_failure");
  assert.deepEqual(result.status, previousStatus);
});

test("decidePublication preserves the last good data when health degrades", () => {
  const previousStatus = {
    schemaVersion: 1,
    generatedAt: "2026-07-29T10:17:00.000Z",
    lastSuccessfulCheckAt: "2026-07-29T10:17:00.000Z",
    monitor: { status: "ok", errorCode: null },
    events: [resetEvent],
  };

  const result = decidePublication({
    previousStatus,
    events: [],
    now: new Date("2026-07-29T11:17:00.000Z"),
    errorCode: "invalid_response",
  });

  assert.equal(result.publish, true);
  assert.equal(result.degraded, true);
  assert.equal(result.reason, "degraded");
  assert.deepEqual(result.status, {
    ...previousStatus,
    generatedAt: "2026-07-29T11:17:00.000Z",
    monitor: {
      status: "degraded",
      errorCode: "invalid_response",
    },
  });
});

test("decidePublication publishes recovery after a degraded check", () => {
  const previousStatus = {
    schemaVersion: 1,
    generatedAt: "2026-07-29T11:17:00.000Z",
    lastSuccessfulCheckAt: "2026-07-29T10:17:00.000Z",
    monitor: {
      status: "degraded",
      errorCode: "request_failed",
    },
    events: [resetEvent],
  };

  const result = decidePublication({
    previousStatus,
    events: [{ ...resetEvent, confidence: 0.91 }],
    now: new Date("2026-07-29T12:17:00.000Z"),
  });

  assert.equal(result.publish, true);
  assert.equal(result.degraded, false);
  assert.equal(result.reason, "recovered");
  assert.equal(result.status.monitor.status, "ok");
  assert.equal(result.status.lastSuccessfulCheckAt, "2026-07-29T12:17:00.000Z");
  assert.deepEqual(result.status.events, [resetEvent]);
});

test("decidePublication republishes an otherwise unchanged feed when site assets change", () => {
  const previousStatus = {
    schemaVersion: 1,
    generatedAt: "2026-07-29T10:17:00.000Z",
    lastSuccessfulCheckAt: "2026-07-29T10:17:00.000Z",
    monitor: { status: "ok", errorCode: null },
    events: [resetEvent],
  };

  const result = decidePublication({
    previousStatus,
    events: [{ ...resetEvent, confidence: 0.91 }],
    now: new Date("2026-07-29T12:17:00.000Z"),
    assetsChanged: true,
  });

  assert.equal(result.publish, true);
  assert.equal(result.reason, "site_changed");
  assert.deepEqual(result.status.events, [resetEvent]);
  assert.equal(result.status.lastSuccessfulCheckAt, "2026-07-29T12:17:00.000Z");
});

test("decidePublication expires retained events after the 48-hour window", () => {
  const oldEvent = {
    ...resetEvent,
    announcedAt: "2026-07-26T10:00:00.000Z",
  };
  const previousStatus = {
    schemaVersion: 1,
    generatedAt: "2026-07-29T10:17:00.000Z",
    lastSuccessfulCheckAt: "2026-07-29T10:17:00.000Z",
    monitor: { status: "ok", errorCode: null },
    events: [oldEvent],
  };

  const result = decidePublication({
    previousStatus,
    events: [],
    now: new Date("2026-07-29T12:17:00.000Z"),
  });

  assert.equal(result.publish, true);
  assert.equal(result.reason, "events_changed");
  assert.deepEqual(result.status.events, []);
});

test("decidePublication retains an older scheduled event through its effective window", () => {
  const scheduledEvent = {
    ...resetEvent,
    kind: "reset_scheduled",
    announcedAt: "2026-07-25T12:00:00.000Z",
    effectiveAt: "2026-07-29T13:00:00.000Z",
    rationale: "Explicit Codex quota reset schedule.",
  };
  const previousStatus = {
    schemaVersion: 1,
    generatedAt: "2026-07-29T10:17:00.000Z",
    lastSuccessfulCheckAt: "2026-07-29T10:17:00.000Z",
    monitor: { status: "ok", errorCode: null },
    events: [scheduledEvent],
  };

  const result = decidePublication({
    previousStatus,
    events: [],
    now: new Date("2026-07-29T12:17:00.000Z"),
  });

  assert.equal(result.publish, false);
  assert.equal(result.reason, "unchanged");
  assert.deepEqual(result.status.events, [scheduledEvent]);
});

test("decidePublication publishes when the degraded error category changes", () => {
  const previousStatus = {
    schemaVersion: 1,
    generatedAt: "2026-07-29T10:17:00.000Z",
    lastSuccessfulCheckAt: "2026-07-29T09:17:00.000Z",
    monitor: { status: "degraded", errorCode: "request_failed" },
    events: [resetEvent],
  };

  const result = decidePublication({
    previousStatus,
    events: [],
    now: new Date("2026-07-29T11:17:00.000Z"),
    errorCode: "invalid_response",
  });

  assert.equal(result.publish, true);
  assert.equal(result.reason, "degraded_changed");
  assert.equal(result.status.monitor.errorCode, "invalid_response");
});
