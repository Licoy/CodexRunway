import assert from "node:assert/strict";
import test from "node:test";

import {
  attachCandidateCitations,
  extractDiscoveryCandidates,
  mergeDiscoveryCandidates,
} from "../src/index.mjs";

test("extractDiscoveryCandidates reads JSON rows and status URL annotations", () => {
  const response = {
    status: "completed",
    output: [{
      type: "message",
      content: [{
        type: "output_text",
        text: JSON.stringify([
          {
            postId: "2082317452755751098",
            url: "https://x.com/thsottiaux/status/2082317452755751098",
            announcedAt: "2026-07-29T04:09:02Z",
            snippet: "I've reset usage limits for all ChatGPT Work and Codex users",
            kindGuess: "reset_completed",
          },
          {
            postId: "2082341416681001277",
            announcedAt: "2026-07-29T05:44:16Z",
            snippet: "I read your tweets and decide accordingly",
            kindGuess: "reset_scheduled",
            parentContext: "quoted prediction next codex reset coming on 31 July",
          },
        ]),
        annotations: [
          { url: "https://x.com/i/status/2082317452755751098" },
          { url: "https://x.com/thsottiaux/status/2081899343091843463" },
        ],
      }],
    }],
  };

  const candidates = extractDiscoveryCandidates(response);
  assert.equal(candidates.some((item) => item.postId === "2082317452755751098"), true);
  assert.equal(candidates.some((item) => item.postId === "2082341416681001277"), true);
  assert.equal(candidates.some((item) => item.postId === "2081899343091843463"), true);
  const reply = candidates.find((item) => item.postId === "2082341416681001277");
  assert.match(reply.parentContext, /31 July/);
});

test("attachCandidateCitations injects candidate URLs for parse validation", () => {
  const response = {
    status: "completed",
    output: [{
      type: "message",
      content: [{
        type: "output_text",
        text: "{\"events\":[]}",
        annotations: [],
      }],
    }],
  };
  const cited = attachCandidateCitations(response, [{
    postId: "200",
    url: "https://x.com/thsottiaux/status/200",
  }]);
  assert.deepEqual(cited.citations, ["https://x.com/thsottiaux/status/200"]);
  assert.equal(
    cited.output[0].content[0].annotations[0].url,
    "https://x.com/thsottiaux/status/200",
  );
});

test("mergeDiscoveryCandidates keeps richer snippets", () => {
  const merged = mergeDiscoveryCandidates(
    [{ postId: "1", snippet: "a", kindGuess: "uncertain", parentContext: "" }],
    [{ postId: "1", snippet: "longer snippet", kindGuess: "reset_completed", parentContext: "July 31" }],
  );
  assert.equal(merged.length, 1);
  assert.equal(merged[0].snippet, "longer snippet");
  assert.equal(merged[0].kindGuess, "reset_completed");
  assert.equal(merged[0].parentContext, "July 31");
});
