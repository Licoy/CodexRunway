import assert from "node:assert/strict";
import {
  mkdir,
  mkdtemp,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { stageSite } from "../src/site.mjs";

test("stageSite refuses an output directory that contains its inputs", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "hasreset-site-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  const publicDir = join(root, "public");
  const previousDir = join(root, "previous");
  await mkdir(publicDir);
  await mkdir(previousDir);
  await writeFile(join(publicDir, "index.html"), "fixture");

  await assert.rejects(
    stageSite({
      publicDir,
      previousDir,
      outputDir: root,
      status: {},
    }),
    /not safe/,
  );
});
