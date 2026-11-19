// Run with: node --test ui-tests/
// Due-date grouping. Dates are built in local time, as the panel passes them.
const test = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

const task = (id, dueDate, extra) => Object.assign({ id, name: "t" + id, dueDate, timerId: 0, timerRunning: false }, extra || {})
const groupOf = (due, now) => M.dueInfo(due, now).group
const keys = (groups) => groups.map((g) => g.key)
const ids = (groups, key) => (groups.find((g) => g.key === key) || { tasks: [] }).tasks.map((t) => t.id)

// Thursday 2026-11-19: this week runs to Sun 22nd, next week is 23rd-29th.
const thu = new Date(2026, 10, 19, 10, 0)

test("buckets around a Thursday", () => {
  assert.equal(groupOf("2026-11-18", thu), "overdue")
  assert.equal(groupOf("2025-01-01", thu), "overdue")
  assert.equal(groupOf("2026-11-19", thu), "today")
  assert.equal(groupOf("2026-11-20", thu), "tomorrow")
  assert.equal(groupOf("2026-11-21", thu), "thisWeek")
  assert.equal(groupOf("2026-11-22", thu), "thisWeek")
  assert.equal(groupOf("2026-11-23", thu), "nextWeek")
  assert.equal(groupOf("2026-11-29", thu), "nextWeek")
  assert.equal(groupOf("2026-11-30", thu), "later")
  assert.equal(groupOf("2027-03-01", thu), "later")
  assert.equal(M.dueInfo("2026-11-16", thu).days, -3)
  assert.equal(M.dueInfo("2026-11-27", thu).weekday, 5)
})

test("midnight boundaries", () => {
  const lastMinute = new Date(2026, 10, 19, 23, 59, 59, 999)
  const firstMinute = new Date(2026, 10, 20, 0, 0, 0, 0)
  assert.equal(groupOf("2026-11-19", lastMinute), "today")
  assert.equal(groupOf("2026-11-20", lastMinute), "tomorrow")
  assert.equal(groupOf("2026-11-19", firstMinute), "overdue")
  assert.equal(groupOf("2026-11-20", firstMinute), "today")
  assert.equal(groupOf("2026-11-21", firstMinute), "tomorrow")
  // Epoch ms and a plain ISO date mean the same day.
  assert.equal(groupOf("2026-11-20", firstMinute.getTime()), "today")
  assert.equal(groupOf("2026-11-20", "2026-11-20"), "today")
})

test("Sunday to Monday week rollover", () => {
  const sat = new Date(2026, 10, 21, 12)
  assert.equal(groupOf("2026-11-22", sat), "tomorrow")
  assert.equal(groupOf("2026-11-23", sat), "nextWeek")
  assert.equal(groupOf("2026-11-29", sat), "nextWeek")
  assert.equal(groupOf("2026-11-30", sat), "later")
  const lateSunday = new Date(2026, 10, 22, 23, 59)
  const earlyMonday = new Date(2026, 10, 23, 0, 1)
  assert.equal(groupOf("2026-11-29", lateSunday), "nextWeek")
  assert.equal(groupOf("2026-11-30", lateSunday), "later")
  assert.equal(groupOf("2026-11-29", earlyMonday), "thisWeek")
  assert.equal(groupOf("2026-11-30", earlyMonday), "nextWeek")
  assert.equal(groupOf("2026-12-06", earlyMonday), "nextWeek")
  assert.equal(groupOf("2026-12-07", earlyMonday), "later")
})

test("on a Sunday, tomorrow is Tomorrow, not next week", () => {
  const sun = new Date(2026, 10, 22, 9)
  assert.equal(groupOf("2026-11-22", sun), "today")
  assert.equal(groupOf("2026-11-23", sun), "tomorrow")
  assert.equal(groupOf("2026-11-24", sun), "nextWeek")
  assert.equal(groupOf("2026-11-29", sun), "nextWeek")
  assert.equal(groupOf("2026-11-30", sun), "later")
  const g = M.groupTasks([task(1, "2026-11-23"), task(2, "2026-11-24")], sun)
  assert.deepEqual(keys(g), ["tomorrow", "nextWeek"])
})

