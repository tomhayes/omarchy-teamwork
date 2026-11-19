// Run with: node --test ui-tests/
// Dates are built in local time, so the results don't depend on TZ.
const test = require("node:test")
const assert = require("node:assert/strict")
const W = require("../WorkTime.js")

// 2026-11-16 is a Monday.
const at = (day, h, m) => new Date(2026, 10, day, h, m || 0, 0, 0)
const cfg = W.makeConfig({
  workDays: "1,2,3,4,5", workStart: "09:00", workEnd: "17:30", lunchStart: "12:30", lunchEnd: "13:30"
})

test("parses times and work days", () => {
  assert.equal(W.parseHHMM("09:00"), 540)
  assert.equal(W.parseHHMM("9:05"), 545)
  assert.equal(W.parseHHMM("24:00"), null)
  assert.equal(W.parseHHMM("12:60"), null)
  assert.equal(W.parseHHMM("noon"), null)
  assert.equal(W.parseHHMM(undefined), null)
  assert.equal(W.formatHHMM(545), "09:05")
  assert.deepEqual(W.parseWorkDays("5, 1,3,3,9,x"), [1, 3, 5])
  assert.deepEqual(W.parseWorkDays(""), [])
  assert.equal(W.formatWorkDays([5, 1, 2]), "1,2,5")
})

test("invalid times fall back to the defaults", () => {
  const c = W.makeConfig({ workStart: "bogus", workEnd: "17:30" })
  assert.equal(c.start, 540)
  assert.deepEqual(c.workDays, [1, 2, 3, 4, 5])
})

test("full day is span less lunch", () => {
  assert.equal(W.dayMinutes(cfg), 7.5 * 60)
  // Lunch outside the day doesn't count.
  assert.equal(W.dayMinutes(W.makeConfig({ workStart: "09:00", workEnd: "12:00", lunchStart: "12:30", lunchEnd: "13:30" })), 180)
  // Lunch hanging over the end counts only the part inside.
  assert.equal(W.dayMinutes(W.makeConfig({ workStart: "09:00", workEnd: "13:00", lunchStart: "12:30", lunchEnd: "13:30" })), 210)
})

test("before start: nothing elapsed, full target", () => {
  const t = W.today(at(16, 8, 15), cfg)
  assert.equal(t.phase, "before")
  assert.equal(t.workDay, true)
  assert.equal(t.elapsedMinutes, 0)
  assert.equal(t.fullMinutes, 450)
  assert.equal(W.percent(3600, t.elapsedMinutes), null)
  assert.equal(W.segmentStartMs(at(16, 8, 15), cfg), null)
})

test("during the morning", () => {
  const t = W.today(at(16, 11, 0), cfg)
  assert.equal(t.phase, "working")
  assert.equal(t.elapsedMinutes, 120)
  assert.equal(W.percent(90 * 60, t.elapsedMinutes), 75)
  assert.equal(W.percent(90 * 60, t.fullMinutes), 20)
  assert.equal(W.segmentStartMs(at(16, 11, 0), cfg), at(16, 9, 0).getTime())
})

test("during lunch the clock stops at lunch start", () => {
  const t = W.today(at(16, 13, 0), cfg)
  assert.equal(t.phase, "lunch")
  assert.equal(t.elapsedMinutes, 210)
  assert.equal(W.today(at(16, 12, 30), cfg).phase, "lunch")
  assert.equal(W.today(at(16, 13, 30), cfg).phase, "working")
  assert.equal(W.segmentStartMs(at(16, 13, 0), cfg), null)
})

test("afternoon counts from lunch end", () => {
  const t = W.today(at(16, 14, 30), cfg)
  assert.equal(t.elapsedMinutes, 210 + 60)
  assert.equal(W.segmentStartMs(at(16, 14, 30), cfg), at(16, 13, 30).getTime())
})

test("after end: whole day elapsed", () => {
  const t = W.today(at(16, 19, 0), cfg)
  assert.equal(t.phase, "after")
  assert.equal(t.elapsedMinutes, 450)
  assert.equal(W.today(at(16, 17, 30), cfg).phase, "after")
})

test("non-work day: no target, phase off", () => {
  const sat = at(21, 11, 0)
  const t = W.today(sat, cfg)
  assert.equal(t.phase, "off")
  assert.equal(t.workDay, false)
  assert.equal(t.fullMinutes, 0)
  assert.equal(t.elapsedMinutes, 0)
  assert.equal(W.percent(3600, t.fullMinutes), null)
})

test("custom work days make Saturday a work day", () => {
  const c = W.makeConfig({ workDays: "6", workStart: "10:00", workEnd: "14:00", lunchStart: "12:00", lunchEnd: "12:30" })
  assert.equal(W.today(at(21, 11, 0), c).phase, "working")
  assert.equal(W.today(at(16, 11, 0), c).phase, "off")
  assert.equal(W.week(at(21, 11, 0), c).fullMinutes, 210)
  assert.equal(W.week(at(21, 11, 0), c).elapsedMinutes, 60)
})

test("week to date", () => {
  // Wednesday 11:00: Mon + Tue full (900) + 120 today; target 5 x 450.
  const w = W.week(at(18, 11, 0), cfg)
  assert.equal(w.start, "2026-11-16")
  assert.equal(w.fullMinutes, 2250)
  assert.equal(w.elapsedMinutes, 1020)
  // Monday before start: nothing elapsed yet.
  assert.equal(W.week(at(16, 8, 0), cfg).elapsedMinutes, 0)
  // Sunday: the whole working week has elapsed.
  const sun = W.week(at(22, 15, 0), cfg)
  assert.equal(sun.start, "2026-11-16")
  assert.equal(sun.elapsedMinutes, 2250)
  // Saturday after a week: still the same week.
  assert.equal(W.week(at(21, 9, 0), cfg).elapsedMinutes, 2250)
})

test("week starts on Monday across a month boundary", () => {
  assert.equal(W.isoDate(W.weekStart(new Date(2026, 11, 2, 10, 0))), "2026-11-30")
  assert.equal(W.isoDate(W.weekStart(new Date(2026, 10, 29, 10, 0))), "2026-11-23")
})

test("formats durations", () => {
  assert.equal(W.formatHM(0), "0:00")
  assert.equal(W.formatHM(59), "0:00")
  assert.equal(W.formatHM(3599), "0:59")
  assert.equal(W.formatHM(3600 * 12 + 60 * 5), "12:05")
  assert.equal(W.formatHMS(3661), "1:01:01")
  assert.equal(W.formatHM(-5), "0:00")
})

test("validates the settings form", () => {
  assert.equal(W.validate({ workStart: "09:00", workEnd: "17:30", lunchStart: "12:30", lunchEnd: "13:30" }).ok, true)
  assert.deepEqual(W.validate({ workStart: "17:00", workEnd: "09:00", lunchStart: "12:30", lunchEnd: "13:30" }).errors, { workEnd: "order" })
  assert.deepEqual(W.validate({ workStart: "9", workEnd: "17:30", lunchStart: "12:30", lunchEnd: "13:30" }).errors, { workStart: "time" })
  assert.deepEqual(W.validate({ workStart: "09:00", workEnd: "17:30", lunchStart: "13:30", lunchEnd: "12:30" }).errors, { lunchEnd: "order" })
})
