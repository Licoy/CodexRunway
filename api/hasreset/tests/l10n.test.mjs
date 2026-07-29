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

test("scope chip labels use plain language instead of raw enum values", () => {
  const english = createTranslator("en");
  const chinese = createTranslator("zh-CN");

  assert.equal(english.text("windowUnknown"), "Window not specified");
  assert.equal(english.text("windowFiveHour"), "5-hour window");
  assert.equal(english.text("windowWeekly"), "Weekly limit");
  assert.equal(english.text("planAll"), "All plans");
  assert.equal(chinese.text("windowUnknown"), "窗口未指明");
  assert.equal(chinese.text("windowFiveHour"), "5 小时窗口");
  assert.equal(chinese.text("windowWeekly"), "周额度");
  assert.equal(chinese.text("planAll"), "全部套餐");
  assert.equal(chinese.text("planUnknown"), "套餐未指明");
  assert.equal(chinese.text("chipWindow"), "额度窗口");
  assert.equal(chinese.text("chipConfidence"), "置信度");
});

test("language helpers normalize and detect browser languages", () => {
  assert.equal(normalizeLanguage("zh-Hans-CN"), "zh-CN");
  assert.equal(normalizeLanguage("en-GB"), "en");
  assert.equal(detectBrowserLanguage(["fr-FR", "zh-CN"]), "zh-CN");
  assert.equal(createTranslator("zh-CN").language, "zh-CN");
});
