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
  extname,
  isAbsolute,
  parse,
  relative,
  resolve,
} from "node:path";

const STAMPABLE_EXTENSIONS = new Set([
  ".html",
  ".js",
  ".css",
  ".webmanifest",
]);

const VERSION_QUERY = "?ver=";

export async function assetsChanged({ publicDir, previousDir }) {
  const current = await assetManifest(publicDir);
  current.set(".nojekyll", digest(Buffer.alloc(0)));

  let previous;
  try {
    previous = await assetManifest(previousDir, {
      exclude: new Set([".git", "api/status.json"]),
      // Deployed copies carry ?ver= stamps; ignore them so source vs live compare fair.
      normalizeStamps: true,
    });
  } catch (error) {
    if (error?.code === "ENOENT") return true;
    throw error;
  }
  return serializeManifest(current) !== serializeManifest(previous);
}

export async function stageSite({
  publicDir,
  previousDir,
  outputDir,
  status,
  assetVersion,
}) {
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
  await stampDeployedAssets(outputDir, resolveAssetVersion(status, assetVersion));
}

/** Exported for unit tests. */
export function applyAssetVersion(content, version) {
  const ver = sanitizeVersion(version);
  let result = stripAssetVersions(content);

  // href="/x" / src="./x" (quoted attributes)
  result = result.replace(
    /(\b(?:href|src)=["'])(\.\/[^"'?#]+?\.(?:css|js|mjs|png|jpe?g|webp|svg|ico|webmanifest|woff2?|ttf|otf))(["'])/gi,
    `$1$2${VERSION_QUERY}${ver}$3`,
  );

  // srcset entries: "./logo.png 1x, ./logo@2x.png 2x"
  result = result.replace(
    /(^|[\s,"'])(\.\/[^"'?#\s,]+\.(?:png|jpe?g|webp|svg|ico))(?=[\s,])/gi,
    `$1$2${VERSION_QUERY}${ver}`,
  );

  // ES module imports: from "./l10n.js"
  result = result.replace(
    /(\bfrom\s+["'])(\.\/[^"'?#]+?\.(?:js|mjs))(["'])/g,
    `$1$2${VERSION_QUERY}${ver}$3`,
  );

  // CSS url(...) including relative font paths without ./
  result = result.replace(
    /(\burl\(\s*['"]?)(\.?\.?\/?[^)'"?#]+?\.(?:woff2?|ttf|otf|eot|png|svg|jpe?g|webp|gif))(['"]?\s*\))/gi,
    `$1$2${VERSION_QUERY}${ver}$3`,
  );

  // webmanifest / JSON icon src
  result = result.replace(
    /("src"\s*:\s*")(\.\/[^"?#]+?\.(?:png|jpe?g|webp|svg|ico))(")/gi,
    `$1$2${VERSION_QUERY}${ver}$3`,
  );

  return result;
}

/** Exported for unit tests. */
export function stripAssetVersions(content) {
  return content.replace(/\?ver=[^"'?\s,)]+/g, "");
}

async function stampDeployedAssets(outputDir, version) {
  await visitFiles(outputDir, "", async (entryPath, absolutePath) => {
    if (!STAMPABLE_EXTENSIONS.has(extname(entryPath).toLowerCase())) return;
    const original = await readFile(absolutePath, "utf8");
    const stamped = applyAssetVersion(original, version);
    if (stamped !== original) {
      await writeFile(absolutePath, stamped);
    }
  });
}

function resolveAssetVersion(status, assetVersion) {
  if (assetVersion != null && String(assetVersion).length > 0) {
    return sanitizeVersion(assetVersion);
  }
  if (status && typeof status.generatedAt === "string") {
    const millis = Date.parse(status.generatedAt);
    if (Number.isFinite(millis)) return String(millis);
  }
  return String(Date.now());
}

function sanitizeVersion(version) {
  const value = String(version).trim();
  if (!/^[A-Za-z0-9._-]+$/.test(value)) {
    throw new Error("asset version must be a simple token");
  }
  return value;
}

async function assetManifest(directory, options = {}) {
  const result = new Map();
  await visit(
    directory,
    "",
    result,
    options.exclude ?? new Set(),
    options.normalizeStamps === true,
  );
  return result;
}

async function visit(root, path, result, exclude, normalizeStamps) {
  for (const entry of await readdir(resolve(root, path), { withFileTypes: true })) {
    const entryPath = path ? `${path}/${entry.name}` : entry.name;
    if (exclude.has(entryPath)) continue;
    if (entry.isDirectory()) {
      await visit(root, entryPath, result, exclude, normalizeStamps);
    } else if (entry.isFile()) {
      const bytes = await readFile(resolve(root, entryPath));
      result.set(
        entryPath,
        digest(normalizeManifestBytes(entryPath, bytes, normalizeStamps)),
      );
    } else {
      result.set(entryPath, "unsupported-entry");
    }
  }
}

async function visitFiles(root, path, onFile) {
  for (const entry of await readdir(resolve(root, path), { withFileTypes: true })) {
    const entryPath = path ? `${path}/${entry.name}` : entry.name;
    const absolutePath = resolve(root, entryPath);
    if (entry.isDirectory()) {
      await visitFiles(root, entryPath, onFile);
    } else if (entry.isFile()) {
      await onFile(entryPath, absolutePath);
    }
  }
}

function normalizeManifestBytes(entryPath, bytes, normalizeStamps) {
  if (!normalizeStamps) return bytes;
  if (!STAMPABLE_EXTENSIONS.has(extname(entryPath).toLowerCase())) return bytes;
  return Buffer.from(stripAssetVersions(bytes.toString("utf8")), "utf8");
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
