import assert from "node:assert/strict";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  applyAssetVersion,
  assetsChanged,
  stageSite,
  stripAssetVersions,
} from "../src/site.mjs";

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

test("applyAssetVersion stamps relative static assets and is idempotent", () => {
  const source = [
    '<link rel="stylesheet" href="./styles.css">',
    '<script type="module" src="./app.js"></script>',
    '<img src="./logo.png" srcset="./logo.png 1x, ./logo@2x.png 2x">',
    'import { x } from "./l10n.js";',
    "url('fonts/StrawberryIcon-Free.woff')",
    '"src": "./favicon-32.png"',
    '<a href="./api/status.json">json</a>',
    '<a href="https://example.com/styles.css">abs</a>',
  ].join("\n");

  const stamped = applyAssetVersion(source, "1710000000000");
  assert.match(stamped, /href="\.\/styles\.css\?ver=1710000000000"/);
  assert.match(stamped, /src="\.\/app\.js\?ver=1710000000000"/);
  assert.match(stamped, /src="\.\/logo\.png\?ver=1710000000000"/);
  assert.match(
    stamped,
    /srcset="\.\/logo\.png\?ver=1710000000000 1x, \.\/logo@2x\.png\?ver=1710000000000 2x"/,
  );
  assert.match(stamped, /from "\.\/l10n\.js\?ver=1710000000000"/);
  assert.match(stamped, /url\('fonts\/StrawberryIcon-Free\.woff\?ver=1710000000000'\)/);
  assert.match(stamped, /"src": "\.\/favicon-32\.png\?ver=1710000000000"/);
  assert.match(stamped, /href="\.\/api\/status\.json"/);
  assert.match(stamped, /href="https:\/\/example\.com\/styles\.css"/);

  const restamped = applyAssetVersion(stamped, "1710000000999");
  assert.equal(restamped, applyAssetVersion(source, "1710000000999"));
  assert.equal(stripAssetVersions(restamped), source);
});

test("stageSite rewrites deployed asset references with ?ver=timestamp", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "hasreset-site-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  const publicDir = join(root, "public");
  const previousDir = join(root, "previous");
  const outputDir = join(root, "output");
  await mkdir(publicDir, { recursive: true });
  await mkdir(join(publicDir, "vendor", "caomei", "fonts"), { recursive: true });
  await mkdir(previousDir);

  await writeFile(
    join(publicDir, "index.html"),
    [
      '<link rel="stylesheet" href="./styles.css">',
      '<link rel="stylesheet" href="./vendor/caomei/style.css">',
      '<script type="module" src="./app.js"></script>',
      '<img src="./logo.png" srcset="./logo.png 1x, ./logo@2x.png 2x">',
      '<link rel="manifest" href="./site.webmanifest">',
      '<a href="./api/status.json">json</a>',
    ].join("\n"),
  );
  await writeFile(
    join(publicDir, "app.js"),
    'import { t } from "./l10n.js";\nimport { c } from "./status-logic.js";\n',
  );
  await writeFile(join(publicDir, "styles.css"), "body{color:red}");
  await writeFile(join(publicDir, "l10n.js"), "export const t = 1;\n");
  await writeFile(join(publicDir, "status-logic.js"), "export const c = 1;\n");
  await writeFile(join(publicDir, "logo.png"), "png");
  await writeFile(join(publicDir, "logo@2x.png"), "png2");
  await writeFile(
    join(publicDir, "site.webmanifest"),
    JSON.stringify({
      name: "test",
      icons: [{ src: "./favicon-32.png", sizes: "32x32" }],
    }),
  );
  await writeFile(join(publicDir, "favicon-32.png"), "ico");
  await writeFile(
    join(publicDir, "vendor", "caomei", "style.css"),
    "@font-face{src:url('fonts/StrawberryIcon-Free.woff') format('woff');}",
  );
  await writeFile(
    join(publicDir, "vendor", "caomei", "fonts", "StrawberryIcon-Free.woff"),
    "woff",
  );

  const status = {
    schemaVersion: 1,
    generatedAt: "2026-07-29T12:17:00.000Z",
    lastSuccessfulCheckAt: "2026-07-29T12:17:00.000Z",
    monitor: { state: "healthy", errorCode: null },
    events: [],
  };
  const expectedVer = String(Date.parse(status.generatedAt));

  await stageSite({
    publicDir,
    previousDir,
    outputDir,
    status,
  });

  const index = await readFile(join(outputDir, "index.html"), "utf8");
  assert.match(index, new RegExp(`styles\\.css\\?ver=${expectedVer}`));
  assert.match(index, new RegExp(`app\\.js\\?ver=${expectedVer}`));
  assert.match(index, new RegExp(`logo\\.png\\?ver=${expectedVer}`));
  assert.match(index, new RegExp(`logo@2x\\.png\\?ver=${expectedVer}`));
  assert.match(index, new RegExp(`site\\.webmanifest\\?ver=${expectedVer}`));
  assert.match(index, /href="\.\/api\/status\.json"/);

  const app = await readFile(join(outputDir, "app.js"), "utf8");
  assert.match(app, new RegExp(`l10n\\.js\\?ver=${expectedVer}`));
  assert.match(app, new RegExp(`status-logic\\.js\\?ver=${expectedVer}`));

  const manifest = await readFile(join(outputDir, "site.webmanifest"), "utf8");
  assert.match(manifest, new RegExp(`favicon-32\\.png\\?ver=${expectedVer}`));

  const iconCss = await readFile(
    join(outputDir, "vendor", "caomei", "style.css"),
    "utf8",
  );
  assert.match(
    iconCss,
    new RegExp(`StrawberryIcon-Free\\.woff\\?ver=${expectedVer}`),
  );

  // Source tree must stay unstamped so local browsing and git remain clean.
  const sourceIndex = await readFile(join(publicDir, "index.html"), "utf8");
  assert.doesNotMatch(sourceIndex, /\?ver=/);
});

test("assetsChanged ignores deploy-time ?ver= stamps on previous site", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "hasreset-site-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  const publicDir = join(root, "public");
  const previousDir = join(root, "previous");
  const outputDir = join(root, "output");
  await mkdir(publicDir);
  await mkdir(previousDir);
  await writeFile(
    join(publicDir, "index.html"),
    '<link rel="stylesheet" href="./styles.css">\n',
  );
  await writeFile(join(publicDir, "styles.css"), "body{}\n");

  await stageSite({
    publicDir,
    previousDir,
    outputDir,
    status: { generatedAt: "2026-07-29T12:17:00.000Z" },
  });

  assert.equal(
    await assetsChanged({ publicDir, previousDir: outputDir }),
    false,
  );

  await writeFile(join(publicDir, "styles.css"), "body{color:blue}\n");
  assert.equal(
    await assetsChanged({ publicDir, previousDir: outputDir }),
    true,
  );
});
