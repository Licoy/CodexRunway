import {
  LANGUAGE_OPTIONS,
  THEME_OPTIONS,
  createTranslator,
  detectBrowserLanguage,
  normalizeLanguage,
} from "./l10n.js?ver=1785495309205";
import { classifyStatus, nextScheduledReset } from "./status-logic.js?ver=1785495309205";
import {
  formatTiboClock,
  inspectTiboLocalTime,
} from "./tibo-radar.js?ver=1785495309205";

const STORAGE_LANG = "hasreset-lang";
const STORAGE_THEME = "hasreset-theme";

/** DEV: preview every activity tag style at once. Turn off before ship. */
const DEV_SHOW_ALL_ACTIVITY_TAGS = false;

const state = {
  language: loadLanguage(),
  theme: loadTheme(),
  feed: null,
  loadError: false,
  l10n: null,
  countdownTimer: null,
  clockTimer: null,
  tiboChipSignature: null,
};

const elements = {
  html: document.documentElement,
  card: document.querySelector("#status-card"),
  value: document.querySelector("#status-value"),
  badge: document.querySelector("#state-badge"),
  detail: document.querySelector("#status-detail"),
  countdown: document.querySelector("#status-countdown"),
  updated: document.querySelector("#updated"),
  monitorChip: document.querySelector("#monitor-chip"),
  monitorValue: document.querySelector("#monitor-value"),
  nextChip: document.querySelector("#next-chip"),
  nextValue: document.querySelector("#next-value"),
  events: document.querySelector("#events"),
  empty: document.querySelector("#empty"),
  tiboTime: document.querySelector("#tibo-time"),
  tiboZone: document.querySelector("#tibo-zone"),
  tiboMeta: document.querySelector("#tibo-meta"),
  tiboRegion: document.querySelector("#tibo-region"),
  langBtn: document.querySelector("#lang-btn"),
  langIcon: document.querySelector("#lang-icon"),
  langValue: document.querySelector("#lang-value"),
  themeBtn: document.querySelector("#theme-btn"),
  themeIcon: document.querySelector("#theme-icon"),
  themeValue: document.querySelector("#theme-value"),
  githubBtn: document.querySelector("#github-btn"),
};

bootstrap();

function bootstrap() {
  applyTheme(state.theme);
  applyLanguage(state.language);
  elements.langBtn?.addEventListener("click", cycleLanguage);
  elements.themeBtn?.addEventListener("click", cycleTheme);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
      updateCountdowns();
      renderTiboRadar();
    }
  });
  startClockTicker();
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
  renderTiboRadar();
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

  if (elements.langIcon) elements.langIcon.className = `control-icon ${language.icon}`;
  if (elements.langValue) elements.langValue.textContent = language.label;
  if (elements.langBtn) {
    elements.langBtn.setAttribute(
      "aria-label",
      `${l10n.text("langButtonAria")}: ${language.label}`,
    );
  }

  if (elements.themeIcon) elements.themeIcon.className = `control-icon ${theme.icon}`;
  if (elements.themeValue) elements.themeValue.textContent = l10n.text(theme.labelKey);
  if (elements.themeBtn) {
    elements.themeBtn.setAttribute(
      "aria-label",
      `${l10n.text("themeButtonAria")}: ${l10n.text(theme.labelKey)}`,
    );
  }

  if (elements.githubBtn) {
    elements.githubBtn.setAttribute("aria-label", l10n.text("githubButtonAria"));
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
  setConfidenceBadge(result.confidence, l10n);
  elements.detail.textContent = statusDetail(result, l10n);
  elements.updated.textContent = formatUpdatedShort(feed.lastSuccessfulCheckAt, l10n);

  const monitorStatus = feed?.monitor?.status === "ok" ? "ok" : "degraded";
  elements.monitorChip.dataset.monitor = monitorStatus;
  elements.monitorValue.textContent = monitorStatus === "ok"
    ? l10n.text("monitorOk")
    : l10n.text("monitorDegraded");

  const upcoming = (result.reason === "scheduled" || result.reason === "scheduled_today")
    && result.scheduledAt
    ? { effectiveAt: result.scheduledAt }
    : nextScheduledReset(Array.isArray(feed.events) ? feed.events : [], now);

  if (upcoming?.effectiveAt) {
    elements.nextChip.dataset.hasNext = "true";
    elements.nextValue.textContent = formatDate(upcoming.effectiveAt, l10n);
  } else {
    elements.nextChip.dataset.hasNext = "false";
    elements.nextValue.textContent = l10n.text("nextNone");
  }

  // When the verdict names a future reset time, show a live relative countdown
  // on its own line (same wording as the signal log, without surrounding parens).
  const verdictScheduleAt = (result.reason === "scheduled" || result.reason === "scheduled_today")
    ? result.scheduledAt
    : null;
  setVerdictCountdown(verdictScheduleAt, now, l10n);

  renderEvents(Array.isArray(feed.events) ? feed.events : [], l10n, now);
}

