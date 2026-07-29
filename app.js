import {
  LANGUAGE_OPTIONS,
  THEME_OPTIONS,
  createTranslator,
  detectBrowserLanguage,
  normalizeLanguage,
} from "./l10n.js";
import { classifyStatus, nextScheduledReset } from "./status-logic.js";

const STORAGE_LANG = "hasreset-lang";
const STORAGE_THEME = "hasreset-theme";

const state = {
  language: loadLanguage(),
  theme: loadTheme(),
  feed: null,
  loadError: false,
  l10n: null,
};

const elements = {
  html: document.documentElement,
  card: document.querySelector("#status-card"),
  value: document.querySelector("#status-value"),
  emoji: document.querySelector("#status-emoji"),
  badge: document.querySelector("#state-badge"),
  detail: document.querySelector("#status-detail"),
  updated: document.querySelector("#updated"),
  monitorChip: document.querySelector("#monitor-chip"),
  monitorValue: document.querySelector("#monitor-value"),
  nextChip: document.querySelector("#next-chip"),
  nextValue: document.querySelector("#next-value"),
  events: document.querySelector("#events"),
  empty: document.querySelector("#empty"),
  livePill: document.querySelector("#live-pill"),
  langBtn: document.querySelector("#lang-btn"),
  langEmoji: document.querySelector("#lang-emoji"),
  langValue: document.querySelector("#lang-value"),
  themeBtn: document.querySelector("#theme-btn"),
  themeEmoji: document.querySelector("#theme-emoji"),
  themeValue: document.querySelector("#theme-value"),
};

bootstrap();

function bootstrap() {
  applyTheme(state.theme);
  applyLanguage(state.language);
  elements.langBtn?.addEventListener("click", cycleLanguage);
  elements.themeBtn?.addEventListener("click", cycleTheme);
  loadStatus();
}

async function loadStatus() {
  try {
    const response = await fetch("./api/status.json", { cache: "no-store" });
    if (!response.ok) throw new Error("status request failed");
    state.feed = await response.json();
    state.loadError = false;
  } catch {
    state.feed = null;
    state.loadError = true;
  }
  render();
}

function applyLanguage(language) {
  state.language = normalizeLanguage(language) ?? "en";
  state.l10n = createTranslator(state.language);
  elements.html.lang = state.language === "zh-CN" ? "zh-CN" : "en";
  document.title = state.l10n.text("pageTitle");
  localizeStaticContent();
  updateControlLabels();
}

function applyTheme(theme) {
  const next = THEME_OPTIONS.some((item) => item.id === theme) ? theme : "system";
  state.theme = next;
  elements.html.dataset.theme = next;
  updateControlLabels();
}

function cycleLanguage() {
  const index = LANGUAGE_OPTIONS.findIndex((item) => item.id === state.language);
  const next = LANGUAGE_OPTIONS[(index + 1) % LANGUAGE_OPTIONS.length];
  try {
    localStorage.setItem(STORAGE_LANG, next.id);
  } catch {
    // ignore
  }
  applyLanguage(next.id);
  render();
}

function cycleTheme() {
  const index = THEME_OPTIONS.findIndex((item) => item.id === state.theme);
  const next = THEME_OPTIONS[(index + 1) % THEME_OPTIONS.length];
  try {
    localStorage.setItem(STORAGE_THEME, next.id);
  } catch {
    // ignore
  }
  applyTheme(next.id);
}

function updateControlLabels() {
  const l10n = state.l10n;
  if (!l10n) return;

  const language = LANGUAGE_OPTIONS.find((item) => item.id === state.language)
    ?? LANGUAGE_OPTIONS[0];
  const theme = THEME_OPTIONS.find((item) => item.id === state.theme)
    ?? THEME_OPTIONS[0];

  if (elements.langEmoji) elements.langEmoji.textContent = language.emoji;
  if (elements.langValue) elements.langValue.textContent = language.label;
  if (elements.langBtn) {
    elements.langBtn.setAttribute(
      "aria-label",
      `${l10n.text("langButtonAria")}: ${language.emoji} ${language.label}`,
    );
  }

  if (elements.themeEmoji) elements.themeEmoji.textContent = theme.emoji;
  if (elements.themeValue) elements.themeValue.textContent = l10n.text(theme.labelKey);
  if (elements.themeBtn) {
    elements.themeBtn.setAttribute(
      "aria-label",
      `${l10n.text("themeButtonAria")}: ${theme.emoji} ${l10n.text(theme.labelKey)}`,
    );
  }
}

