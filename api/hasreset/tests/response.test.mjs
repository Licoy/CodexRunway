import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { HasResetError, parseGrokResponse } from "../src/index.mjs";

const validResponse = JSON.parse(await readFile(
  new URL("./fixtures/grok-valid.json", import.meta.url),
  "utf8",
));

test("parseGrokResponse publishes cited events in deterministic order", () => {
  const events = parseGrokResponse(validResponse);

  assert.deepEqual(events, [
    {
      kind: "reset_completed",
      announcedAt: "2026-07-28T11:55:00.000Z",
      effectiveAt: null,
      scope: {
        plans: ["all"],
        windows: ["five_hour", "weekly"],
      },
      source: {
        handle: "thsottiaux",
        postId: "200",
        url: "https://x.com/thsottiaux/status/200",
      },
      confidence: 0.98,
      rationale: "Explicit Codex quota reset announcement.",
    },
    {
      kind: "limit_increase",
      announcedAt: "2026-07-27T09:00:00.000Z",
      effectiveAt: null,
      scope: {
        plans: ["all", "pro"],
        windows: ["weekly"],
      },
      source: {
        handle: "thsottiaux",
        postId: "100",
        url: "https://x.com/thsottiaux/status/100",
      },
      confidence: 0.83,
      rationale: "Quota limit increase announcement; not a reset.",
    },
  ]);
});

test("parseGrokResponse rejects an event without a matching X citation", () => {
  const response = structuredClone(validResponse);
  response.citations = ["https://x.com/i/status/999"];

  assert.throws(
    () => parseGrokResponse(response),
    (error) => (
      error instanceof HasResetError
      && error.code === "uncited_source"
    ),
  );
});

test("parseGrokResponse does not accept a matching post ID cited from another handle", () => {
  const response = structuredClone(validResponse);
  response.citations = [
    "https://x.com/someone_else/status/200",
    "https://x.com/thsottiaux/status/100",
  ];

  assert.throws(
    () => parseGrokResponse(response),
    (error) => (
      error instanceof HasResetError
      && error.code === "uncited_source"
    ),
  );
});

test("parseGrokResponse rejects incomplete or malformed structured output", () => {
  const incomplete = structuredClone(validResponse);
  incomplete.status = "in_progress";
  assert.throws(
    () => parseGrokResponse(incomplete),
    (error) => error.code === "invalid_response",
  );

  const malformed = structuredClone(validResponse);
  malformed.output[1].content[0].text = "{\"events\":";
  assert.throws(
    () => parseGrokResponse(malformed),
    (error) => error.code === "invalid_response",
  );
});

test("parseGrokResponse publishes only fixed derived rationale text", () => {
  const response = structuredClone(validResponse);
  const analysis = JSON.parse(response.output[1].content[0].text);
  analysis.events[0].rationale = "Copied source text must not be published.";
  response.output[1].content[0].text = JSON.stringify(analysis);

  assert.throws(
    () => parseGrokResponse(response),
    (error) => error.code === "invalid_response",
  );
});

test("parseGrokResponse accepts a cited completed reset with a distinct effective time", () => {
  const response = structuredClone(validResponse);
  const analysis = JSON.parse(response.output[1].content[0].text);
  analysis.events = [{
    ...analysis.events[1],
    effectiveAt: "2026-07-28T12:00:00Z",
  }];
  response.output[1].content[0].text = JSON.stringify(analysis);

  const [event] = parseGrokResponse(response);
  assert.equal(event.effectiveAt, "2026-07-28T12:00:00.000Z");
});

test("parseGrokResponse requires effectiveAt only for scheduled resets", () => {
  const response = structuredClone(validResponse);
  const analysis = JSON.parse(response.output[1].content[0].text);
  analysis.events = [{
    ...analysis.events[1],
    kind: "reset_scheduled",
    effectiveAt: null,
  }];
  response.output[1].content[0].text = JSON.stringify(analysis);

  assert.throws(
    () => parseGrokResponse(response),
    (error) => error.code === "invalid_response",
  );
});
