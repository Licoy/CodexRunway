import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  fetchGrokEvents,
  HasResetError,
  mergeEventsByPostId,
  needsFullWindowBackfill,
} from "../src/index.mjs";

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

function analysisWithEvents(events) {
  const response = structuredClone(validResponse);
  response.output[1].content[0].text = JSON.stringify({ events });
  response.citations = events.map((event) => (
    `https://x.com/thsottiaux/status/${event.postId}`
  ));
  return response;
}

const completedToday = {
  kind: "reset_completed",
  announcedAt: "2026-07-29T04:09:02.000Z",
  effectiveAt: null,
  plans: ["all"],
  windows: ["weekly"],
  postId: "2082317452755751098",
  sourceUrl: "https://x.com/thsottiaux/status/2082317452755751098",
  confidence: 0.99,
};

const scheduledReply = {
  kind: "reset_scheduled",
  announcedAt: "2026-07-29T05:44:16.000Z",
  effectiveAt: "2026-07-31T12:00:00.000Z",
  plans: ["all"],
  windows: ["unknown"],
  postId: "2082341416681001277",
  sourceUrl: "https://x.com/thsottiaux/status/2082341416681001277",
  confidence: 0.9,
};

const olderCompleted = {
  kind: "reset_completed",
  announcedAt: "2026-07-28T03:09:23.000Z",
  effectiveAt: null,
  plans: ["all"],
  windows: ["unknown"],
  postId: "2081940052154933696",
  sourceUrl: "https://x.com/thsottiaux/status/2081940052154933696",
  confidence: 0.98,
};

test("fetchGrokEvents recent pass alone is enough when UTC-today completed reset is found", async () => {
  let opened = 0;
  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-29T12:00:00.000Z"),
    timeoutMs: 1_000,
    transport: "websocket",
    openWebSocketImpl: mockWebSocket((session, text) => {
      opened += 1;
      const message = JSON.parse(text);
      assert.equal(message.type, "response.create");
      assert.equal(message.max_tool_calls, 10);
      assert.deepEqual(message.reasoning, { effort: "high" });
      assert.match(message.input[1].content[0].text, /FOCUS MODE: recent/);
      session.emit("message", JSON.stringify({
        type: "response.completed",
        response: analysisWithEvents([completedToday, scheduledReply]),
      }));
    }),
  });

  assert.equal(opened, 1);
  assert.equal(events.length, 2);
  assert.equal(events[0].source.postId, "2082341416681001277");
  assert.equal(events[0].kind, "reset_scheduled");
  assert.equal(events[0].effectiveAt, "2026-07-31T12:00:00.000Z");
  assert.equal(events[1].source.postId, "2082317452755751098");
  assert.equal(events[1].kind, "reset_completed");
});

test("fetchGrokEvents backfills the full window when recent pass lacks UTC-today completed", async () => {
  let opened = 0;
  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-29T12:00:00.000Z"),
    timeoutMs: 1_000,
    transport: "websocket",
    openWebSocketImpl: mockWebSocket((session, text) => {
      opened += 1;
      const message = JSON.parse(text);
      if (opened === 1) {
        assert.match(message.input[1].content[0].text, /FOCUS MODE: recent/);
        session.emit("message", JSON.stringify({
          type: "response.completed",
          response: analysisWithEvents([olderCompleted]),
        }));
        return;
      }
      assert.match(message.input[1].content[0].text, /FOCUS MODE: full window/);
      assert.equal(message.max_tool_calls, 8);
      session.emit("message", JSON.stringify({
        type: "response.completed",
        response: analysisWithEvents([completedToday, olderCompleted, scheduledReply]),
      }));
    }),
  });

  assert.equal(opened, 2);
  assert.equal(events.map((event) => event.source.postId).join(","), [
    "2082341416681001277",
    "2082317452755751098",
    "2081940052154933696",
  ].join(","));
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
  const stale = analysisWithEvents([{
    kind: "reset_completed",
    announcedAt: "2026-07-25T11:59:59.000Z",
    effectiveAt: null,
    plans: ["all"],
    windows: ["weekly"],
    postId: "99",
    sourceUrl: "https://x.com/thsottiaux/status/99",
    confidence: 0.9,
  }, {
    kind: "limit_increase",
    announcedAt: "2026-07-28T12:00:00.001Z",
    effectiveAt: null,
    plans: ["all"],
    windows: ["weekly"],
    postId: "100",
    sourceUrl: "https://x.com/thsottiaux/status/100",
    confidence: 0.8,
  }]);
  let callCount = 0;

  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-28T12:00:00.000Z"),
    transport: "websocket",
    openWebSocketImpl: mockWebSocket((session) => {
      callCount += 1;
      // No UTC-today completed reset → dual pass; both payloads stay out of window.
      session.emit("message", JSON.stringify({
        type: "response.completed",
        response: stale,
      }));
    }),
  });

  assert.deepEqual(events, []);
  assert.equal(callCount, 2);
});

test("fetchGrokEvents defaults to HTTP transport", async () => {
  const requests = [];
  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-29T12:00:00.000Z"),
    fetchImpl: async (url, options) => {
      requests.push({ url, options: JSON.parse(options.body) });
      return new Response(
        JSON.stringify(analysisWithEvents([completedToday])),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      );
    },
  });

  assert.equal(events.length, 1);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, "https://api.x.ai/v1/responses");
  assert.match(requests[0].options.input[1].content, /FOCUS MODE: recent/);
  assert.deepEqual(requests[0].options.reasoning, { effort: "high" });
});

test("needsFullWindowBackfill detects missing UTC-today completed resets", () => {
  const now = new Date("2026-07-29T12:00:00.000Z");
  assert.equal(needsFullWindowBackfill([], now), true);
  assert.equal(needsFullWindowBackfill([{
    kind: "reset_completed",
    announcedAt: "2026-07-28T03:09:23.000Z",
    source: { postId: "1" },
  }], now), true);
  assert.equal(needsFullWindowBackfill([{
    kind: "reset_completed",
    announcedAt: "2026-07-29T04:09:02.000Z",
    source: { postId: "2" },
  }], now), false);
});

test("mergeEventsByPostId prefers decisive kinds and newest order", () => {
  const merged = mergeEventsByPostId(
    [{
      kind: "uncertain",
      announcedAt: "2026-07-29T05:00:00.000Z",
      confidence: 0.5,
      source: { postId: "1" },
    }],
    [{
      kind: "reset_completed",
      announcedAt: "2026-07-29T05:00:00.000Z",
      confidence: 0.9,
      source: { postId: "1" },
    }, {
      kind: "reset_scheduled",
      announcedAt: "2026-07-29T06:00:00.000Z",
      confidence: 0.8,
      source: { postId: "2" },
    }],
  );
  assert.equal(merged[0].source.postId, "2");
  assert.equal(merged[1].kind, "reset_completed");
});
