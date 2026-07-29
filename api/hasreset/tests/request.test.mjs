import assert from "node:assert/strict";
import test from "node:test";

import {
  buildGrokRequest,
  responsesURL,
} from "../src/index.mjs";

test("buildGrokRequest limits Grok to Tibo X posts in the prior 48-hour date window", () => {
  const request = buildGrokRequest({
    model: "grok-4.5",
    now: new Date("2026-07-28T12:00:00.000Z"),
  });

  assert.equal(request.model, "grok-4.5");
  assert.equal(request.tool_choice, "required");
  assert.equal(request.max_tool_calls, 2);
  assert.equal("max_turns" in request, false);
  assert.equal(request.parallel_tool_calls, false);
  assert.equal(request.store, false);
  assert.deepEqual(request.tools, [{
    type: "x_search",
    allowed_x_handles: ["thsottiaux"],
    from_date: "2026-07-26",
    to_date: "2026-07-28",
    enable_image_understanding: false,
    enable_video_understanding: false,
  }]);
  assert.equal(request.text.format.type, "json_schema");
  assert.equal(request.text.format.name, "hasreset_analysis");
  assert.equal(request.text.format.strict, true);
  assert.equal(request.text.format.schema.additionalProperties, false);
});

test("responsesURL accepts HTTPS and loopback HTTP API version base URLs", () => {
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
  assert.throws(
    () => responsesURL("https://api.x.ai"),
    /version directory/,
  );
});
