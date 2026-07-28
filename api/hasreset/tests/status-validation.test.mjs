import assert from "node:assert/strict";
import test from "node:test";

import { validateStatus } from "../src/index.mjs";

const validStatus = {
  schemaVersion: 1,
  generatedAt: "2026-07-29T12:17:00.000Z",
  lastSuccessfulCheckAt: "2026-07-29T12:17:00.000Z",
  monitor: { status: "ok", errorCode: null },
  events: [{
    kind: "reset_completed",
    announcedAt: "2026-07-29T11:55:00.000Z",
    effectiveAt: null,
    scope: { plans: ["all"], windows: ["weekly"] },
    source: {
      handle: "thsottiaux",
      postId: "200",
      url: "https://x.com/thsottiaux/status/200",
    },
    confidence: 0.98,
    rationale: "Explicit Codex quota reset announcement.",
  }],
};

test("validateStatus accepts the complete public v1 contract", () => {
  assert.equal(validateStatus(validStatus), validStatus);
});

test("validateStatus rejects inconsistent health and unsafe event sources", () => {
  assert.throws(
    () => validateStatus({
      ...validStatus,
      monitor: { status: "ok", errorCode: "request_failed" },
    }),
    /healthy monitor/,
  );
  assert.throws(
    () => validateStatus({
      ...validStatus,
      events: [{
        ...validStatus.events[0],
        source: {
          ...validStatus.events[0].source,
          url: "https://example.com/status/200",
        },
      }],
    }),
    /canonical/,
  );
  assert.throws(
    () => validateStatus({
      ...validStatus,
      events: [{
        ...validStatus.events[0],
        rationale: "Source text must never be copied into this field.",
      }],
    }),
    /derived explanation/,
  );
});