test("Monday: the rest of the week is this week", () => {
  const mon = new Date(2026, 10, 16, 9)
  assert.equal(groupOf("2026-11-17", mon), "tomorrow")
  assert.equal(groupOf("2026-11-18", mon), "thisWeek")
  assert.equal(groupOf("2026-11-22", mon), "thisWeek")
  assert.equal(groupOf("2026-11-23", mon), "nextWeek")
})

test("year and month rollover", () => {
  const dec31 = new Date(2026, 11, 31, 12) // Thursday
  assert.equal(groupOf("2027-01-01", dec31), "tomorrow")
  assert.equal(groupOf("2027-01-03", dec31), "thisWeek")
  assert.equal(groupOf("2027-01-04", dec31), "nextWeek")
  assert.equal(groupOf("2026-12-30", dec31), "overdue")
})

test("missing and invalid due dates have no due date", () => {
  for (const bad of [null, undefined, "", "soon", "2026-02-30", "2026-13-01", "2026-11-19T00:00:00Z", 20261119]) {
    assert.equal(groupOf(bad, thu), "noDate", String(bad))
  }
  const g = M.groupTasks([task(1, null), task(2, "nope"), task(3, "2026-11-19")], thu)
  assert.deepEqual(keys(g), ["today", "noDate"])
  assert.deepEqual(ids(g, "noDate"), [1, 2])
})

test("timer tasks go to Timers only, running first", () => {
  const tasks = [
    task(1, "2026-11-19"),
    task(2, "2026-11-19", { timerId: 50 }),
    task(3, "2026-11-10", { timerId: 51, timerRunning: true }),
    task(4, null, { timerId: 52 }),
    task(5, "2026-11-18")
  ]
  const g = M.groupTasks(tasks, thu)
  assert.deepEqual(keys(g), ["timers", "today", "overdue"])
  assert.deepEqual(ids(g, "timers"), [3, 2, 4])
  assert.deepEqual(ids(g, "today"), [1])
  assert.deepEqual(ids(g, "overdue"), [5])
  // Every task shows exactly once.
  assert.equal(g.reduce((n, x) => n + x.tasks.length, 0), tasks.length)
})

test("with the snapshot's timers, those decide (as the rows do)", () => {
  const timers = [
    { id: 60, taskId: 1, running: false },
    { id: 61, taskId: 2, running: true }
  ]
  // Task 3 carries a stale timerId the snapshot no longer has.
  const tasks = [task(1, "2026-11-19"), task(2, null), task(3, "2026-11-20", { timerId: 99 })]
  const g = M.groupTasks(tasks, thu, timers)
  assert.deepEqual(ids(g, "timers"), [2, 1])
  assert.deepEqual(ids(g, "tomorrow"), [3])
  assert.deepEqual(keys(M.groupTasks(tasks, thu, [])), ["today", "tomorrow", "noDate"])
})

test("groups in order, empty ones left out, sorted by due then name", () => {
  const tasks = [
    task(1, null, { name: "zeta" }),
    task(2, "2027-01-10", { name: "b" }),
    task(3, "2026-12-01", { name: "c" }),
    task(4, "2026-11-25", { name: "x" }),
    task(5, "2026-11-25", { name: "A" }),
    task(6, "2026-11-21"),
    task(7, "2026-11-20"),
    task(8, "2026-11-19"),
    task(9, "2026-11-01", { name: "old" }),
    task(10, "2026-11-17", { name: "newer" }),
    task(11, null, { name: "alpha" }),
    task(12, "2026-11-30", { timerId: 5 })
  ]
  const g = M.groupTasks(tasks, thu)
  assert.deepEqual(keys(g), M.GROUPS)
  assert.deepEqual(ids(g, "overdue"), [9, 10])
  assert.deepEqual(ids(g, "nextWeek"), [5, 4])
  assert.deepEqual(ids(g, "later"), [3, 2])
  assert.deepEqual(ids(g, "noDate"), [11, 1])
  assert.deepEqual(M.groupTasks([], thu), [])
  assert.deepEqual(M.groupTasks(null, thu), [])
})

