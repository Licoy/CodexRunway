export const LANGUAGE_OPTIONS = Object.freeze([
  { id: "en", label: "English", emoji: "🇺🇸", short: "EN" },
  { id: "zh-CN", label: "中文", emoji: "🇨🇳", short: "中文" },
]);

export const THEME_OPTIONS = Object.freeze([
  { id: "system", labelKey: "themeSystem", emoji: "🖥️" },
  { id: "light", labelKey: "themeLight", emoji: "☀️" },
  { id: "dark", labelKey: "themeDark", emoji: "🌙" },
]);

const TRANSLATIONS = Object.freeze({
  en: Object.freeze({
    metaDescription: "Unofficial Codex quota reset status derived from public X information.",
    pageTitle: "Did Codex reset today?",
    brandName: "Codex Runway",
    brandTag: "Reset Watch",
    liveLabel: "Live",
    offlineLabel: "Offline",
    intro: "Local calendar day in your browser timezone · signals from @thsottiaux",
    currentVerdict: "Today's answer",
    loading: "Syncing…",
    loadingDetail: "Pulling the latest monitor feed…",
    monitorLabel: "Feed health",
    checkedLabel: "Last check",
    nextLabel: "Next schedule",
    nextNone: "None detected",
    monitorOk: "Healthy",
    monitorDegraded: "Degraded",
    evidenceKicker: "Signal log",
    recentEvidence: "Evidence stream",
    viewJSON: "JSON",
    emptyEvents: "No quota signals in the monitoring window.",
    disclaimer: "Unofficial · AI-classified public X posts · Advisory only",
    privacy: "No analytics · No cookies · No tracking",
    statusYes: "Yes",
    statusNo: "No",
    statusUnknown: "Unknown",
    statusYesEmoji: "✅",
    statusNoEmoji: "🚫",
    statusUnknownEmoji: "❔",
    detailReset: "An effective {event} is on the board for your local day.",
    detailUnavailable: "Feed is stale or unreachable (>30h).",
    detailUncertain: "A same-day signal exists but cannot be classified safely.",
    detailNone: "No already-effective reset found for your local day.",
    detailScheduled: "Nothing effective yet today. Next scheduled reset: {date}.",
    eventResetCompleted: "Completed",
    eventResetScheduled: "Scheduled",
    eventBankedReset: "Banked",
    eventLimitIncrease: "Limit up",
    eventUncertain: "Uncertain",
    eventFallback: "Related",
    eventScheduledFor: "Effective {date}",
    chipPlan: "plan",
    chipWindow: "window",
    chipConfidence: "conf",
    rationaleResetCompleted: "Explicit Codex quota reset announcement.",
    rationaleResetScheduled: "Explicit future reset schedule.",
    rationaleBankedReset: "Banked reset grant — not a completed reset.",
    rationaleLimitIncrease: "Quota raised / window restored — not a full reset.",
    rationaleUncertain: "Could not classify this signal safely.",
    rationaleFallback: "No derived explanation.",
    sourceLink: "Open on X",
    statusReadFailed: "Could not load status.json.",
    neverChecked: "No successful check yet",
    neverCheckedShort: "—",
    lastChecked: "Last successful check: {date}",
    unknownTime: "Unknown time",
    langButtonAria: "Switch language",
    themeButtonAria: "Switch color mode",
    themeSystem: "Auto",
    themeLight: "Light",
    themeDark: "Dark",
    controlLang: "Language",
    controlTheme: "Theme",
  }),
  "zh-CN": Object.freeze({
    metaDescription: "Codex Runway 根据公开 X 信息生成的非官方 Codex 配额重置状态。",
    pageTitle: "Codex 今日是否重置？",
    brandName: "Codex Runway",
    brandTag: "重置观察",
    liveLabel: "实时",
    offlineLabel: "离线",
    intro: "按浏览器本地自然日判断 · 信号来自 @thsottiaux",
    currentVerdict: "今日结论",
    loading: "同步中…",
    loadingDetail: "正在拉取最新监控数据…",
    monitorLabel: "数据健康",
    checkedLabel: "最近检查",
    nextLabel: "下次计划",
    nextNone: "暂无",
    monitorOk: "健康",
    monitorDegraded: "降级",
    evidenceKicker: "信号日志",
    recentEvidence: "证据流",
    viewJSON: "JSON",
    emptyEvents: "监控窗口内没有配额相关信号。",
    disclaimer: "非官方 · AI 分类公开 X 动态 · 仅供参考",
    privacy: "无分析 · 无 Cookie · 无追踪",
    statusYes: "是",
    statusNo: "否",
    statusUnknown: "未知",
    statusYesEmoji: "✅",
    statusNoEmoji: "🚫",
    statusUnknownEmoji: "❔",
    detailReset: "本地今天已有生效的{event}记录。",
    detailUnavailable: "数据不可用或已超过 30 小时。",
    detailUncertain: "今天有相关信号，但无法安全分类。",
    detailNone: "今天还没有已经生效的重置记录。",
    detailScheduled: "今天尚未生效。下次计划重置：{date}。",
    eventResetCompleted: "已完成",
    eventResetScheduled: "已排期",
    eventBankedReset: "Banked",
    eventLimitIncrease: "提额",
    eventUncertain: "待定",
    eventFallback: "相关",
    eventScheduledFor: "生效 {date}",
    chipPlan: "套餐",
    chipWindow: "窗口",
    chipConfidence: "置信",
    rationaleResetCompleted: "明确的配额重置公告。",
    rationaleResetScheduled: "明确的未来重置安排。",
    rationaleBankedReset: "Banked reset，不代表已完成重置。",
    rationaleLimitIncrease: "额度/窗口提升，不代表完整重置。",
    rationaleUncertain: "该信号无法被安全分类。",
    rationaleFallback: "暂无说明。",
    sourceLink: "在 X 打开",
    statusReadFailed: "无法加载 status.json。",
    neverChecked: "尚无成功检查",
    neverCheckedShort: "—",
    lastChecked: "最近成功检查：{date}",
    unknownTime: "时间未知",
    langButtonAria: "切换语言",
    themeButtonAria: "切换颜色模式",
    themeSystem: "跟随系统",
    themeLight: "浅色",
    themeDark: "深色",
    controlLang: "语言",
    controlTheme: "外观",
  }),
});

export function createTranslator(languageOrList = "en") {
  const language = Array.isArray(languageOrList)
    ? resolveLanguage(languageOrList)
    : normalizeLanguage(languageOrList);
  const strings = TRANSLATIONS[language] ?? TRANSLATIONS.en;
  return {
    language,
    text(key, values = {}) {
      const template = strings[key] ?? TRANSLATIONS.en[key] ?? key;
      return template.replace(/\{([a-zA-Z]+)\}/g, (_, name) => (
        Object.prototype.hasOwnProperty.call(values, name)
          ? String(values[name])
          : `{${name}}`
      ));
    },
  };
}

export function translationKeys(language) {
  return Object.keys(TRANSLATIONS[normalizeLanguage(language)] ?? {});
}

export function resolveLanguage(languages = []) {
  for (const value of languages) {
    const normalized = normalizeLanguage(value);
    if (normalized) return normalized;
  }
  return "en";
}

export function normalizeLanguage(value) {
  if (typeof value !== "string") return null;
  const normalized = value.toLowerCase();
  if (normalized === "zh-cn" || normalized.startsWith("zh")) return "zh-CN";
  if (normalized === "en" || normalized.startsWith("en")) return "en";
  return null;
}

export function detectBrowserLanguage(languages = navigator.languages ?? [navigator.language]) {
  return resolveLanguage(languages);
}
