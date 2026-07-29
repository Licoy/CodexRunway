import assert from "node:assert/strict";
import test from "node:test";

import {
  buildGrokRequest,
  buildWebSocketCreateMessage,
  responsesURL,
  responsesWebSocketURL,
} from "../src/index.mjs";

test("buildGrokRequest searches Tibo posts and replies in the prior 72-hour window", () => {
  const request = buildGrokRequest({
    model: "grok-4.5",
    now: new Date("2026-07-28T12:00:00.000Z"),
  });

  assert.equal(request.model, "grok-4.5");
  assert.equal(request.tool_choice, "required");
  assert.equal(request.max_tool_calls, 4);
  assert.equal("max_turns" in request, false);
  assert.equal(request.parallel_tool_calls, false);
  assert.equal(request.store, false);
  assert.deepEqual(request.tools, [{
    type: "x_search",
    allowed_x_handles: ["thsottiaux"],
    from_date: "2026-07-25",
    to_date: "2026-07-28",
    enable_image_understanding: false,
    enable_video_understanding: false,
  }]);
  assert.match(request.input[1].content, /Current UTC time: 2026-07-28T12:00:00.000Z/);
  assert.match(request.input[0].content, /replies/i);
  assert.equal(request.text.format.type, "json_schema");
  assert.equal(request.text.format.name, "hasreset_analysis");
  assert.equal(request.text.format.strict, true);
  assert.equal(request.text.format.schema.additionalProperties, false);
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
  assert.equal(
    responsesURL("http://127.0.0.1:8317/v1").href,
    "http://127.0.0.1:8317/v1/responses",
  );
  assert.equal(
    responsesURL("http://[::1]:8317/v1").href,
    "http://[::1]:8317/v1/responses",
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
  assert.equal(
    responsesWebSocketURL("http://127.0.0.1:8317/v1").href,
    "ws://127.0.0.1:8317/v1/responses",
  );
});

test("buildWebSocketCreateMessage wraps the Responses body for response.create", () => {
  const request = buildGrokRequest({
    model: "grok-4.5",
    now: new Date("2026-07-28T12:00:00.000Z"),
  });
  const message = buildWebSocketCreateMessage(request);
  assert.equal(message.type, "response.create");
  assert.equal(message.model, "grok-4.5");
  assert.equal(message.input[0].type, "message");
  assert.equal(message.input[0].role, "system");
  assert.equal(message.input[0].content[0].type, "input_text");
  assert.equal(message.input[1].role, "user");
  assert.equal("stream" in message, false);
});
