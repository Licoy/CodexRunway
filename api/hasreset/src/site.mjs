import { createHash } from "node:crypto";
import {
  cp,
  mkdir,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import {
  isAbsolute,
  parse,
  relative,
  resolve,
} from "node:path";

export async function assetsChanged({ publicDir, previousDir }) {
  const current = await assetManifest(publicDir);
  current.set(".nojekyll", digest(Buffer.alloc(0)));

  let previous;
  try {
    previous = await assetManifest(previousDir, {
      exclude: new Set([".git", "api/status.json"]),
    });
  } catch (error) {
    if (error?.code === "ENOENT") return true;
    throw error;
  }
  return serializeManifest(current) !== serializeManifest(previous);
}

export async function stageSite({ publicDir, previousDir, outputDir, status }) {
  assertSafeOutput({ publicDir, previousDir, outputDir });
  await rm(outputDir, { recursive: true, force: true });
  await mkdir(outputDir, { recursive: true });
  await cp(publicDir, outputDir, { recursive: true, errorOnExist: true });
  await writeFile(resolve(outputDir, ".nojekyll"), "");
  const apiDir = resolve(outputDir, "api");
  await mkdir(apiDir, { recursive: true });
  await writeFile(
    resolve(apiDir, "status.json"),
    `${JSON.stringify(status, null, 2)}\n`,
  );
}

async function assetManifest(directory, options = {}) {
  const result = new Map();
  await visit(directory, "", result, options.exclude ?? new Set());
  return result;
}

async function visit(root, path, result, exclude) {
  for (const entry of await readdir(resolve(root, path), { withFileTypes: true })) {
    const entryPath = path ? `${path}/${entry.name}` : entry.name;
    if (exclude.has(entryPath)) continue;
    if (entry.isDirectory()) {
      await visit(root, entryPath, result, exclude);
    } else if (entry.isFile()) {
      result.set(entryPath, digest(await readFile(resolve(root, entryPath))));
    } else {
      result.set(entryPath, "unsupported-entry");
    }
  }
}

function serializeManifest(manifest) {
  return JSON.stringify([...manifest.entries()].sort(([left], [right]) => (
    left.localeCompare(right)
  )));
}

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

function assertSafeOutput({ publicDir, previousDir, outputDir }) {
  const output = resolve(outputDir);
  const protectedPaths = [
    resolve(process.cwd()),
    resolve(publicDir),
    resolve(previousDir),
  ];
  if (
    output === parse(output).root
    || protectedPaths.some((path) => pathsOverlap(output, path))
  ) {
    throw new Error("output directory is not safe to replace");
  }
}

function pathsOverlap(left, right) {
  return isSameOrDescendant(left, right) || isSameOrDescendant(right, left);
}

function isSameOrDescendant(path, parent) {
  const value = relative(parent, path);
  return value === "" || (!value.startsWith("..") && !isAbsolute(value));
}