function render() {
  if (state.loadError || !state.feed) {
    renderUnavailable();
    return;
  }
  renderFeed(state.feed, new Date());
}

function renderFeed(feed, now) {
  const l10n = state.l10n;
  const result = classifyStatus(feed, now);
  elements.card.dataset.state = result.state;
  elements.card.setAttribute("aria-busy", "false");

  const label = l10n.text(statusLabelKey(result.state));
  elements.value.textContent = label;
  elements.badge.textContent = label;
  elements.emoji.textContent = l10n.text(statusEmojiKey(result.state));
  elements.detail.textContent = statusDetail(result, l10n);
  elements.updated.textContent = formatUpdatedShort(feed.lastSuccessfulCheckAt, l10n);

  const monitorStatus = feed?.monitor?.status === "ok" ? "ok" : "degraded";
  elements.monitorChip.dataset.monitor = monitorStatus;
  elements.monitorValue.textContent = monitorStatus === "ok"
    ? l10n.text("monitorOk")
    : l10n.text("monitorDegraded");

  if (elements.livePill) {
    elements.livePill.hidden = monitorStatus !== "ok";
  }

  const upcoming = result.reason === "scheduled" && result.scheduledAt
    ? { effectiveAt: result.scheduledAt }
    : nextScheduledReset(Array.isArray(feed.events) ? feed.events : [], now);

  if (upcoming?.effectiveAt) {
    elements.nextChip.dataset.hasNext = "true";
    elements.nextValue.textContent = formatDate(upcoming.effectiveAt, l10n);
  } else {
    elements.nextChip.dataset.hasNext = "false";
    elements.nextValue.textContent = l10n.text("nextNone");
  }

  renderEvents(Array.isArray(feed.events) ? feed.events : [], l10n);
}

function renderEvents(events, l10n) {
  elements.events.replaceChildren();
  elements.empty.hidden = events.length !== 0;

  events.slice(0, 8).forEach((event, index) => {
    const item = document.createElement("li");

    const indexEl = document.createElement("span");
    indexEl.className = "event-index";
    indexEl.textContent = String(index + 1).padStart(2, "0");

    const body = document.createElement("div");
    body.className = "event-body";

    const top = document.createElement("div");
    top.className = "event-top";

    const badge = document.createElement("span");
    badge.className = "kind-badge";
    badge.dataset.kind = event.kind || "uncertain";
    badge.textContent = `${eventKindEmoji(event.kind)} ${l10n.text(eventLabelKey(event.kind))}`;

    const time = document.createElement("time");
    time.dateTime = event.announcedAt;
    time.textContent = formatDate(event.announcedAt, l10n);

    top.append(badge, time);

    const rationale = document.createElement("p");
    rationale.textContent = l10n.text(rationaleKey(event.kind));
    body.append(top, rationale);

    if (event.kind === "reset_scheduled" && event.effectiveAt) {
      const schedule = document.createElement("p");
      schedule.className = "schedule";
      schedule.textContent = l10n.text("eventScheduledFor", {
        date: formatDate(event.effectiveAt, l10n),
      });
      body.append(schedule);
    }

    const chips = document.createElement("div");
    chips.className = "event-chips";
    for (const plan of event?.scope?.plans ?? []) {
      chips.append(chip(`${l10n.text("chipPlan")}:${plan}`));
    }
    for (const window of event?.scope?.windows ?? []) {
      chips.append(chip(`${l10n.text("chipWindow")}:${window}`));
    }
    if (typeof event.confidence === "number") {
      const confidence = chip(
        `${l10n.text("chipConfidence")} ${formatConfidence(event.confidence)}`,
      );
      confidence.classList.add("chip-confidence");
      chips.append(confidence);
    }
    if (chips.childNodes.length > 0) body.append(chips);

    const source = safeSourceLink(event?.source?.url, l10n);
    if (source) body.append(source);

    item.append(indexEl, body);
    elements.events.append(item);
  });
}

function chip(text) {
  const el = document.createElement("span");
  el.className = "chip";
  el.textContent = text;
  return el;
}

