import { createTranslator } from "./l10n.js";
import { classifyStatus } from "./status-logic.js";

const l10n = createTranslator(navigator.languages ?? [navigator.language]);
document.documentElement.lang = l10n.language;
localizeStaticContent();

const elements = {
  card: document.querySelector("#status-card"),
  value: document.querySelector("#status-value"),
  badge: document.querySelector("#state-badge"),
  detail: document.querySelector("#status-detail"),
  updated: document.querySelector("#updated"),
  monitorChip: document.querySelector("#monitor-chip"),
  monitorValue: document.querySelector("#monitor-value"),
  events: document.querySelector("#events"),
  empty: document.querySelector("#empty"),
  livePill: document.querySelector("#live-pill"),
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
  elements.badge.textContent = label;
  elements.detail.textContent = statusDetail(result);
  elements.updated.textContent = formatUpdatedShort(feed.lastSuccessfulCheckAt);

  const monitorStatus = feed?.monitor?.status === "ok" ? "ok" : "degraded";
  elements.monitorChip.dataset.monitor = monitorStatus;
  elements.monitorValue.textContent = monitorStatus === "ok"
    ? l10n.text("monitorOk")
    : l10n.text("monitorDegraded");

  if (elements.livePill) {
    elements.livePill.hidden = monitorStatus !== "ok";
  }

  renderEvents(Array.isArray(feed.events) ? feed.events : []);
}

function renderEvents(events) {
  elements.events.replaceChildren();
  elements.empty.hidden = events.length !== 0;

  for (const event of events.slice(0, 8)) {
    const item = document.createElement("li");
    const top = document.createElement("div");
    top.className = "event-top";

    const badge = document.createElement("span");
    badge.className = "kind-badge";
    badge.dataset.kind = event.kind || "uncertain";
    badge.textContent = l10n.text(eventLabelKey(event.kind));

    const time = document.createElement("time");
    time.dateTime = event.announcedAt;
    time.textContent = formatDate(event.announcedAt);

    top.append(badge, time);

    const rationale = document.createElement("p");
    rationale.textContent = l10n.text(rationaleKey(event.kind));

    item.append(top, rationale);

    if (event.kind === "reset_scheduled" && event.effectiveAt) {
      const schedule = document.createElement("p");
      schedule.className = "schedule";
      schedule.textContent = l10n.text("eventScheduledFor", {
        date: formatDate(event.effectiveAt),
      });
      item.append(schedule);
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
    if (chips.childNodes.length > 0) item.append(chips);

    const source = safeSourceLink(event?.source?.url);
    if (source) item.append(source);

    elements.events.append(item);
  }
}

function chip(text) {
  const el = document.createElement("span");
  el.className = "chip";
  el.textContent = text;
  return el;
}

function safeSourceLink(value) {
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
  elements.card.dataset.state = "unknown";
  elements.card.setAttribute("aria-busy", "false");
  const label = l10n.text("statusUnknown");
  elements.value.textContent = label;
  elements.badge.textContent = label;
  elements.detail.textContent = l10n.text("statusReadFailed");
  elements.updated.textContent = "—";
  elements.monitorChip.dataset.monitor = "degraded";
  elements.monitorValue.textContent = l10n.text("monitorDegraded");
  if (elements.livePill) elements.livePill.hidden = true;
  elements.events.replaceChildren();
  elements.empty.hidden = false;
}

function formatUpdatedShort(value) {
  const date = new Date(value ?? "");
  return Number.isNaN(date.getTime())
    ? l10n.text("neverCheckedShort")
    : date.toLocaleString();
}

function formatDate(value) {
  const date = new Date(value ?? "");
  return Number.isNaN(date.getTime()) ? l10n.text("unknownTime") : date.toLocaleString();
}

function formatConfidence(value) {
  return `${Math.round(value * 100)}%`;
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
