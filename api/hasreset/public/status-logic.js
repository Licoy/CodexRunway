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

  const upcoming = nextScheduledReset(events, now);
  if (upcoming) {
    return status("no", "scheduled", "reset_scheduled", upcoming.effectiveAt);
  }
  return status("no", "none");
}

export function nextScheduledReset(events, now = new Date()) {
  const nowMs = now.getTime();
  let best = null;
  for (const event of events) {
    if (event?.kind !== "reset_scheduled") continue;
    const when = new Date(event.effectiveAt ?? "");
    if (Number.isNaN(when.getTime()) || when.getTime() <= nowMs) continue;
    if (!best || when < best.when) {
      best = { event, when };
    }
  }
  return best
    ? { effectiveAt: best.when.toISOString(), event: best.event }
    : null;
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

function status(state, reason, eventKind = null, scheduledAt = null) {
  return { state, reason, eventKind, scheduledAt };
}
