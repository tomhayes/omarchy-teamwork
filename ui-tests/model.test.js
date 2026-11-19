// Run with: node --test ui-tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

const snapshot = {
  ok: true,
  user: { id: 7, name: "Alex" },
  timers: [
    { id: 11, taskId: 2, taskName: "Paused older", projectName: "P", running: false, elapsedSeconds: 600, lastStartedAt: "2026-11-19T08:00:00Z" },
    { id: 12, taskId: 3, taskName: "Paused newer", projectName: "P", running: false, elapsedSeconds: 300, lastStartedAt: "2026-11-19T09:00:00Z" }
  ],
  tasks: [
    { id: 2, name: "Design review", projectName: "Acme", tasklistName: "Sprint", dueDate: null, recent: false },
    { id: 3, name: "Fix <b>login</b>", projectName: "Beta", tasklistName: "Bugs", dueDate: "2026-11-20", recent: true }
  ],
  today: { date: "2026-11-19", loggedSeconds: 3600 },
  week: { start: "2026-11-16", loggedSeconds: 7200, days: [{ date: "2026-11-16", loggedSeconds: 3600 }] },
  fetchedAt: "2026-11-19T10:00:00Z"
}

test("parses helper output", () => {
  assert.equal(M.parseResult('{"ok": true, "hasKey": true}').hasKey, true)
  assert.deepEqual(M.parseResult('{"ok": false, "error": "Bad key", "code": "auth"}'), { ok: false, error: "Bad key", code: "auth" })
  assert.equal(M.parseResult("").ok, false)
  assert.equal(M.parseResult("Traceback...").code, "usage")
  assert.equal(M.parseResult("[1,2]").ok, false)
  // A warning line ahead of the JSON is skipped.
  assert.equal(M.parseResult('warning: x\n{"ok": true}').ok, true)
})

test("cleans and bounds the snapshot", () => {
  const long = "x".repeat(1000)
  const s = M.cleanSnapshot({
    ok: true,
    timers: [{ id: "bad" }, { id: 5, taskName: long, elapsedSeconds: -4, running: "yes" }],
    tasks: Array.from({ length: 700 }, (_, i) => ({ id: i + 1, name: "t\n" + i, dueDate: "soon" })),
    week: { days: [{ date: "2026-11-16", loggedSeconds: 1 }, { date: "nope" }] }
  })
  assert.equal(s.timers.length, 1)
  assert.equal(s.timers[0].taskName.length, 300)
  assert.equal(s.timers[0].elapsedSeconds, 0)
  assert.equal(s.timers[0].running, false)
  assert.equal(s.tasks.length, 500)
  assert.equal(s.tasks[0].name, "t 0")
  assert.equal(s.tasks[0].dueDate, "")
  assert.equal(s.week.days.length, 1)
  assert.equal(M.cleanSnapshot({ ok: false }), null)
})

test("current timer: running first, else the latest paused", () => {
  const s = M.cleanSnapshot(snapshot)
  assert.equal(M.currentTimer(s.timers).id, 12)
  assert.equal(M.runningTimer(s.timers), null)
  const running = s.timers.concat([{ id: 13, taskId: 9, running: true, elapsedSeconds: 10, lastStartedAt: "" }])
  assert.equal(M.currentTimer(running).id, 13)
  assert.equal(M.currentTimer([]), null)
})

test("live seconds tick only while running", () => {
  const t = { running: true, elapsedSeconds: 100 }
  assert.equal(M.liveSeconds(t, 1000, 61000), 160)
  assert.equal(M.liveSeconds({ running: false, elapsedSeconds: 100 }, 1000, 61000), 100)
  assert.equal(M.unloggedSeconds([t, { running: false, elapsedSeconds: 40 }], 1000, 11000), 150)
})

test("finds a task's timer by timerId, else by task", () => {
  const s = M.cleanSnapshot(snapshot)
  assert.equal(M.timerForTask({ id: 2, timerId: 0 }, s.timers).id, 11)
  assert.equal(M.timerForTask({ id: 2, timerId: 12 }, s.timers).id, 12)
  assert.equal(M.timerForTask({ id: 99, timerId: 0 }, s.timers), null)
  const t = M.cleanSnapshot({ ok: true, tasks: [{ id: 4, timerId: 8, timerRunning: true, projectId: 3 }] }).tasks[0]
  assert.equal(t.timerId, 8)
  assert.equal(t.timerRunning, true)
  assert.equal(t.projectId, 3)
})