function setConfidenceBadge(confidence, l10n) {
  if (!elements.badge) return;
  if (typeof confidence !== "number" || !Number.isFinite(confidence)) {
    elements.badge.hidden = true;
    elements.badge.replaceChildren();
    elements.badge.textContent = "";
    return;
  }

  const label = `${l10n.text("chipConfidence")} ${formatConfidence(confidence)}`.trim();
  if (!label) {
    elements.badge.hidden = true;
    elements.badge.replaceChildren();
    return;
  }

  elements.badge.hidden = false;
  elements.badge.replaceChildren(
    icon("czs-bar-chart-l"),
    document.createTextNode(label),
  );
}

function renderEvents(events, l10n, now = new Date()) {
  elements.events.replaceChildren();
  const ordered = sortEventsByNewest(Array.isArray(events) ? events : []);
  elements.empty.hidden = ordered.length !== 0;

  ordered.slice(0, 8).forEach((event, index) => {
    const item = document.createElement("li");
    item.dataset.kind = event.kind || "uncertain";
    const pendingSchedule = isPendingScheduled(event, now);
    if (pendingSchedule) item.dataset.pending = "true";

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
    if (pendingSchedule) badge.dataset.pending = "true";
    badge.append(
      icon(eventKindIcon(event.kind)),
      document.createTextNode(l10n.text(eventLabelKey(event.kind))),
    );

    const time = document.createElement("time");
    time.dateTime = event.announcedAt;
    time.append(
      icon("czs-time-l"),
      document.createTextNode(formatDate(event.announcedAt, l10n)),
    );

    top.append(badge, time);

    const rationale = document.createElement("p");
    rationale.textContent = l10n.text(rationaleKey(event.kind));
    body.append(top, rationale);

    if (event.kind === "reset_scheduled" && event.effectiveAt) {
      const schedule = document.createElement("p");
      schedule.className = "schedule";
      schedule.append(icon("czs-calendar-l"));

      if (pendingSchedule) {
        schedule.append(
          document.createTextNode(`${l10n.text("eventScheduledForLabel")} `),
        );
        const when = document.createElement("strong");
        when.className = "schedule-when";
        when.textContent = formatDate(event.effectiveAt, l10n);
        schedule.append(when);

        const countdown = formatCountdown(event.effectiveAt, now, l10n);
        if (countdown) {
          const rel = document.createElement("span");
          rel.className = "schedule-relative";
          rel.dataset.effectiveAt = event.effectiveAt;
          rel.dataset.countdownFormat = "paren";
          rel.textContent = ` (${countdown})`;
          schedule.append(rel);
        }
      } else {
        schedule.append(document.createTextNode(l10n.text("eventScheduledFor", {
          date: formatDate(event.effectiveAt, l10n),
        })));
      }

      body.append(schedule);
    }

    const chips = document.createElement("div");
    chips.className = "event-chips";
    for (const plan of uniqueStrings(event?.scope?.plans)) {
      chips.append(chip(
        formatPlanChip(plan, l10n),
        `plan-${plan}`,
        "czs-tag-l",
      ));
    }
    for (const windowName of uniqueStrings(event?.scope?.windows)) {
      chips.append(chip(
        formatWindowChip(windowName, l10n),
        `window-${windowName}`,
        "czs-clock-l",
      ));
    }
    if (typeof event.confidence === "number") {
      const confidence = chip(
        `${l10n.text("chipConfidence")} ${formatConfidence(event.confidence)}`,
        "confidence",
        "czs-bar-chart-l",
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

  syncCountdownTicker();
}

function syncCountdownTicker() {
  const hasLive = document.querySelector(".schedule-relative[data-effective-at]");
  if (!hasLive) {
    stopCountdownTicker();
    return;
  }
  if (state.countdownTimer == null) {
    state.countdownTimer = setInterval(updateCountdowns, 1000);
  }
  updateCountdowns();
}

function stopCountdownTicker() {
  if (state.countdownTimer != null) {
    clearInterval(state.countdownTimer);
    state.countdownTimer = null;
  }
}

/** Always-on 1s ticker for Tibo local clock (independent of reset countdowns). */
function startClockTicker() {
  if (state.clockTimer != null) return;
  renderTiboRadar();
  state.clockTimer = setInterval(renderTiboRadar, 1000);
}

function renderTiboRadar(now = new Date()) {
  const l10n = state.l10n;
  if (!l10n || !elements.tiboTime) return;

  const snap = inspectTiboLocalTime(now);
  const clock = formatTiboClock(snap, state.language);

  elements.tiboTime.textContent = clock.dateTime;
  if (elements.tiboZone) {
    elements.tiboZone.textContent = `${snap.timeZone} · ${clock.zone}`;
  }
  if (elements.tiboRegion) {
    elements.tiboRegion.textContent = l10n.text(snap.regionKey);
  }

  renderTiboChips(snap, l10n);
}

function renderTiboChips(snap, l10n) {
  if (!elements.tiboMeta) return;

  // Avoid rebuilding every second (restarts shimmer). Only refresh when the
  // visible set of tags / labels would change.
  const signature = DEV_SHOW_ALL_ACTIVITY_TAGS
    ? `dev|${state.language}|${snap.dayType}|${snap.holidayId ?? ""}`
    : `${state.language}|${snap.activity}|${snap.dayType}|${snap.holidayId ?? ""}`;
  if (state.tiboChipSignature === signature) return;
  state.tiboChipSignature = signature;

  if (DEV_SHOW_ALL_ACTIVITY_TAGS) {
    elements.tiboMeta.replaceChildren(
      tiboActivityChip("working", l10n),
      tiboActivityChip("sleeping", l10n),
      tiboActivityChip("off", l10n),
      tiboDaytypeChip(snap, l10n),
    );
    return;
  }

  elements.tiboMeta.replaceChildren(
    tiboActivityChip(snap.activity, l10n),
    tiboDaytypeChip(snap, l10n),
  );
}

function tiboActivityChip(activity, l10n) {
  const el = document.createElement("span");
  el.className = "tibo-chip";
  el.dataset.activity = activity;
  el.append(
    icon(tiboActivityIcon(activity)),
    document.createTextNode(tiboActivityLabel(activity, l10n)),
  );
  return el;
}

function tiboDaytypeChip(snap, l10n) {
  const el = document.createElement("span");
  el.className = "tibo-chip";
  el.dataset.daytype = snap.dayType;
  el.append(
    icon(tiboDaytypeIcon(snap.dayType)),
    document.createTextNode(tiboDaytypeLabel(snap, l10n)),
  );
  return el;
}

function tiboActivityIcon(activity) {
  return {
    working: "czs-sun-l",
    sleeping: "czs-moon-l",
    off: "czs-clock-l",
  }[activity] ?? "czs-clock-l";
}

function tiboActivityLabel(activity, l10n) {
  return {
    working: l10n.text("tiboActivityWorking"),
    sleeping: l10n.text("tiboActivitySleeping"),
    off: l10n.text("tiboActivityOff"),
  }[activity] ?? l10n.text("tiboActivityOff");
}

function tiboDaytypeIcon(dayType) {
  return {
    weekday: "czs-calendar-l",
    weekend: "czs-calendar-l",
    holiday: "czs-star-l",
  }[dayType] ?? "czs-calendar-l";
}

function tiboDaytypeLabel(snap, l10n) {
  if (snap.dayType === "holiday") {
    return l10n.text("tiboDayHoliday", {
      name: tiboHolidayName(snap.holidayId, l10n),
    });
  }
  if (snap.dayType === "weekend") return l10n.text("tiboDayWeekend");
  return l10n.text("tiboDayWeekday");
}

function tiboHolidayName(holidayId, l10n) {
  const key = {
    newYear: "tiboHolidayNewYear",
    mlk: "tiboHolidayMlk",
    presidents: "tiboHolidayPresidents",
    memorial: "tiboHolidayMemorial",
    juneteenth: "tiboHolidayJuneteenth",
    independence: "tiboHolidayIndependence",
    laborDay: "tiboHolidayLaborDay",
    indigenousPeoples: "tiboHolidayIndigenousPeoples",
    veterans: "tiboHolidayVeterans",
    thanksgiving: "tiboHolidayThanksgiving",
    christmas: "tiboHolidayChristmas",
  }[holidayId];
  return l10n.text(key ?? "tiboHolidayFallback");
}

function updateCountdowns() {
  const l10n = state.l10n;
  if (!l10n) return;

  const nodes = document.querySelectorAll(".schedule-relative[data-effective-at]");
  if (nodes.length === 0) {
    stopCountdownTicker();
    return;
  }

  const now = new Date();
  let stillPending = false;
  for (const el of nodes) {
    const text = formatCountdown(el.dataset.effectiveAt, now, l10n);
    if (text) {
      el.textContent = el.dataset.countdownFormat === "paren" ? ` (${text})` : text;
      el.hidden = false;
      stillPending = true;
    } else {
      el.textContent = "";
      el.hidden = true;
      delete el.dataset.effectiveAt;
    }
  }

  // Countdown hit zero: re-render so pending styles / next schedule refresh.
  if (!stillPending && state.feed && !state.loadError) {
    stopCountdownTicker();
    render();
  }
}

function setVerdictCountdown(effectiveAt, now, l10n) {
  const el = elements.countdown;
  if (!el) return;

  const text = formatCountdown(effectiveAt, now, l10n);
  if (!text || !effectiveAt) {
    el.hidden = true;
    el.textContent = "";
    delete el.dataset.effectiveAt;
    return;
  }

  el.dataset.effectiveAt = effectiveAt;
  el.textContent = text;
  el.hidden = false;
}

function sortEventsByNewest(events) {
  return [...events].sort((left, right) => {
    const byTime = String(right?.announcedAt ?? "").localeCompare(String(left?.announcedAt ?? ""));
    if (byTime !== 0) return byTime;
    return String(right?.source?.postId ?? "").localeCompare(String(left?.source?.postId ?? ""));
  });
}

function uniqueStrings(values) {
  if (!Array.isArray(values)) return [];
  return [...new Set(values.filter((value) => typeof value === "string" && value.length > 0))];
}

function formatPlanChip(plan, l10n) {
  return `${l10n.text("chipPlan")} · ${planLabel(plan, l10n)}`;
}

function formatWindowChip(windowName, l10n) {
  return `${l10n.text("chipWindow")} · ${windowLabel(windowName, l10n)}`;
}

function planLabel(plan, l10n) {
  switch (plan) {
    case "all":
      return l10n.text("planAll");
    case "free":
      return l10n.text("planFree");
    case "plus":
      return l10n.text("planPlus");
    case "pro":
      return l10n.text("planPro");
    case "team":
      return l10n.text("planTeam");
    case "business":
      return l10n.text("planBusiness");
    case "enterprise":
      return l10n.text("planEnterprise");
    case "unknown":
      return l10n.text("planUnknown");
    default:
      return plan;
  }
}

function windowLabel(windowName, l10n) {
  switch (windowName) {
    case "weekly":
      return l10n.text("windowWeekly");
    case "five_hour":
      return l10n.text("windowFiveHour");
    case "unknown":
      return l10n.text("windowUnknown");
    default:
      return windowName;
  }
}

function chip(text, kind = null, iconName = null) {
  const el = document.createElement("span");
  el.className = "chip";
  if (kind) el.dataset.kind = kind;
  if (iconName) el.append(icon(iconName));
  el.append(document.createTextNode(text));
  return el;
}

function icon(name) {
  const el = document.createElement("i");
  el.className = name;
  el.setAttribute("aria-hidden", "true");
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
    link.append(
      icon("czs-out-l"),
      document.createTextNode(l10n.text("sourceLink")),
    );
    return link;
  } catch {
    return null;
  }
}

function renderUnavailable() {
  const l10n = state.l10n;
  stopCountdownTicker();
  elements.card.dataset.state = "unknown";
  elements.card.setAttribute("aria-busy", "false");
  elements.value.textContent = l10n.text("statusUnknown");
  setConfidenceBadge(null, l10n);
  elements.detail.textContent = l10n.text("statusReadFailed");
  setVerdictCountdown(null, new Date(), l10n);
  elements.updated.textContent = "—";
  elements.monitorChip.dataset.monitor = "degraded";
  elements.monitorValue.textContent = l10n.text("monitorDegraded");
  elements.nextChip.dataset.hasNext = "false";
  elements.nextValue.textContent = l10n.text("nextNone");
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

/**
 * Live countdown in the browser's local timezone: "N小时N分钟N秒后" / "Nh Nm Ns later".
 */
function formatCountdown(value, now = new Date(), l10n = state.l10n) {
  const target = new Date(value ?? "");
  if (Number.isNaN(target.getTime()) || !l10n) return null;
  const diffMs = target.getTime() - now.getTime();
  if (diffMs <= 0) return null;

  const totalSeconds = Math.floor(diffMs / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  return l10n.text("relativeCountdown", {
    hours: String(hours),
    minutes: String(minutes),
    seconds: String(seconds),
  });
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

function statusDetail(result, l10n) {
  if (result.reason === "reset") {
    return l10n.text("detailReset", {
      event: l10n.text(eventLabelKey(result.eventKind)),
    });
  }
  if (result.reason === "scheduled_today" && result.scheduledAt) {
    return l10n.text("detailScheduledToday", {
      date: formatDate(result.scheduledAt, l10n),
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

function eventKindIcon(kind) {
  return {
    reset_completed: "czs-lightning",
    reset_scheduled: "czs-calendar",
    banked_reset: "czs-box",
    limit_increase: "czs-bar-chart",
    uncertain: "czs-warning-l",
  }[kind] ?? "czs-label-info-l";
}

/** Scheduled reset that has not become effective yet. */
function isPendingScheduled(event, now = new Date()) {
  if (event?.kind !== "reset_scheduled") return false;
  const when = new Date(event.effectiveAt ?? "");
  return !Number.isNaN(when.getTime()) && when.getTime() > now.getTime();
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
