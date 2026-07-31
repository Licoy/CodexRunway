/**
 * Tibo (@thsottiaux) local-time radar.
 * Work location is hard-coded to San Francisco (not live GPS).
 */

/** @typedef {"working" | "sleeping" | "off"} TiboActivity */
/** @typedef {"weekday" | "weekend" | "holiday"} TiboDayType */

export const TIBO_PROFILE = Object.freeze({
  /** IANA timezone used for all local-time math. */
  timeZone: "America/Los_Angeles",
  /** l10n key for the hard-coded region label. */
  regionKey: "tiboRegion",
  /** Workday window [start, end) in local hours. */
  workStartHour: 9,
  workEndHour: 18,
  /** Sleep window: from sleepStartHour through midnight, then until sleepEndHour. */
  sleepStartHour: 23,
  sleepEndHour: 7,
});

/**
 * Snapshot of Tibo's local wall clock, activity, and day type.
 * @param {Date} [now]
 * @param {typeof TIBO_PROFILE} [profile]
 */
export function inspectTiboLocalTime(now = new Date(), profile = TIBO_PROFILE) {
  const instant = now instanceof Date ? now : new Date(now);
  if (Number.isNaN(instant.getTime())) {
    throw new TypeError("inspectTiboLocalTime requires a valid Date");
  }

  const parts = readZonedParts(instant, profile.timeZone);
  const holidayId = usPublicHolidayId(parts.year, parts.month, parts.day);
  const isWeekend = parts.weekday === 6 || parts.weekday === 7; // Sat / Sun (ISO)
  /** @type {TiboDayType} */
  let dayType = "weekday";
  if (holidayId) dayType = "holiday";
  else if (isWeekend) dayType = "weekend";

  /** @type {TiboActivity} */
  let activity = "off";
  if (isSleepHour(parts.hour, profile)) {
    activity = "sleeping";
  } else if (dayType === "weekday" && isWorkHour(parts.hour, profile)) {
    activity = "working";
  }

  return {
    timeZone: profile.timeZone,
    regionKey: profile.regionKey,
    year: parts.year,
    month: parts.month,
    day: parts.day,
    hour: parts.hour,
    minute: parts.minute,
    second: parts.second,
    /** ISO weekday 1=Mon … 7=Sun */
    weekday: parts.weekday,
    timeZoneName: parts.timeZoneName,
    dayType,
    holidayId,
    activity,
  };
}

/**
 * Format the local clock for display (uses page language locale).
 * @param {ReturnType<typeof inspectTiboLocalTime>} snap
 * @param {string} locale
 */
export function formatTiboClock(snap, locale = "en") {
  const pad = (n) => String(n).padStart(2, "0");
  const date = `${snap.year}-${pad(snap.month)}-${pad(snap.day)}`;
  const time = `${pad(snap.hour)}:${pad(snap.minute)}:${pad(snap.second)}`;
  const zone = snap.timeZoneName || snap.timeZone;
  void locale;
  return { date, time, zone, dateTime: `${date} ${time}` };
}

function isWorkHour(hour, profile) {
  return hour >= profile.workStartHour && hour < profile.workEndHour;
}

function isSleepHour(hour, profile) {
  const start = profile.sleepStartHour;
  const end = profile.sleepEndHour;
  if (start > end) {
    return hour >= start || hour < end;
  }
  return hour >= start && hour < end;
}

/**
 * @param {Date} date
 * @param {string} timeZone
 */
function readZonedParts(date, timeZone) {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
    weekday: "short",
    timeZoneName: "short",
  });

  /** @type {Record<string, string>} */
  const map = {};
  for (const part of formatter.formatToParts(date)) {
    if (part.type !== "literal") map[part.type] = part.value;
  }

  const weekdayToken = map.weekday ?? "";
  const weekday = WEEKDAY_TO_ISO[weekdayToken] ?? 1;

  return {
    year: Number(map.year),
    month: Number(map.month),
    day: Number(map.day),
    hour: Number(map.hour),
    minute: Number(map.minute),
    second: Number(map.second),
    weekday,
    timeZoneName: map.timeZoneName ?? timeZone,
  };
}

