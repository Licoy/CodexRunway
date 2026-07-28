const STALE_AFTER_MS = 30 * 60 * 60 * 1_000;

export function classifyStatus(feed, now = new Date()) {
  const lastCheck = new Date(feed?.lastSuccessfulCheckAt ?? "");
  const stale = Number.isNaN(lastCheck.getTime())
    || now.getTime() - lastCheck.getTime() > STALE_AFTER_MS;
  if (feed?.monitor?.status !== "ok" || stale) {
    return status("unknown", "unavailable");
  }

  const events = Array.isArray(feed.events) ? feed.events : [];
  if (events.some((event) => (
    event?.kind === "uncertain" && isSameLocalDay(event.announcedAt, now)
  ))) {
    return status("unknown", "uncertain");
  }
  const reset = events.find((event) => isEffectiveResetToday(event, now));
  if (reset) {
    return status("yes", "reset", reset.kind);
  }
  return status("no", "none");
}

function isEffectiveResetToday(event, now) {
  if (!["reset_completed", "reset_scheduled"].includes(event?.kind)) return false;
  const occurrence = new Date(event.effectiveAt ?? event.announcedAt ?? "");
  return !Number.isNaN(occurrence.getTime())
    && occurrence <= now
    && isSameLocalDay(occurrence, now);
}

function isSameLocalDay(value, now) {
  const date = value instanceof Date ? value : new Date(value ?? "");
  return !Number.isNaN(date.getTime())
    && date.getFullYear() === now.getFullYear()
    && date.getMonth() === now.getMonth()
    && date.getDate() === now.getDate();
}

function status(state, reason, eventKind = null) {
  return { state, reason, eventKind };
}
