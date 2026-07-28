export const EVENT_KINDS = new Set([
  "reset_completed",
  "reset_scheduled",
  "banked_reset",
  "limit_increase",
  "uncertain",
]);

export const DERIVED_RATIONALES = Object.freeze({
  reset_completed: "Explicit Codex quota reset announcement.",
  reset_scheduled: "Explicit Codex quota reset schedule.",
  banked_reset: "Banked reset announcement; not a completed reset.",
  limit_increase: "Quota limit increase announcement; not a reset.",
  uncertain: "Relevant announcement could not be classified safely.",
});

export function derivedRationale(kind) {
  return DERIVED_RATIONALES[kind];
}