const WEEKDAY_TO_ISO = Object.freeze({
  Mon: 1,
  Tue: 2,
  Wed: 3,
  Thu: 4,
  Fri: 5,
  Sat: 6,
  Sun: 7,
});

/**
 * US federal public holidays (incl. weekend observed shifts), relevant for SF work.
 * Returns a stable holiday id for l10n, or null.
 * @param {number} year
 * @param {number} month 1-12
 * @param {number} day
 * @returns {string | null}
 */
export function usPublicHolidayId(year, month, day) {
  const key = month * 100 + day;
  for (const [id, date] of usHolidayDates(year)) {
    if (date.month * 100 + date.day === key) return id;
  }
  return null;
}

/**
 * @param {number} year
 * @returns {Array<[string, { month: number, day: number }]>}
 */
export function usHolidayDates(year) {
  return [
    ["newYear", observedFixed(year, 1, 1)],
    ["mlk", { month: 1, day: nthWeekdayOfMonth(year, 1, 1, 3) }],
    ["presidents", { month: 2, day: nthWeekdayOfMonth(year, 2, 1, 3) }],
    ["memorial", { month: 5, day: lastWeekdayOfMonth(year, 5, 1) }],
    ["juneteenth", observedFixed(year, 6, 19)],
    ["independence", observedFixed(year, 7, 4)],
    ["laborDay", { month: 9, day: nthWeekdayOfMonth(year, 9, 1, 1) }],
    ["indigenousPeoples", { month: 10, day: nthWeekdayOfMonth(year, 10, 1, 2) }],
    ["veterans", observedFixed(year, 11, 11)],
    ["thanksgiving", { month: 11, day: nthWeekdayOfMonth(year, 11, 4, 4) }],
    ["christmas", observedFixed(year, 12, 25)],
  ];
}

/**
 * Federal observed rule: Sat → Fri, Sun → Mon (same calendar year when possible).
 * @param {number} year
 * @param {number} month
 * @param {number} day
 */
function observedFixed(year, month, day) {
  const dow = weekdayUtc(year, month, day); // 0=Sun … 6=Sat
  if (dow === 6) return shiftCalendarDate(year, month, day, -1);
  if (dow === 0) return shiftCalendarDate(year, month, day, 1);
  return { month, day };
}

/**
 * @param {number} year
 * @param {number} month
 * @param {number} day
 * @param {number} deltaDays
 */
function shiftCalendarDate(year, month, day, deltaDays) {
  const utc = new Date(Date.UTC(year, month - 1, day + deltaDays));
  // Only accept shifts that stay in the same year for matching "today".
  if (utc.getUTCFullYear() !== year) {
    return { month, day };
  }
  return { month: utc.getUTCMonth() + 1, day: utc.getUTCDate() };
}

/** @returns {number} 0=Sun … 6=Sat */
function weekdayUtc(year, month, day) {
  return new Date(Date.UTC(year, month - 1, day)).getUTCDay();
}

/**
 * n-th ISO weekday of month (1=Mon … 7=Sun).
 * @param {number} year
 * @param {number} month
 * @param {number} isoWeekday
 * @param {number} n
 */
export function nthWeekdayOfMonth(year, month, isoWeekday, n) {
  const target = isoToUtcDow(isoWeekday);
  const firstDow = weekdayUtc(year, month, 1);
  let day = 1 + ((target - firstDow + 7) % 7);
  day += (n - 1) * 7;
  return day;
}

/**
 * Last ISO weekday of month (1=Mon … 7=Sun).
 * @param {number} year
 * @param {number} month
 * @param {number} isoWeekday
 */
export function lastWeekdayOfMonth(year, month, isoWeekday) {
  const target = isoToUtcDow(isoWeekday);
  const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const lastDow = weekdayUtc(year, month, lastDay);
  return lastDay - ((lastDow - target + 7) % 7);
}

function isoToUtcDow(isoWeekday) {
  return isoWeekday === 7 ? 0 : isoWeekday;
}
