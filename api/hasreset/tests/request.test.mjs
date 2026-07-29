import assert from "node:assert/strict";
import test from "node:test";

import {
  buildClassificationRequest,
  buildDiscoveryRequest,
  buildGrokRequest,
  buildScheduleReplyDiscoveryRequest,
  buildWebSocketCreateMessage,
  responsesURL,
  responsesWebSocketURL,
} from "../src/index.mjs";

test("buildDiscoveryRequest uses x_search + web_search with low reasoning", () => {
  const request = buildDiscoveryRequest({
    model: "grok-4.5",
    now: new Date("2026-07-29T12:00:00.000Z"),
  });

  assert.equal(request.model, "grok-4.5");
  assert.equal(request.tool_choice, "required");
  assert.equal(request.max_tool_calls, 8);
  assert.deepEqual(request.reasoning, { effort: "low" });
  assert.equal(request.tools.length, 2);
  assert.equal(request.tools[0].type, "x_search");
  assert.deepEqual(request.tools[0].allowed_x_handles, ["thsottiaux"]);
  assert.equal(request.tools[0].from_date, "2026-07-26");
  assert.equal(request.tools[0].to_date, "2026-07-29");
  assert.equal(request.tools[1].type, "web_search");
  assert.match(request.input[0].content, /I've reset usage limits/);
  assert.match(request.input[0].content, /I read your tweets and decide accordingly/);
  assert.equal("text" in request, false);
});

test("buildScheduleReplyDiscoveryRequest focuses on decision replies", () => {
  const request = buildScheduleReplyDiscoveryRequest({
    model: "grok-4.5",
    now: new Date("2026-07-29T12:00:00.000Z"),
  });
  assert.equal(request.tool_choice, "required");
  assert.match(request.input[0].content, /decide accordingly/i);
  assert.equal(request.tools[0].from_date, "2026-07-27");
});

test("buildClassificationRequest classifies candidates without tools", () => {
  const request = buildClassificationRequest({
    model: "grok-4.5",
    now: new Date("2026-07-29T12:00:00.000Z"),
    candidates: [{
      postId: "2082317452755751098",
      url: "https://x.com/thsottiaux/status/2082317452755751098",
      announcedAt: "2026-07-29T04:09:02.000Z",
      snippet: "I've reset usage limits",
      kindGuess: "reset_completed",
    }],
  });
  assert.equal(request.tool_choice, "none");
  assert.equal("tools" in request, false);
  assert.deepEqual(request.reasoning, { effort: "low" });
  assert.equal(request.text.format.type, "json_schema");
  assert.equal(request.text.format.strict, true);
  assert.match(request.input[1].content, /2082317452755751098/);
  assert.match(request.input[0].content, /decide accordingly/i);
});

test("buildGrokRequest remains a discovery alias for compatibility", () => {
  const request = buildGrokRequest({
    model: "grok-4.5",
    now: new Date("2026-07-28T12:00:00.000Z"),
  });
  assert.equal(request.tools[0].type, "x_search");
  assert.equal(request.tools[1].type, "web_search");
});

test("responsesURL accepts HTTPS and loopback HTTP API version base URLs", () => {
  assert.equal(
    responsesURL("https://api.x.ai").href,
    "https://api.x.ai/v1/responses",
  );
  assert.equal(
    responsesURL("https://api.x.ai/v1/").href,
    "https://api.x.ai/v1/responses",
  );
  assert.equal(
    responsesURL("http://localhost:8317/v1").href,
    "http://localhost:8317/v1/responses",
  );
  assert.throws(
    () => responsesURL("http://api.x.ai/v1"),
    /HTTPS/,
  );
});

test("responsesWebSocketURL maps the Responses endpoint to wss/ws", () => {
  assert.equal(
    responsesWebSocketURL("https://api.x.ai/v1").href,
    "wss://api.x.ai/v1/responses",
  );
});

test("buildWebSocketCreateMessage wraps the Responses body for response.create", () => {
  const request = buildDiscoveryRequest({
    model: "grok-4.5",
    now: new Date("2026-07-28T12:00:00.000Z"),
  });
  const message = buildWebSocketCreateMessage(request);
  assert.equal(message.type, "response.create");
  assert.equal(message.model, "grok-4.5");
  assert.deepEqual(message.reasoning, { effort: "low" });
  assert.equal(message.input[0].type, "message");
  assert.equal(message.input[0].content[0].type, "input_text");
});
