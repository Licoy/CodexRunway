import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { fetchGrokEvents, HasResetError } from "../src/index.mjs";

const validResponse = JSON.parse(await readFile(
  new URL("./fixtures/grok-valid.json", import.meta.url),
  "utf8",
));

test("fetchGrokEvents performs exactly one authenticated Responses API request", async () => {
  const requests = [];
  const fetchImpl = async (url, options) => {
    requests.push({ url, options });
    return new Response(JSON.stringify(validResponse), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-28T12:00:00.000Z"),
    fetchImpl,
    timeoutMs: 1_000,
  });

  assert.equal(events.length, 2);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, "https://api.x.ai/v1/responses");
  assert.equal(requests[0].options.method, "POST");
  assert.equal(requests[0].options.headers.Authorization, "Bearer test-secret");
  assert.equal(JSON.parse(requests[0].options.body).max_tool_calls, 2);
});

test("fetchGrokEvents does not retry a failed request", async () => {
  let callCount = 0;
  const fetchImpl = async () => {
    callCount += 1;
    throw new Error("fixture network failure");
  };

  await assert.rejects(
    fetchGrokEvents({
      baseURL: "https://api.x.ai/v1",
      model: "grok-4.5",
      apiKey: "test-secret",
      fetchImpl,
    }),
    (error) => error instanceof HasResetError && error.code === "request_failed",
  );
  assert.equal(callCount, 1);
});

test("fetchGrokEvents reports an unsuccessful HTTP status without its body", async () => {
  await assert.rejects(
    fetchGrokEvents({
      baseURL: "https://api.x.ai/v1",
      model: "grok-4.5",
      apiKey: "test-secret",
      fetchImpl: async () => new Response("sensitive upstream body", {
        status: 503,
      }),
    }),
    (error) => (
      error instanceof HasResetError
      && error.code === "request_failed"
      && error.message === "Grok returned HTTP 503"
      && !error.message.includes("sensitive")
    ),
  );
});

test("fetchGrokEvents ignores posts outside the strict prior 48 hours", async () => {
  const response = structuredClone(validResponse);
  const analysis = JSON.parse(response.output[1].content[0].text);
  analysis.events[0].announcedAt = "2026-07-26T11:59:59.000Z";
  analysis.events[1].announcedAt = "2026-07-28T12:00:00.001Z";
  response.output[1].content[0].text = JSON.stringify(analysis);
  let callCount = 0;

  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-28T12:00:00.000Z"),
    fetchImpl: async () => {
      callCount += 1;
      return new Response(JSON.stringify(response), { status: 200 });
    },
  });

  assert.deepEqual(events, []);
  assert.equal(callCount, 1);
});
