import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { fetchGrokEvents, HasResetError } from "../src/index.mjs";

const validResponse = JSON.parse(await readFile(
  new URL("./fixtures/grok-valid.json", import.meta.url),
  "utf8",
));

function mockWebSocket(handler) {
  return async (url, options) => {
    const listeners = new Map();
    const session = {
      sent: [],
      url,
      options,
      send(text) {
        this.sent.push(text);
        queueMicrotask(() => handler(session, text));
      },
      close() {},
      on(type, callback) {
        const list = listeners.get(type) ?? [];
        list.push(callback);
        listeners.set(type, list);
        return () => {
          listeners.set(type, (listeners.get(type) ?? []).filter((item) => item !== callback));
        };
      },
      emit(type, payload) {
        for (const callback of listeners.get(type) ?? []) callback(payload);
      },
    };
    return session;
  };
}

test("fetchGrokEvents performs exactly one authenticated Responses WebSocket request", async () => {
  let opened = 0;
  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-28T12:00:00.000Z"),
    timeoutMs: 1_000,
    transport: "websocket",
    openWebSocketImpl: mockWebSocket((session, text) => {
      opened += 1;
      assert.equal(session.url, "wss://api.x.ai/v1/responses");
      assert.equal(session.options.headers.Authorization, "Bearer test-secret");
      const message = JSON.parse(text);
      assert.equal(message.type, "response.create");
      assert.equal(message.max_tool_calls, 8);
      assert.equal(message.input[0].type, "message");
      session.emit("message", JSON.stringify({
        type: "response.completed",
        response: validResponse,
      }));
    }),
  });

  assert.equal(events.length, 2);
  assert.equal(opened, 1);
});

test("fetchGrokEvents does not retry a failed WebSocket request", async () => {
  let callCount = 0;

  await assert.rejects(
    fetchGrokEvents({
      baseURL: "https://api.x.ai/v1",
      model: "grok-4.5",
      apiKey: "test-secret",
      transport: "websocket",
      openWebSocketImpl: async () => {
        callCount += 1;
        throw new Error("fixture network failure");
      },
    }),
    (error) => error instanceof HasResetError && error.code === "request_failed",
  );
  assert.equal(callCount, 1);
});

test("fetchGrokEvents reports a failed WebSocket upgrade without upstream body details", async () => {
  await assert.rejects(
    fetchGrokEvents({
      baseURL: "https://api.x.ai/v1",
      model: "grok-4.5",
      apiKey: "test-secret",
      transport: "websocket",
      openWebSocketImpl: async () => {
        throw new Error("WebSocket upgrade failed with HTTP 503: sensitive upstream body");
      },
    }),
    (error) => (
      error instanceof HasResetError
      && error.code === "request_failed"
      && error.message === "Grok WebSocket upgrade failed (HTTP 503)"
      && !error.message.includes("sensitive")
    ),
  );
});

test("fetchGrokEvents ignores posts outside the strict prior 72 hours", async () => {
  const response = structuredClone(validResponse);
  const analysis = JSON.parse(response.output[1].content[0].text);
  analysis.events[0].announcedAt = "2026-07-25T11:59:59.000Z";
  analysis.events[1].announcedAt = "2026-07-28T12:00:00.001Z";
  response.output[1].content[0].text = JSON.stringify(analysis);
  let callCount = 0;

  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-28T12:00:00.000Z"),
    transport: "websocket",
    openWebSocketImpl: mockWebSocket((session) => {
      callCount += 1;
      session.emit("message", JSON.stringify({
        type: "response.completed",
        response,
      }));
    }),
  });

  assert.deepEqual(events, []);
  assert.equal(callCount, 1);
});

test("fetchGrokEvents defaults to HTTP transport", async () => {
  const requests = [];
  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-28T12:00:00.000Z"),
    fetchImpl: async (url, options) => {
      requests.push({ url, options });
      return new Response(JSON.stringify(validResponse), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    },
  });

  assert.equal(events.length, 2);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, "https://api.x.ai/v1/responses");
});
