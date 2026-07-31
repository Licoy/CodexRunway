const STALE_AFTER_MS = 30 * 60 * 60 * 1_000;

/**
 * Today's answer means: is there a reset on the viewer's local calendar day?
 * That includes already-effective resets and still-pending same-day schedules.
 * When both exist, the next upcoming same-day schedule wins for the detail line.
 */
export function classifyStatus(feed, now = new Date()) {
  const lastCheck = new Date(feed?.lastSuccessfulCheckAt ?? "");
  const stale = Number.isNaN(lastCheck.getTime())
    || now.getTime() - lastCheck.getTime() > STALE_AFTER_MS;
  if (feed?.monitor?.status !== "ok" || stale) {
    return status("unknown", "unavailable");
  }

  const events = Array.isArray(feed.events) ? feed.events : [];

  // Next future schedule (any day) — used for same-day priority and "no" detail.
  const upcoming = nextScheduledReset(events, now);
  if (upcoming && isSameLocalDay(upcoming.effectiveAt, now)) {
    return status(
      "yes",
      "scheduled_today",
      "reset_scheduled",
      upcoming.effectiveAt,
      confidenceOf(upcoming.event),
    );
  }

  // Confirmed same-day already-effective resets win over uncertain commentary.
  const reset = events.find((event) => isAlreadyEffectiveResetToday(event, now));
  if (reset) {
    return status("yes", "reset", reset.kind, null, confidenceOf(reset));
  }

  const uncertain = events.find((event) => (
    event?.kind === "uncertain" && isSameLocalDay(event.announcedAt, now)
  ));
  if (uncertain) {
    return status("unknown", "uncertain", "uncertain", null, confidenceOf(uncertain));
  }

  if (upcoming) {
    return status(
      "no",
      "scheduled",
      "reset_scheduled",
      upcoming.effectiveAt,
      confidenceOf(upcoming.event),
    );
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

/** Reset that already took effect on the local calendar day. */
function isAlreadyEffectiveResetToday(event, now) {
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

function status(state, reason, eventKind = null, scheduledAt = null, confidence = null) {
  return { state, reason, eventKind, scheduledAt, confidence };
}

function confidenceOf(event) {
  return typeof event?.confidence === "number" && Number.isFinite(event.confidence)
    ? event.confidence
    : null;
}
