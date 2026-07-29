import assert from "node:assert/strict";
import test from "node:test";

import { classifyStatus } from "../public/status-logic.js";

function feed(event, overrides = {}) {
  return {
    schemaVersion: 1,
    generatedAt: "2026-07-29T10:00:00.000Z",
    lastSuccessfulCheckAt: "2026-07-29T10:00:00.000Z",
    monitor: { status: "ok", errorCode: null },
    events: event ? [event] : [],
    ...overrides,
  };
}

const reset = {
  kind: "reset_completed",
  announcedAt: "2026-07-29T11:00:00.000Z",
  effectiveAt: null,
};

test("classifyStatus reports only already-effective local-day resets as yes", () => {
  assert.equal(
    classifyStatus(
      feed(reset),
      new Date("2026-07-29T12:00:00.000Z"),
    ).state,
    "yes",
  );
  assert.equal(
    classifyStatus(
      feed({
        ...reset,
        kind: "reset_scheduled",
        effectiveAt: "2026-07-29T13:00:00.000Z",
      }),
      new Date("2026-07-29T12:00:00.000Z"),
    ).state,
    "no",
  );
});

test("classifyStatus reports uncertain, degraded, and stale data as unknown", () => {
  assert.equal(
    classifyStatus(
      feed({ ...reset, kind: "uncertain" }),
      new Date("2026-07-29T12:00:00.000Z"),
    ).state,
    "unknown",
  );
  assert.equal(
    classifyStatus(
      feed(null, {
        monitor: { status: "degraded", errorCode: "request_failed" },
      }),
      new Date("2026-07-29T12:00:00.000Z"),
    ).state,
    "unknown",
  );
  assert.equal(
    classifyStatus(
      feed(null, { lastSuccessfulCheckAt: "2026-07-27T00:00:00.000Z" }),
      new Date("2026-07-29T12:00:00.000Z"),
    ).state,
    "unknown",
  );
});

test("classifyStatus prefers a confirmed same-day reset over uncertain commentary", () => {
  const uncertain = {
    ...reset,
    kind: "uncertain",
    announcedAt: "2026-07-29T11:30:00.000Z",
  };
  const value = feed(reset);
  value.events.push(uncertain);

  assert.equal(
    classifyStatus(value, new Date("2026-07-29T12:00:00.000Z")).state,
    "yes",
  );
});

test("classifyStatus reports unknown when only same-day uncertain events exist", () => {
  assert.equal(
    classifyStatus(
      feed({
        kind: "uncertain",
        announcedAt: "2026-07-29T11:30:00.000Z",
        effectiveAt: null,
      }),
      new Date("2026-07-29T12:00:00.000Z"),
    ).state,
    "unknown",
  );
});

test("classifyStatus surfaces the next future scheduled reset when today is not reset", () => {
  const result = classifyStatus(
    feed({
      kind: "reset_scheduled",
      announcedAt: "2026-07-29T05:00:00.000Z",
      effectiveAt: "2026-07-31T12:00:00.000Z",
    }),
    new Date("2026-07-29T12:00:00.000Z"),
  );
  assert.equal(result.state, "no");
  assert.equal(result.reason, "scheduled");
  assert.equal(result.scheduledAt, "2026-07-31T12:00:00.000Z");
});
