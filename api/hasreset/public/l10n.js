const TRANSLATIONS = Object.freeze({
  en: Object.freeze({
    metaDescription: "Unofficial Codex quota reset status derived from public X information.",
    pageTitle: "Did Codex reset today?",
    eyebrow: "CODEX RUNWAY · RESET WATCH",
    intro: "Evaluated against today in your browser's time zone.",
    currentVerdict: "Current verdict",
    loading: "Loading…",
    loadingDetail: "Reading the latest status…",
    recentEvidence: "Recent evidence",
    viewJSON: "View JSON",
    emptyEvents: "No related announcement was found in the recent monitoring window.",
    disclaimer: "Unofficial status · AI analysis of public information · Advisory only",
    privacy: "No analytics, cookies, forms, or user tracking.",
    statusYes: "Yes",
    statusNo: "No",
    statusUnknown: "Unknown",
    detailReset: "A {event} record is effective today.",
    detailUnavailable: "Monitoring data is unavailable or more than 30 hours old.",
    detailUncertain: "A relevant post was found today, but it cannot be classified safely.",
    detailNone: "No already-effective reset announcement was found today.",
    detailScheduled: "No reset is effective today yet. Next scheduled reset: {date}.",
    eventResetCompleted: "completed reset",
    eventResetScheduled: "scheduled reset",
    eventBankedReset: "banked reset",
    eventLimitIncrease: "limit increase",
    eventUncertain: "uncertain information",
    eventFallback: "related information",
    eventScheduledFor: "Scheduled for {date}.",
    rationaleResetCompleted: "An explicit Codex quota reset was announced.",
    rationaleResetScheduled: "An explicit Codex quota reset was scheduled.",
    rationaleBankedReset: "A banked reset was announced; this is not a completed reset.",
    rationaleLimitIncrease: "A quota limit increase was announced; this is not a reset.",
    rationaleUncertain: "The relevant announcement could not be classified safely.",
    rationaleFallback: "No derived explanation is available.",
    sourceLink: "View X source",
    statusReadFailed: "The status feed could not be loaded.",
    neverChecked: "No successful check has been published yet",
    lastChecked: "Last successful check: {date}",
    unknownTime: "Unknown time",
  }),
  "zh-CN": Object.freeze({
    metaDescription: "Codex Runway 根据公开 X 信息生成的非官方 Codex 配额重置状态。",
    pageTitle: "Codex 今日是否重置？",
    eyebrow: "CODEX RUNWAY · RESET WATCH",
    intro: "按当前浏览器时区的本地自然日判断。",
    currentVerdict: "当前结论",
    loading: "加载中…",
    loadingDetail: "正在读取最新状态…",
    recentEvidence: "最近依据",
    viewJSON: "查看 JSON",
    emptyEvents: "最近监控窗口内没有发现相关公告。",
    disclaimer: "非官方状态 · 由 AI 分析公开信息 · 仅供参考",
    privacy: "不使用分析、Cookie、表单或用户追踪。",
    statusYes: "是",
    statusNo: "否",
    statusUnknown: "未知",
    detailReset: "今天已有生效的{event}记录。",
    detailUnavailable: "监控数据不可用或已经超过 30 小时。",
    detailUncertain: "今天发现相关信息，但无法安全判断是否重置。",
    detailNone: "今天尚未发现已经生效的重置公告。",
    detailScheduled: "今天还没有生效的重置。下次计划重置：{date}。",
    eventResetCompleted: "已完成重置",
    eventResetScheduled: "已安排重置",
    eventBankedReset: "Banked reset",
    eventLimitIncrease: "提高额度",
    eventUncertain: "不明确信息",
    eventFallback: "相关信息",
    eventScheduledFor: "计划生效：{date}。",
    rationaleResetCompleted: "发现明确的 Codex 配额重置公告。",
    rationaleResetScheduled: "发现明确的 Codex 配额重置安排。",
    rationaleBankedReset: "公告涉及 banked reset，不代表已完成重置。",
    rationaleLimitIncrease: "公告涉及提高配额，不代表发生重置。",
    rationaleUncertain: "相关公告无法被安全分类。",
    rationaleFallback: "没有可显示的派生说明。",
    sourceLink: "查看 X 来源",
    statusReadFailed: "暂时无法读取状态数据。",
    neverChecked: "尚无成功检查记录",
    lastChecked: "最近成功检查：{date}",
    unknownTime: "时间未知",
  }),
});

export function createTranslator(languages = []) {
  const language = resolveLanguage(languages);
  const strings = TRANSLATIONS[language];
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
  return Object.keys(TRANSLATIONS[language] ?? {});
}

function resolveLanguage(languages) {
  for (const value of languages) {
    if (typeof value !== "string") continue;
    const normalized = value.toLowerCase();
    if (normalized.startsWith("zh")) return "zh-CN";
    if (normalized.startsWith("en")) return "en";
  }
  return "en";
}
