import {
  mkdir,
  readFile,
  writeFile,
} from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { fetchGrokEvents } from "./monitor.mjs";
import { HasResetError } from "./response.mjs";
import { assetsChanged, stageSite } from "./site.mjs";
import { decidePublication } from "./status.mjs";
import { validateStatus } from "./validation.mjs";

const defaultPublicDir = fileURLToPath(new URL("../public/", import.meta.url));

export async function runCLI({
  argv,
  env = process.env,
  now = new Date(),
  fetchImpl = globalThis.fetch,
  publicDir = defaultPublicDir,
  onMonitorError = () => {},
}) {
  const paths = parseArguments(argv);
  const prior = await loadPrevious(paths.previousDir);
  const siteChanged = await assetsChanged({
    publicDir,
    previousDir: paths.previousDir,
  });

  let events = [];
  let errorCode = prior.errorCode;
  if (errorCode === null) {
    try {
      events = await fetchGrokEvents({
        baseURL: env.GROK_API_BASE_URL,
        model: env.GROK_MODEL,
        apiKey: env.GROK_API_KEY,
        now,
        fetchImpl,
      });
    } catch (error) {
      const diagnostic = safeErrorDiagnostic(error);
      errorCode = diagnostic.code;
      onMonitorError(diagnostic);
    }
  }

  const result = decidePublication({
    previousStatus: prior.status,
    events,
    now,
    errorCode,
    assetsChanged: siteChanged,
  });
  await stageSite({
    publicDir,
    previousDir: paths.previousDir,
    outputDir: paths.outputDir,
    status: result.status,
  });
  await writeDecision(paths.decisionFile, result);
  return result.degraded ? 2 : 0;
}

function parseArguments(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!["--previous-dir", "--output-dir", "--decision-file"].includes(flag) || !value) {
      throw new HasResetError("configuration_error", "Invalid CLI arguments");
    }
    if (values.has(flag)) {
      throw new HasResetError("configuration_error", "Duplicate CLI argument");
    }
    values.set(flag, value);
  }
  if (values.size !== 3) {
    throw new HasResetError("configuration_error", "Missing CLI argument");
  }
  return {
    previousDir: resolve(values.get("--previous-dir")),
    outputDir: resolve(values.get("--output-dir")),
    decisionFile: resolve(values.get("--decision-file")),
  };
}

async function loadPrevious(previousDir) {
  try {
    const value = JSON.parse(await readFile(
      resolve(previousDir, "api/status.json"),
      "utf8",
    ));
    return { status: validateStatus(value), errorCode: null };
  } catch (error) {
    if (error?.code === "ENOENT") {
      return { status: null, errorCode: null };
    }
    return { status: null, errorCode: "invalid_response" };
  }
}

function safeErrorCode(error) {
  return error instanceof HasResetError
    ? error.code
    : "request_failed";
}

function safeErrorDiagnostic(error) {
  if (error instanceof HasResetError) {
    return { code: error.code, message: error.message };
  }
  return {
    code: "request_failed",
    message: "Unexpected monitor failure",
  };
}

async function writeDecision(path, result) {
  const decision = {
    publish: result.publish,
    degraded: result.degraded,
    errorCode: result.errorCode,
    reason: result.reason,
  };
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(decision, null, 2)}\n`);
}

async function main() {
  try {
    process.exitCode = await runCLI({
      argv: process.argv.slice(2),
      onMonitorError: ({ code, message }) => {
        process.stderr.write(`hasreset monitor: ${code}: ${message}\n`);
      },
    });
  } catch (error) {
    const code = safeErrorCode(error);
    process.stderr.write(`hasreset: ${code}\n`);
    process.exitCode = 2;
  }
}

const entryURL = process.argv[1]
  ? pathToFileURL(resolve(process.argv[1])).href
  : null;
if (entryURL === import.meta.url) {
  await main();
}
