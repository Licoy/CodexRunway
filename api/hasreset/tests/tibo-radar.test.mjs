import assert from "node:assert/strict";
import test from "node:test";

import {
  TIBO_PROFILE,
  formatTiboClock,
  inspectTiboLocalTime,
  nthWeekdayOfMonth,
  usPublicHolidayId,
} from "../public/tibo-radar.js";

test("Tibo profile is hard-coded to San Francisco / America/Los_Angeles", () => {
  assert.equal(TIBO_PROFILE.timeZone, "America/Los_Angeles");
  assert.equal(TIBO_PROFILE.regionKey, "tiboRegion");
});

test("usPublicHolidayId covers Christmas, Independence Day, and Thanksgiving", () => {
  assert.equal(usPublicHolidayId(2026, 12, 25), "christmas");
  assert.equal(usPublicHolidayId(2026, 7, 3), "independence"); // Jul 4 is Sat → observed Fri
  assert.equal(usPublicHolidayId(2026, 7, 4), null);
  // Thanksgiving 2026 = Nov 26
  assert.equal(nthWeekdayOfMonth(2026, 11, 4, 4), 26);
  assert.equal(usPublicHolidayId(2026, 11, 26), "thanksgiving");
  // MLK 2026 = Jan 19 (3rd Monday)
  assert.equal(usPublicHolidayId(2026, 1, 19), "mlk");
  // Ordinary midweek day
  assert.equal(usPublicHolidayId(2026, 7, 30), null);
});

/**
 * Build a UTC Date that lands on the given America/Los_Angeles wall clock.
 */
function sfWallClock(year, month, day, hour, minute = 0, second = 0) {
  let guess = new Date(Date.UTC(year, month - 1, day, hour + 7, minute, second));
  for (let i = 0; i < 8; i += 1) {
    const snap = inspectTiboLocalTime(guess);
    if (
      snap.year === year
      && snap.month === month
      && snap.day === day
      && snap.hour === hour
      && snap.minute === minute
      && snap.second === second
    ) {
      return guess;
    }
    const deltaMs = ((hour - snap.hour) * 3600
      + (minute - snap.minute) * 60
      + (second - snap.second)
      + (day - snap.day) * 86400
      + (month - snap.month) * 86400 * 30) * 1000;
    guess = new Date(guess.getTime() + deltaMs);
  }
  throw new Error(`Could not pin SF wall clock ${year}-${month}-${day} ${hour}:${minute}`);
}

test("weekday work hours mark activity as working", () => {
  // 2026-07-30 is a Thursday
  const now = sfWallClock(2026, 7, 30, 14, 30, 0);
  const snap = inspectTiboLocalTime(now);
  assert.equal(snap.dayType, "weekday");
  assert.equal(snap.activity, "working");
  assert.equal(snap.holidayId, null);
  assert.equal(snap.hour, 14);
  assert.equal(snap.timeZone, "America/Los_Angeles");
});

test("late night marks activity as sleeping", () => {
  const now = sfWallClock(2026, 7, 30, 2, 15, 0);
  const snap = inspectTiboLocalTime(now);
  assert.equal(snap.activity, "sleeping");
});

test("weekday evening after work is off (awake, not working)", () => {
  const now = sfWallClock(2026, 7, 30, 20, 0, 0);
  const snap = inspectTiboLocalTime(now);
  assert.equal(snap.dayType, "weekday");
  assert.equal(snap.activity, "off");
});

test("Saturday is weekend even during work hours", () => {
  // 2026-08-01 is a Saturday
  const now = sfWallClock(2026, 8, 1, 11, 0, 0);
  const snap = inspectTiboLocalTime(now);
  assert.equal(snap.dayType, "weekend");
  assert.equal(snap.activity, "off");
});

test("Christmas Day is holiday even mid-afternoon", () => {
  const now = sfWallClock(2026, 12, 25, 15, 0, 0);
  const snap = inspectTiboLocalTime(now);
  assert.equal(snap.dayType, "holiday");
  assert.equal(snap.holidayId, "christmas");
  assert.equal(snap.activity, "off");
});

test("Christmas night is still holiday + sleeping", () => {
  const now = sfWallClock(2026, 12, 25, 1, 0, 0);
  const snap = inspectTiboLocalTime(now);
  assert.equal(snap.dayType, "holiday");
  assert.equal(snap.holidayId, "christmas");
  assert.equal(snap.activity, "sleeping");
});

test("formatTiboClock returns stable numeric wall clock", () => {
  const snap = inspectTiboLocalTime(sfWallClock(2026, 7, 30, 9, 5, 7));
  const formatted = formatTiboClock(snap, "zh-CN");
  assert.equal(formatted.date, "2026-07-30");
  assert.equal(formatted.time, "09:05:07");
  assert.ok(formatted.zone.length > 0);
});
