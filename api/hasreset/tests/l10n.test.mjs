import assert from "node:assert/strict";
import test from "node:test";

import {
  createTranslator,
  detectBrowserLanguage,
  normalizeLanguage,
  translationKeys,
} from "../public/l10n.js";

test("public page has matching English and Simplified Chinese translations", () => {
  assert.deepEqual(
    translationKeys("en").sort(),
    translationKeys("zh-CN").sort(),
  );
});

test("public page follows browser language priority and interpolates values", () => {
  const english = createTranslator(["en-US", "zh-CN"]);
  const chinese = createTranslator(["zh-Hans-CN", "en-US"]);

  assert.equal(english.language, "en");
  assert.equal(english.text("statusYes"), "Yes");
  assert.equal(chinese.language, "zh-CN");
  assert.equal(chinese.text("statusYes"), "是");
  assert.equal(
    chinese.text("lastChecked", { date: "2026-07-28 12:00" }),
    "最近成功检查：2026-07-28 12:00",
  );
});

test("language helpers normalize and detect browser languages", () => {
  assert.equal(normalizeLanguage("zh-Hans-CN"), "zh-CN");
  assert.equal(normalizeLanguage("en-GB"), "en");
  assert.equal(detectBrowserLanguage(["fr-FR", "zh-CN"]), "zh-CN");
  assert.equal(createTranslator("zh-CN").language, "zh-CN");
});