test("collapsed by default: Later and No due date", () => {
  assert.deepEqual(Object.keys(M.COLLAPSED_BY_DEFAULT).sort(), ["later", "noDate"])
})

test("DST changes don't shift a day", () => {
  // Europe clocks go back on 2026-10-25, the US on 2026-11-01.
  assert.equal(groupOf("2026-10-26", new Date(2026, 9, 25, 23, 30)), "tomorrow")
  assert.equal(groupOf("2026-10-25", new Date(2026, 9, 25, 0, 30)), "today")
  assert.equal(groupOf("2026-11-02", new Date(2026, 10, 1, 23, 30)), "tomorrow")
  assert.equal(groupOf("2026-03-30", new Date(2026, 2, 29, 23, 30)), "tomorrow")
})

// ------------------------------------------------------------ priority order

test("priority rank sorts ahead of due date within every group", () => {
  const p = (id, due, rank, extra) => task(id, due, Object.assign({ priorityRank: rank, priorityOrder: rank === null ? "" : rank + "th" }, extra || {}))
  const g = M.groupTasks([
    p(1, "2026-11-19", null, { name: "a" }),
    p(2, "2026-11-19", 2),
    p(3, "2026-11-19", 1),
    p(4, "2026-11-19", 2, { name: "a2" }),   // same rank: falls back to name
    p(5, "2026-11-16", null),
    p(6, "2026-11-18", 3),
    p(7, null, null),
    p(8, null, 8),
  ], thu)
  assert.deepEqual(ids(g, "today"), [3, 4, 2, 1])
  assert.deepEqual(ids(g, "overdue"), [6, 5])
  assert.deepEqual(ids(g, "noDate"), [8, 7])
})

test("timers keep running first, then priority", () => {
  const timers = [
    { id: 100, taskId: 1, running: false },
    { id: 101, taskId: 2, running: true },
    { id: 102, taskId: 3, running: false },
    { id: 103, taskId: 4, running: false },
  ]
  const g = M.groupTasks([
    task(1, "2026-11-19", { priorityRank: 5 }),
    task(2, "2026-11-25", { priorityRank: null }),
    task(3, "2026-11-30", { priorityRank: 1 }),
    task(4, "2026-11-18", { priorityRank: null }),
  ], thu, timers)
  assert.deepEqual(ids(g, "timers"), [2, 3, 1, 4])
})

test("cleanTask keeps a valid priority and drops junk", () => {
  const snap = M.cleanSnapshot({ ok: true, tasks: [
    { id: 1, name: "a", priorityOrder: "1st", priorityRank: 1 },
    { id: 2, name: "b", priorityOrder: "x\n".repeat(50), priorityRank: "2" },
    { id: 3, name: "c", priorityOrder: null, priorityRank: 1.5 },
    { id: 4, name: "d" },
  ] })
  const by = Object.fromEntries(snap.tasks.map((t) => [t.id, [t.priorityOrder, t.priorityRank]]))
  assert.deepEqual(by[1], ["1st", 1])
  assert.equal(by[2][0].length <= 40, true)
  assert.equal(by[2][0].includes("\n"), false)
  assert.equal(by[2][1], null)
  assert.deepEqual(by[3], ["", null])
  assert.deepEqual(by[4], ["", null])
})

test("tasks without priority fields sort as before", () => {
  const g = M.groupTasks([task(2, "2026-11-19", { name: "b" }), task(1, "2026-11-19", { name: "a" })], thu)
  assert.deepEqual(ids(g, "today"), [1, 2])
})
