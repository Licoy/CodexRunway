import { createTranslator } from "./l10n.js";
import { classifyStatus } from "./status-logic.js";

const l10n = createTranslator(navigator.languages ?? [navigator.language]);
document.documentElement.lang = l10n.language;
localizeStaticContent();

const elements = {
  card: document.querySelector("#status-card"),
  value: document.querySelector("#status-value"),
  dot: document.querySelector("#status-dot"),
  detail: document.querySelector("#status-detail"),
  updated: document.querySelector("#updated"),
  events: document.querySelector("#events"),
  empty: document.querySelector("#empty"),
};

loadStatus();

async function loadStatus() {
  try {
    const response = await fetch("./api/status.json", { cache: "no-store" });
    if (!response.ok) throw new Error("status request failed");
    render(await response.json(), new Date());
  } catch {
    renderUnavailable();
  }
}

function render(feed, now) {
  const result = classifyStatus(feed, now);
  elements.card.dataset.state = result.state;
  elements.card.setAttribute("aria-busy", "false");
  const label = l10n.text(statusLabelKey(result.state));
  elements.value.textContent = label;
  elements.detail.textContent = statusDetail(result);
  elements.dot.title = label;
  elements.updated.textContent = formatUpdated(feed.lastSuccessfulCheckAt);
  renderEvents(Array.isArray(feed.events) ? feed.events : []);
}

function renderEvents(events) {
  elements.events.replaceChildren();
  elements.empty.hidden = events.length !== 0;
  for (const event of events.slice(0, 8)) {
    const item = document.createElement("li");
    const heading = document.createElement("div");
    const kind = document.createElement("strong");
    const time = document.createElement("time");
    const rationale = document.createElement("p");

    kind.textContent = l10n.text(eventLabelKey(event.kind));
    time.dateTime = event.announcedAt;
    time.textContent = formatDate(event.announcedAt);
    rationale.textContent = l10n.text(rationaleKey(event.kind));
    heading.append(kind, time);
    item.append(heading, rationale);
    if (event.kind === "reset_scheduled" && event.effectiveAt) {
      const schedule = document.createElement("p");
      schedule.className = "schedule";
      schedule.textContent = l10n.text("eventScheduledFor", {
        date: formatDate(event.effectiveAt),
      });
      item.append(schedule);
    }

    const source = safeSourceLink(event?.source?.url);
    if (source) item.append(source);
    elements.events.append(item);
  }
}

function safeSourceLink(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.hostname !== "x.com") return null;
    const link = document.createElement("a");
    link.href = url.href;
    link.rel = "noopener noreferrer";
    link.textContent = l10n.text("sourceLink");
    return link;
  } catch {
    return null;
  }
}

function renderUnavailable() {
  elements.card.dataset.state = "unknown";
  elements.card.setAttribute("aria-busy", "false");
  elements.value.textContent = l10n.text("statusUnknown");
  elements.detail.textContent = l10n.text("statusReadFailed");
  elements.updated.textContent = "";
  elements.events.replaceChildren();
  elements.empty.hidden = false;
}

function formatUpdated(value) {
  const date = new Date(value ?? "");
  return Number.isNaN(date.getTime())
    ? l10n.text("neverChecked")
    : l10n.text("lastChecked", { date: date.toLocaleString() });
}

function formatDate(value) {
  const date = new Date(value ?? "");
  return Number.isNaN(date.getTime()) ? l10n.text("unknownTime") : date.toLocaleString();
}

function localizeStaticContent() {
  for (const element of document.querySelectorAll("[data-i18n]")) {
    element.textContent = l10n.text(element.dataset.i18n);
  }
  for (const element of document.querySelectorAll("[data-i18n-content]")) {
    element.setAttribute("content", l10n.text(element.dataset.i18nContent));
  }
}

function statusLabelKey(state) {
  return {
    yes: "statusYes",
    no: "statusNo",
    unknown: "statusUnknown",
  }[state] ?? "statusUnknown";
}

function statusDetail(result) {
  if (result.reason === "reset") {
    return l10n.text("detailReset", {
      event: l10n.text(eventLabelKey(result.eventKind)),
    });
  }
  if (result.reason === "scheduled" && result.scheduledAt) {
    return l10n.text("detailScheduled", {
      date: formatDate(result.scheduledAt),
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

function rationaleKey(kind) {
  return {
    reset_completed: "rationaleResetCompleted",
    reset_scheduled: "rationaleResetScheduled",
    banked_reset: "rationaleBankedReset",
    limit_increase: "rationaleLimitIncrease",
    uncertain: "rationaleUncertain",
  }[kind] ?? "rationaleFallback";
}