function safeSourceLink(value, l10n) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.hostname !== "x.com") return null;
    const link = document.createElement("a");
    link.className = "source-link";
    link.href = url.href;
    link.rel = "noopener noreferrer";
    link.target = "_blank";
    link.textContent = `↗ ${l10n.text("sourceLink")}`;
    return link;
  } catch {
    return null;
  }
}

function renderUnavailable() {
  const l10n = state.l10n;
  elements.card.dataset.state = "unknown";
  elements.card.setAttribute("aria-busy", "false");
  const label = l10n.text("statusUnknown");
  elements.value.textContent = label;
  elements.badge.textContent = label;
  elements.emoji.textContent = l10n.text("statusUnknownEmoji");
  elements.detail.textContent = l10n.text("statusReadFailed");
  elements.updated.textContent = "—";
  elements.monitorChip.dataset.monitor = "degraded";
  elements.monitorValue.textContent = l10n.text("monitorDegraded");
  elements.nextChip.dataset.hasNext = "false";
  elements.nextValue.textContent = l10n.text("nextNone");
  if (elements.livePill) elements.livePill.hidden = true;
  elements.events.replaceChildren();
  elements.empty.hidden = false;
}

function localizeStaticContent() {
  for (const element of document.querySelectorAll("[data-i18n]")) {
    element.textContent = state.l10n.text(element.dataset.i18n);
  }
  for (const element of document.querySelectorAll("[data-i18n-content]")) {
    element.setAttribute("content", state.l10n.text(element.dataset.i18nContent));
  }
}

function loadLanguage() {
  try {
    const saved = normalizeLanguage(localStorage.getItem(STORAGE_LANG));
    if (saved) return saved;
  } catch {
    // ignore
  }
  return detectBrowserLanguage();
}

function loadTheme() {
  try {
    const saved = localStorage.getItem(STORAGE_THEME);
    if (THEME_OPTIONS.some((item) => item.id === saved)) return saved;
  } catch {
    // ignore
  }
  return "system";
}

function formatUpdatedShort(value, l10n) {
  const date = new Date(value ?? "");
  return Number.isNaN(date.getTime())
    ? l10n.text("neverCheckedShort")
    : date.toLocaleString(localeFor(state.language));
}

function formatDate(value, l10n) {
  const date = new Date(value ?? "");
  return Number.isNaN(date.getTime())
    ? l10n.text("unknownTime")
    : date.toLocaleString(localeFor(state.language));
}

function localeFor(language) {
  return language === "zh-CN" ? "zh-CN" : "en-US";
}

function formatConfidence(value) {
  return `${Math.round(value * 100)}%`;
}

function statusLabelKey(stateName) {
  return {
    yes: "statusYes",
    no: "statusNo",
    unknown: "statusUnknown",
  }[stateName] ?? "statusUnknown";
}

function statusEmojiKey(stateName) {
  return {
    yes: "statusYesEmoji",
    no: "statusNoEmoji",
    unknown: "statusUnknownEmoji",
  }[stateName] ?? "statusUnknownEmoji";
}

function statusDetail(result, l10n) {
  if (result.reason === "reset") {
    return l10n.text("detailReset", {
      event: l10n.text(eventLabelKey(result.eventKind)),
    });
  }
  if (result.reason === "scheduled" && result.scheduledAt) {
    return l10n.text("detailScheduled", {
      date: formatDate(result.scheduledAt, l10n),
    });
  }
  return l10n.text({
    unavailable: "detailUnavailable",
    uncertain: "detailUncertain",
    none: "detailNone",
  }[result.reason] ?? "detailUnavailable");
}

function eventLabelKey(kind) {
  return {
    reset_completed: "eventResetCompleted",
    reset_scheduled: "eventResetScheduled",
    banked_reset: "eventBankedReset",
    limit_increase: "eventLimitIncrease",
    uncertain: "eventUncertain",
  }[kind] ?? "eventFallback";
}

function eventKindEmoji(kind) {
  return {
    reset_completed: "⚡",
    reset_scheduled: "📅",
    banked_reset: "🏦",
    limit_increase: "📈",
    uncertain: "❔",
  }[kind] ?? "•";
}

function rationaleKey(kind) {
  return {
    reset_completed: "rationaleResetCompleted",
    reset_scheduled: "rationaleResetScheduled",
    banked_reset: "rationaleBankedReset",
    limit_increase: "rationaleLimitIncrease",
    uncertain: "rationaleUncertain",
  }[kind] ?? "rationaleFallback";
}