test("filters tasks by every word", () => {
  const s = M.cleanSnapshot(snapshot)
  assert.equal(M.filterTasks(s.tasks, "").length, 2)
  assert.deepEqual(M.filterTasks(s.tasks, "acme design").map((t) => t.id), [2])
  assert.deepEqual(M.filterTasks(s.tasks, "BUGS").map((t) => t.id), [3])
  assert.equal(M.filterTasks(s.tasks, "nothing").length, 0)
})

test("resume target", () => {
  const s = M.cleanSnapshot(snapshot)
  assert.deepEqual(M.resumeTarget(s, { id: 2, name: "Design review" }), { id: 2, name: "Design review" })
  assert.equal(M.resumeTarget(s, null).id, 3)
  assert.equal(M.resumeTarget({ tasks: [] }, null), null)
})

test("notification text cannot carry markup", () => {
  const out = M.notifySafe('Fix <b>login</b> & <a href="https://evil.invalid">x</a> &lt;i&gt;')
  assert.ok(!/[<>&]/.test(out), out)
  assert.ok(out.indexOf("login") !== -1)
  assert.ok(M.notifySafe("<img src=https://tracker.invalid/p>").indexOf("<") === -1)
  assert.equal(M.notifySafe("a\nb"), "a b")
  assert.equal(Array.from(M.notifySafe("y".repeat(400))).length, 120)
})

test("truncates by code point", () => {
  assert.equal(M.truncate("short", 24), "short")
  assert.equal(M.truncate("abcdefghijklmnopqrstuvwxyz", 10), "abcdefghi\u2026")
  assert.equal(Array.from(M.truncate("\u{1F600}".repeat(30), 24)).length, 24)
})

test("site url must be a bare https origin", () => {
  assert.equal(M.cleanSiteUrl("https://acme.teamwork.com/"), "https://acme.teamwork.com")
  assert.equal(M.cleanSiteUrl("HTTPS://Acme.Teamwork.com"), "https://acme.teamwork.com")
  assert.equal(M.cleanSiteUrl("http://acme.teamwork.com"), "")
  assert.equal(M.cleanSiteUrl("https://acme.teamwork.com/app"), "")
  assert.equal(M.cleanSiteUrl("https://user:pw@acme.teamwork.com"), "")
  assert.equal(M.cleanSiteUrl("https://acme.teamwork.com?x=1"), "")
  assert.equal(M.cleanSiteUrl("https://localhost"), "")
  assert.equal(M.taskUrl("https://acme.teamwork.com", 42), "https://acme.teamwork.com/app/tasks/42")
  assert.equal(M.taskUrl("https://acme.teamwork.com", "42; rm -rf"), "")
})

test("nag only in work time, with no timer, after the interval", () => {
  const base = {
    nowMs: 60 * 60000, phase: "working", configured: true, nagEnabled: true, hasRunningTimer: false,
    dataFresh: true, intervalMin: 15, lastNagMs: 0, idleSinceMs: 0, segmentStartMs: 0
  }
  assert.equal(M.shouldNag(base), true)
  assert.equal(M.shouldNag(Object.assign({}, base, { hasRunningTimer: true })), false)
  assert.equal(M.shouldNag(Object.assign({}, base, { phase: "lunch" })), false)
  assert.equal(M.shouldNag(Object.assign({}, base, { phase: "off" })), false)
  assert.equal(M.shouldNag(Object.assign({}, base, { nagEnabled: false })), false)
  assert.equal(M.shouldNag(Object.assign({}, base, { configured: false })), false)
  assert.equal(M.shouldNag(Object.assign({}, base, { dataFresh: false })), false)
  // Ten minutes since the last nag isn't enough; fifteen is.
  assert.equal(M.shouldNag(Object.assign({}, base, { lastNagMs: 50 * 60000 })), false)
  assert.equal(M.shouldNag(Object.assign({}, base, { lastNagMs: 45 * 60000 })), true)
  // The timer stopping, or the afternoon starting, resets the wait.
  assert.equal(M.shouldNag(Object.assign({}, base, { idleSinceMs: 55 * 60000 })), false)
  assert.equal(M.shouldNag(Object.assign({}, base, { segmentStartMs: 50 * 60000 })), false)
})

test("backs off on failure, capped", () => {
  assert.equal(M.backoffMs(60, 0), 60000)
  assert.equal(M.backoffMs(60, 1), 120000)
  assert.equal(M.backoffMs(60, 8), 600000)
  assert.equal(M.backoffMs(5, 0), 15000)
  assert.equal(M.backoffMs(3600, 3), 3600000)
})
