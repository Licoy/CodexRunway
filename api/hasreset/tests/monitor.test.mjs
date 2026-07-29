import assert from "node:assert/strict";
import test from "node:test";

import {
  fetchGrokEvents,
  HasResetError,
  mergeEventsByPostId,
  parseGrokResponse,
} from "../src/index.mjs";

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

function discoveryResponse(candidates) {
  return {
    status: "completed",
    output: [{
      type: "x_search_call",
      status: "completed",
    }, {
      type: "message",
      content: [{
        type: "output_text",
        text: JSON.stringify(candidates),
        annotations: candidates.map((item) => ({ url: item.url })),
      }],
    }],
  };
}

function classificationResponse(events) {
  return {
    status: "completed",
    citations: events.map((event) => event.sourceUrl),
    output: [{
      type: "message",
      content: [{
        type: "output_text",
        text: JSON.stringify({ events }),
        annotations: events.map((event) => ({ url: event.sourceUrl })),
      }],
    }],
  };
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

const scheduleReply = {
  kind: "reset_scheduled",
  announcedAt: "2026-07-29T05:44:16.000Z",
  effectiveAt: "2026-07-31",
  plans: ["all"],
  windows: ["unknown"],
  postId: "2082341416681001277",
  sourceUrl: "https://x.com/thsottiaux/status/2082341416681001277",
  confidence: 0.9,
};

test("fetchGrokEvents discovery + classification returns today completed and next plan", async () => {
  let call = 0;
  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-29T12:00:00.000Z"),
    timeoutMs: 5_000,
    transport: "websocket",
    openWebSocketImpl: mockWebSocket((session, text) => {
      call += 1;
      const message = JSON.parse(text);
      assert.equal(message.type, "response.create");
      if (call === 1) {
        // main discovery
        assert.equal(message.tool_choice, "required");
        session.emit("message", JSON.stringify({
          type: "response.completed",
          response: discoveryResponse([{
            postId: "2082317452755751098",
            url: "https://x.com/thsottiaux/status/2082317452755751098",
            announcedAt: "2026-07-29T04:09:02.000Z",
            snippet: "I've reset usage limits for all ChatGPT Work and Codex users",
            kindGuess: "reset_completed",
          }]),
        }));
        return;
      }
      if (call === 2) {
        // schedule reply discovery
        session.emit("message", JSON.stringify({
          type: "response.completed",
          response: discoveryResponse([{
            postId: "2082341416681001277",
            url: "https://x.com/thsottiaux/status/2082341416681001277",
            announcedAt: "2026-07-29T05:44:16.000Z",
            snippet: "I read your tweets and decide accordingly",
            kindGuess: "reset_scheduled",
            parentContext: "next codex reset coming on 31 July",
          }]),
        }));
        return;
      }
      // classification
      assert.equal(message.tool_choice, "none");
      session.emit("message", JSON.stringify({
        type: "response.completed",
        response: classificationResponse([completedToday, scheduleReply]),
      }));
    }),
  });

  assert.equal(call, 3);
  assert.equal(events[0].source.postId, "2082341416681001277");
  assert.equal(events[0].kind, "reset_scheduled");
  assert.equal(events[0].effectiveAt, "2026-07-31T12:00:00.000Z");
  assert.equal(events[1].source.postId, "2082317452755751098");
  assert.equal(events[1].kind, "reset_completed");
});

test("fetchGrokEvents does not retry a failed WebSocket request beyond first open failure", async () => {
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

test("fetchGrokEvents defaults to HTTP transport and falls back to WS on HTTP failure", async () => {
  const requests = [];
  let opened = 0;
  const events = await fetchGrokEvents({
    baseURL: "https://api.x.ai/v1",
    model: "grok-4.5",
    apiKey: "test-secret",
    now: new Date("2026-07-29T12:00:00.000Z"),
    fetchImpl: async (url, options) => {
      requests.push({ url, body: JSON.parse(options.body) });
      return new Response("gateway timeout", { status: 504 });
    },
    openWebSocketImpl: mockWebSocket((session, text) => {
      opened += 1;
      const message = JSON.parse(text);
      if (message.tool_choice === "required" && opened === 1) {
        session.emit("message", JSON.stringify({
          type: "response.completed",
          response: discoveryResponse([{
            postId: "2082317452755751098",
            url: "https://x.com/thsottiaux/status/2082317452755751098",
            announcedAt: "2026-07-29T04:09:02.000Z",
            snippet: "I've reset usage limits",
            kindGuess: "reset_completed",
          }]),
        }));
        return;
      }
      if (message.tool_choice === "required") {
        session.emit("message", JSON.stringify({
          type: "response.completed",
          response: discoveryResponse([]),
        }));
        return;
      }
      session.emit("message", JSON.stringify({
        type: "response.completed",
        response: classificationResponse([completedToday]),
      }));
    }),
  });

  assert.ok(requests.length >= 1);
  assert.equal(requests[0].url, "https://api.x.ai/v1/responses");
  assert.ok(opened >= 2);
  assert.equal(events[0].source.postId, "2082317452755751098");
});

test("parseGrokResponse still accepts official web_search_call records", () => {
  const response = classificationResponse([completedToday]);
  response.output.unshift({
    type: "web_search_call",
    status: "completed",
    action: {
      type: "search",
      query: "thsottiaux reset",
      sources: [{ url: "https://x.com/thsottiaux/status/2082317452755751098" }],
    },
  });
  const events = parseGrokResponse(response);
  assert.equal(events.length, 1);
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
