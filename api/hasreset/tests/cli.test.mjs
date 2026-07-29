import assert from "node:assert/strict";
import {
  access,
  mkdtemp,
  readFile,
  rm,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { runCLI, validateStatus } from "../src/index.mjs";

function discoveryBody(candidates) {
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

function classificationBody(events) {
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

const todayEvent = {
  kind: "reset_completed",
  announcedAt: "2026-07-29T09:00:00.000Z",
  effectiveAt: null,
  plans: ["all"],
  windows: ["weekly", "five_hour"],
  postId: "200",
  sourceUrl: "https://x.com/i/status/200",
  confidence: 0.98,
};

function mockPipelineFetch() {
  return async (_url, options) => {
    const body = JSON.parse(options.body);
    if (body.tool_choice === "required") {
      return new Response(JSON.stringify(discoveryBody([{
        postId: "200",
        url: "https://x.com/thsottiaux/status/200",
        announcedAt: "2026-07-29T09:00:00.000Z",
        snippet: "I've reset usage limits",
        kindGuess: "reset_completed",
      }])), { status: 200 });
    }
    return new Response(JSON.stringify(classificationBody([todayEvent])), { status: 200 });
  };
}

test("runCLI stages a safe first-run degraded site and returns exit code 2", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "hasreset-cli-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  const previousDir = join(root, "missing-previous");
  const outputDir = join(root, "site");
  const decisionFile = join(root, "decision.json");
  const diagnostics = [];

  const exitCode = await runCLI({
    argv: cliArguments(previousDir, outputDir, decisionFile),
    env: {},
    now: new Date("2026-07-29T12:17:00.000Z"),
    onMonitorError: (diagnostic) => diagnostics.push(diagnostic),
  });

  assert.equal(exitCode, 2);
  assert.deepEqual(diagnostics, [{
    code: "configuration_error",
    message: "GROK_API_KEY is required",
  }]);
  assert.deepEqual(await readJSON(decisionFile), {
    publish: true,
    degraded: true,
    errorCode: "configuration_error",
    reason: "initial_degraded",
  });
  const status = validateStatus(await readJSON(join(outputDir, "api/status.json")));
  assert.equal(status.lastSuccessfulCheckAt, null);
  assert.deepEqual(status.events, []);
  await Promise.all([
    access(join(outputDir, ".nojekyll")),
    access(join(outputDir, "favicon.svg")),
    access(join(outputDir, "index.html")),
    access(join(outputDir, "app.js")),
    access(join(outputDir, "l10n.js")),
    access(join(outputDir, "status-logic.js")),
    access(join(outputDir, "styles.css")),
  ]);
});

test("runCLI returns zero and avoids a same-day no-op publication", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "hasreset-cli-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  const missingPrevious = join(root, "missing-previous");
  const firstOutput = join(root, "first-site");
  const secondOutput = join(root, "second-site");
  const firstDecision = join(root, "first-decision.json");
  const secondDecision = join(root, "second-decision.json");
  const env = {
    GROK_API_BASE_URL: "https://api.x.ai/v1",
    GROK_MODEL: "grok-4.5",
    GROK_API_KEY: "test-secret",
  };
  let requestCount = 0;
  const fetchImpl = async (url, options) => {
    requestCount += 1;
    return mockPipelineFetch()(url, options);
  };

  const firstExit = await runCLI({
    argv: cliArguments(missingPrevious, firstOutput, firstDecision),
    env,
    now: new Date("2026-07-29T10:17:00.000Z"),
    fetchImpl,
  });
  const secondExit = await runCLI({
    argv: cliArguments(firstOutput, secondOutput, secondDecision),
    env,
    now: new Date("2026-07-29T11:17:00.000Z"),
    fetchImpl,
  });

  assert.equal(firstExit, 0);
  assert.equal(secondExit, 0);
  assert.ok(requestCount >= 4);
  assert.deepEqual(await readJSON(firstDecision), {
    publish: true,
    degraded: false,
    errorCode: null,
    reason: "initial_publish",
  });
  assert.deepEqual(await readJSON(secondDecision), {
    publish: false,
    degraded: false,
    errorCode: null,
    reason: "unchanged",
  });
  assert.deepEqual(
    await readJSON(join(secondOutput, "api/status.json")),
    await readJSON(join(firstOutput, "api/status.json")),
  );
});

function cliArguments(previousDir, outputDir, decisionFile) {
  return [
    "--previous-dir",
    previousDir,
    "--output-dir",
    outputDir,
    "--decision-file",
    decisionFile,
  ];
}

test("runCLI uses WebSocket transport when GROK_USE_WS is true", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "hasreset-cli-ws-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  const previousDir = join(root, "missing-previous");
  const outputDir = join(root, "site");
  const decisionFile = join(root, "decision.json");
  let requestCount = 0;
  let usedWebSocket = false;

  const exitCode = await runCLI({
    argv: cliArguments(previousDir, outputDir, decisionFile),
    env: {
      GROK_API_BASE_URL: "https://api.x.ai/v1",
      GROK_MODEL: "grok-4.5",
      GROK_API_KEY: "test-secret",
      GROK_USE_WS: "true",
    },
    now: new Date("2026-07-29T10:17:00.000Z"),
    openWebSocketImpl: async () => {
      usedWebSocket = true;
      const listeners = new Map();
      return {
        send(text) {
          requestCount += 1;
          const message = JSON.parse(text);
          queueMicrotask(() => {
            const payload = message.tool_choice === "required"
              ? discoveryBody([{
                postId: "200",
                url: "https://x.com/thsottiaux/status/200",
                announcedAt: "2026-07-29T09:00:00.000Z",
                snippet: "I've reset usage limits",
                kindGuess: "reset_completed",
              }])
              : classificationBody([todayEvent]);
            for (const callback of listeners.get("message") ?? []) {
              callback(JSON.stringify({
                type: "response.completed",
                response: payload,
              }));
            }
          });
        },
        close() {},
        on(type, callback) {
          const list = listeners.get(type) ?? [];
          list.push(callback);
          listeners.set(type, list);
          return () => {};
        },
      };
    },
    fetchImpl: async () => {
      throw new Error("HTTP transport should not be used when GROK_USE_WS=true");
    },
  });

  assert.equal(exitCode, 0);
  assert.equal(usedWebSocket, true);
  assert.ok(requestCount >= 2);
  assert.deepEqual(await readJSON(decisionFile), {
    publish: true,
    degraded: false,
    errorCode: null,
    reason: "initial_publish",
  });
});

async function readJSON(path) {
  return JSON.parse(await readFile(path, "utf8"));
}
