export const LANGUAGE_OPTIONS = Object.freeze([
  { id: "en", label: "English", icon: "czs-earth-l", short: "EN" },
  { id: "zh-CN", label: "中文", icon: "czs-earth-l", short: "中文" },
]);

export const THEME_OPTIONS = Object.freeze([
  { id: "system", labelKey: "themeSystem", icon: "czs-computer-l" },
  { id: "light", labelKey: "themeLight", icon: "czs-sun-l" },
  { id: "dark", labelKey: "themeDark", icon: "czs-moon-l" },
]);

const TRANSLATIONS = Object.freeze({
  en: Object.freeze({
    metaDescription:
      "Unofficial live status for whether Codex quota resets today — completed or still scheduled. Monitors public signals and shows recent evidence — advisory only.",
    metaKeywords:
      "Codex, Codex reset, quota reset, rate limit, ChatGPT Codex, Codex Runway, OpenAI Codex, reset status, weekly limit",
    pageTitle: "Does Codex Reset Today? · Codex Runway",
    ogLocale: "en_US",
    ogImageAlt: "Codex Runway app icon",
    brandName: "Codex Runway",
    brandTag: "Reset Watch",
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
    viewJSON: "JSON",
    emptyEvents: "No quota signals in the monitoring window",
    disclaimer: "Unofficial · AI-classified public X posts · Advisory only",
    privacy: "No analytics · No cookies · No tracking",
    statusYes: "Yes",
    statusNo: "No",
    statusUnknown: "Unknown",
    detailReset: "An effective {event} is on the board for your local day",
    detailUnavailable: "Feed is stale or unreachable (>30h)",
    detailUncertain: "A same-day signal exists, but cannot be classified safely",
    detailNone: "No reset completed or scheduled for your local day",
    detailScheduled: "No reset for your local day; next scheduled: {date}",
    detailScheduledToday: "Reset scheduled for later today: {date}",
    eventResetCompleted: "Completed",
    eventResetScheduled: "Scheduled",
    eventBankedReset: "Banked",
    eventLimitIncrease: "Limit up",
    eventUncertain: "Uncertain",
    eventFallback: "Related",
    eventScheduledFor: "Effective {date}",
    eventScheduledForLabel: "Effective",
    relativeCountdown: "{hours}h {minutes}m {seconds}s later",
    chipPlan: "Plans",
    chipWindow: "Limit window",
    chipConfidence: "Confidence",
    planAll: "All plans",
    planFree: "Free",
    planPlus: "Plus",
    planPro: "Pro",
    planTeam: "Team",
    planBusiness: "Business",
    planEnterprise: "Enterprise",
    planUnknown: "Plan not specified",
    windowWeekly: "Weekly limit",
    windowFiveHour: "5-hour window",
    windowUnknown: "Window not specified",
    rationaleResetCompleted: "Explicit Codex quota reset announcement",
    rationaleResetScheduled: "Explicit future reset schedule",
    rationaleBankedReset: "Banked reset grant — not a completed reset",
    rationaleLimitIncrease: "Quota raised / window restored — not a full reset",
    rationaleUncertain: "Could not classify this signal safely",
    rationaleFallback: "No derived explanation",
    sourceLink: "Open on X",
    githubLink: "GitHub · Licoy/codex-runway",
    statusReadFailed: "Could not load status.json",
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
    metaDescription:
      "非官方 Codex 配额重置状态：今日是否有重置（已生效或已排期）、下次计划与公开信号证据流，由 Codex Runway 根据公开信息生成，仅供参考。",
    metaKeywords:
      "Codex, Codex 重置, 配额重置, 额度重置, 速率限制, Codex Runway, OpenAI Codex, 今日是否重置, 周额度",
    pageTitle: "Codex 今日是否有重置？· Codex Runway",
    ogLocale: "zh_CN",
    ogImageAlt: "Codex Runway 应用图标",
    brandName: "Codex Runway",
    brandTag: "重置观察",
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
    viewJSON: "JSON",
    emptyEvents: "监控窗口内没有配额相关信号",
    disclaimer: "非官方 · AI 分类公开 X 动态 · 仅供参考",
    privacy: "无分析 · 无 Cookie · 无追踪",
    statusYes: "是",
    statusNo: "否",
    statusUnknown: "未知",
    detailReset: "本地今天已有生效的{event}记录",
    detailUnavailable: "数据不可用或已超过 30 小时",
    detailUncertain: "今天有相关信号，但无法安全分类",
    detailNone: "本地今天没有已完成或已排期的重置",
    detailScheduled: "本地今天没有重置；下次计划：{date}",
    detailScheduledToday: "今日计划重置：{date}",
    eventResetCompleted: "已完成",
    eventResetScheduled: "已排期",
    eventBankedReset: "Banked",
    eventLimitIncrease: "提额",
    eventUncertain: "待定",
    eventFallback: "相关",
    eventScheduledFor: "生效 {date}",
    eventScheduledForLabel: "生效",
    relativeCountdown: "{hours}小时{minutes}分钟{seconds}秒后",
    chipPlan: "套餐",
    chipWindow: "额度窗口",
    chipConfidence: "置信度",
    planAll: "全部套餐",
    planFree: "Free",
    planPlus: "Plus",
    planPro: "Pro",
    planTeam: "Team",
    planBusiness: "Business",
    planEnterprise: "Enterprise",
    planUnknown: "套餐未指明",
    windowWeekly: "周额度",
    windowFiveHour: "5 小时窗口",
    windowUnknown: "窗口未指明",
    rationaleResetCompleted: "明确的配额重置公告",
    rationaleResetScheduled: "明确的未来重置安排",
    rationaleBankedReset: "Banked reset，不代表已完成重置",
    rationaleLimitIncrease: "额度/窗口提升，不代表完整重置",
    rationaleUncertain: "该信号无法被安全分类",
    rationaleFallback: "暂无说明",
    sourceLink: "在 X 打开",
    githubLink: "GitHub · Licoy/codex-runway",
    statusReadFailed: "无法加载 status.json",
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
