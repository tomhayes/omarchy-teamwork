// Snapshot handling for the Teamwork widget: validating what bin/teamwork
// prints, picking the current timer, filtering tasks, and deciding when to
// nag. Pure functions, tested with node (ui-tests/model.test.js).

var MAX_TASKS = 500
var MAX_TIMERS = 50
var MAX_NAME = 300
var MAX_DAYS = 7

function str(value, max) {
  if (value === undefined || value === null) return ""
  var s = String(value)
  // Control characters (newlines included) have no place in a one-line label.
  s = s.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, " ")
  if (s.length > (max || MAX_NAME)) s = s.slice(0, max || MAX_NAME)
  return s
}

function int(value, min, max) {
  var n = Number(value)
  if (!isFinite(n)) return min
  n = Math.floor(n)
  return Math.max(min, Math.min(max, n))
}

function id(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 && Math.floor(n) === n && n < 1e15 ? n : 0
}

function dateStr(value) {
  var s = String(value === undefined || value === null ? "" : value)
  return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : ""
}

var SECONDS_CAP = 60 * 60 * 24 * 366

function cleanTimer(t) {
  if (!t || typeof t !== "object") return null
  var timerId = id(t.id)
  if (!timerId) return null
  return {
    id: timerId,
    taskId: id(t.taskId),
    taskName: str(t.taskName),
    projectId: id(t.projectId),
    projectName: str(t.projectName),
    running: t.running === true,
    billable: t.billable === true,
    elapsedSeconds: int(t.elapsedSeconds, 0, SECONDS_CAP),
    lastStartedAt: str(t.lastStartedAt, 40),
    description: str(t.description, 1000)
  }
}

function cleanTask(t) {
  if (!t || typeof t !== "object") return null
  var taskId = id(t.id)
  if (!taskId) return null
  return {
    id: taskId,
    name: str(t.name),
    projectId: id(t.projectId),
    projectName: str(t.projectName),
    tasklistName: str(t.tasklistName),
    // The task's own timer, if it has one (bin/teamwork sets both).
    timerId: id(t.timerId),
    timerRunning: t.timerRunning === true,
    dueDate: dateStr(t.dueDate),
    estimateMinutes: int(t.estimateMinutes, 0, 1e6),
    // Logged time only (time entries); unlogged timer time is added on top.
    trackedTodaySeconds: int(t.trackedTodaySeconds, 0, SECONDS_CAP),
    trackedWeekSeconds: int(t.trackedWeekSeconds, 0, SECONDS_CAP),
    trackedTotalSeconds: int(t.trackedTotalSeconds, 0, SECONDS_CAP * 10),
    recent: t.recent === true,
    // The sort field (the task custom field named in the sortField setting):
    // its text ("1st") and leading number (1), or "" and null when the task
    // has none or the setting is off.
    priorityOrder: str(t.priorityOrder, 40).trim(),
    priorityRank: rank(t.priorityRank)
  }
}

function rank(value) {
  if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value) return null
  return value >= 0 && value < 1e9 ? value : null
}

function cleanList(list, max, clean) {
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length && out.length < max; i++) {
    var item = clean(list[i])
    if (item) out.push(item)
  }
  return out
}

// bin/teamwork's stdout to a result object. Never throws: anything that isn't
// one JSON object becomes { ok: false, code: "usage" }.
function parseResult(text) {
  var raw = String(text || "").trim()
  if (raw.length > 6 * 1024 * 1024) return { ok: false, error: "Response too large", code: "api" }
  var parsed = null
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    // A stray line ahead of the JSON (a warning, say) shouldn't lose it.
    var last = raw.lastIndexOf("\n{")
    if (last !== -1) {
      try { parsed = JSON.parse(raw.slice(last + 1)) } catch (e2) { parsed = null }
    }
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    return { ok: false, error: raw === "" ? "No response from helper" : "Unreadable helper output", code: "usage" }
  if (parsed.ok !== true)
    return { ok: false, error: str(parsed.error, 200) || "Unknown error", code: str(parsed.code, 20) || "api" }
  return parsed
}

// A validated `status` snapshot, or null when the result isn't one.
function cleanSnapshot(res) {
  if (!res || res.ok !== true) return null
  var user = res.user && typeof res.user === "object" ? { id: id(res.user.id), name: str(res.user.name, 120) } : { id: 0, name: "" }
  var today = res.today && typeof res.today === "object" ? res.today : {}
  var week = res.week && typeof res.week === "object" ? res.week : {}
  var days = []
  if (Array.isArray(week.days)) {
    for (var i = 0; i < week.days.length && days.length < MAX_DAYS; i++) {
      var d = week.days[i]
      if (!d || typeof d !== "object" || !dateStr(d.date)) continue
      days.push({ date: dateStr(d.date), loggedSeconds: int(d.loggedSeconds, 0, SECONDS_CAP) })
    }
  }
  return {
    user: user,
    timers: cleanList(res.timers, MAX_TIMERS, cleanTimer),
    tasks: cleanList(res.tasks, MAX_TASKS, cleanTask),
    today: { date: dateStr(today.date), loggedSeconds: int(today.loggedSeconds, 0, SECONDS_CAP) },
    week: { start: dateStr(week.start), loggedSeconds: int(week.loggedSeconds, 0, SECONDS_CAP), days: days },
    fetchedAt: str(res.fetchedAt, 40)
  }
}

function startedMs(timer) {
  var ms = Date.parse(timer && timer.lastStartedAt || "")
  return isFinite(ms) ? ms : 0
}

// The timer the widget is about: the running one, else the paused one most
// recently started. null when there are none.
function currentTimer(timers) {
  var list = timers || []
  var best = null
  for (var i = 0; i < list.length; i++) {
    var t = list[i]
    if (t.running) return t
    if (!best || startedMs(t) > startedMs(best)) best = t
  }
  return best
}

function runningTimer(timers) {
  var list = timers || []
  for (var i = 0; i < list.length; i++) if (list[i].running) return list[i]
  return null
}

// A timer's elapsed seconds now: the snapshot's figure, plus the time since it
// was fetched while it runs.
function liveSeconds(timer, fetchedMs, nowMs) {
  if (!timer) return 0
  var base = Number(timer.elapsedSeconds) || 0
  if (!timer.running || !(fetchedMs > 0)) return base
  return base + Math.max(0, Math.floor((nowMs - fetchedMs) / 1000))
}

// Unlogged time across every timer, now.
function unloggedSeconds(timers, fetchedMs, nowMs) {
  var list = timers || []
  var total = 0
  for (var i = 0; i < list.length; i++) total += liveSeconds(list[i], fetchedMs, nowMs)
  return total
}

// Map of taskId to its timer (running wins over paused).
function timersByTask(timers) {
  var map = {}
  var list = timers || []
  for (var i = 0; i < list.length; i++) {
    var t = list[i]
    if (!t.taskId) continue
    if (!map[t.taskId] || t.running) map[t.taskId] = t
  }
  return map
}

// A task's timer from the snapshot: its own timerId first, else any timer
// on the task. null when it has none.
function timerForTask(task, timers) {
  if (!task) return null
  var list = timers || []
  var byTask = null
  for (var i = 0; i < list.length; i++) {
    if (task.timerId && list[i].id === task.timerId) return list[i]
    if (list[i].taskId === task.id && (!byTask || list[i].running)) byTask = list[i]
  }
  return byTask
}

// Case-insensitive match on name, project and task list, every word.
function filterTasks(tasks, query) {
  var list = tasks || []
  var words = String(query || "").toLowerCase().split(/\s+/).filter(function(w) { return w !== "" })
  if (words.length === 0) return list
  return list.filter(function(t) {
    var hay = (t.name + " " + t.projectName + " " + t.tasklistName + " " + t.id).toLowerCase()
    for (var i = 0; i < words.length; i++) if (hay.indexOf(words[i]) === -1) return false
    return true
  })
}

// ------------------------------------------------------------ due groups
// The task list is grouped by due date, in this order. "timers" holds every
// task with a running or paused timer, whatever its due date.
var GROUPS = ["timers", "today", "overdue", "tomorrow", "thisWeek", "nextWeek", "later", "noDate"]
// Collapsed until the user opens them.
var COLLAPSED_BY_DEFAULT = { later: true, noDate: true }

// Day number (days since 1970-01-01) of a "YYYY-MM-DD" calendar date, or NaN
// when it isn't a real date. Calendar arithmetic in UTC, so DST can't skew it.
function dayNumber(iso) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso === undefined || iso === null ? "" : iso))
  if (!m) return NaN
  var y = Number(m[1]), mo = Number(m[2]), d = Number(m[3])
  var ms = Date.UTC(y, mo - 1, d)
  var back = new Date(ms)
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) return NaN
  return Math.round(ms / 86400000)
}

// Today's local calendar date as "YYYY-MM-DD". `now` is a Date, epoch ms, or
// already a "YYYY-MM-DD" string.
function localIsoDate(now) {
  if (typeof now === "string" && !isNaN(dayNumber(now))) return now
  var d = now instanceof Date ? now : new Date(Number(now))
  if (isNaN(d.getTime())) d = new Date()
  function pad(n) { return (n < 10 ? "0" : "") + n }
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
}

// Where a due date falls relative to `now` (local time, Monday-start weeks):
//   { group, days, weekday }   days = due minus today (negative when late),
//   weekday = 0 (Sunday) to 6. group is "noDate" for a missing/invalid date.
function dueInfo(dueDate, now) {
  var due = dayNumber(dueDate)
  if (isNaN(due)) return { group: "noDate", days: 0, weekday: -1 }
  var today = dayNumber(localIsoDate(now))
  var days = due - today
  // 1970-01-01 was a Thursday (4).
  var todayDow = ((today % 7) + 7 + 4) % 7
  var toSunday = (7 - todayDow) % 7
  var group
  if (days < 0) group = "overdue"
  else if (days === 0) group = "today"
  else if (days === 1) group = "tomorrow"
  else if (days <= toSunday) group = "thisWeek"
  else if (days <= toSunday + 7) group = "nextWeek"
  else group = "later"
  return { group: group, days: days, weekday: ((due % 7) + 7 + 4) % 7 }
}

// Tasks with a priority rank first, lowest rank first; then due date and name.
function compareTasks(a, b) {
  var ra = rank(a.priorityRank), rb = rank(b.priorityRank)
  if ((ra === null) !== (rb === null)) return ra === null ? 1 : -1
  if (ra !== null && ra !== rb) return ra - rb
  return compareDueThenName(a, b)
}

function compareDueThenName(a, b) {
  var da = dayNumber(a.dueDate), db = dayNumber(b.dueDate)
  var na = isNaN(da), nb = isNaN(db)
  if (na !== nb) return na ? 1 : -1
  if (!na && da !== db) return da - db
  var an = String(a.name || "").toLowerCase(), bn = String(b.name || "").toLowerCase()
  if (an !== bn) return an < bn ? -1 : 1
  return (a.id || 0) - (b.id || 0)
}

// Tasks grouped by due date, relative to `now` (a Date, epoch ms or
// "YYYY-MM-DD"). With `timers` (the snapshot's list) a task's timer is looked
// up there, as the rows do; without it the task's own timerId/timerRunning
// count. Returns the non-empty groups in GROUPS order:
//   [{ key, tasks: [task, ...] }]
// Timers: running first, then as the others. Others: priority rank (ranked
// tasks first, lowest first), then due date, then name.
function groupTasks(tasks, now, timers) {
  var list = tasks || []
  var buckets = {}
  var running = {}
  for (var g = 0; g < GROUPS.length; g++) buckets[GROUPS[g]] = []
  for (var i = 0; i < list.length; i++) {
    var t = list[i]
    if (!t) continue
    var timer = timers ? timerForTask(t, timers) : null
    var hasTimer = timers ? !!timer : !!(t.timerId || t.timerRunning)
    if (hasTimer) {
      running[t.id] = timers ? timer.running === true : t.timerRunning === true
      buckets.timers.push(t)
    } else {
      buckets[dueInfo(t.dueDate, now).group].push(t)
    }
  }
  buckets.timers.sort(function(a, b) {
    var ra = !!running[a.id], rb = !!running[b.id]
    if (ra !== rb) return ra ? -1 : 1
    return compareTasks(a, b)
  })
  var out = []
  for (var k = 0; k < GROUPS.length; k++) {
    var key = GROUPS[k]
    if (key !== "timers") buckets[key].sort(compareTasks)
    if (buckets[key].length > 0) out.push({ key: key, tasks: buckets[key] })
  }
  return out
}

// The task to start when the bar is clicked with no timer: the one last seen
// running here, else the first recent task in the snapshot. null if none.
function resumeTarget(snapshot, lastTask) {
  if (lastTask && id(lastTask.id)) return { id: id(lastTask.id), name: str(lastTask.name) }
  var tasks = snapshot && snapshot.tasks ? snapshot.tasks : []
  for (var i = 0; i < tasks.length; i++)
    if (tasks[i].recent) return { id: tasks[i].id, name: tasks[i].name }
  return null
}

// Cuts to `max` characters (by code point) with an ellipsis.
function truncate(text, max) {
  var chars = Array.from(String(text || ""))
  if (chars.length <= max) return chars.join("")
  return chars.slice(0, Math.max(1, max - 1)).join("").replace(/\s+$/, "") + "\u2026"
}

// Dynamic text for a notification. The notification server renders the body
// as markup and decodes entities first, so escaping cannot keep a task name
// inert: the characters markup is built from are swapped for look-alikes.
function notifySafe(text, max) {
  var s = str(text, 2000)
    .replace(/&/g, "\uff06")
    .replace(/</g, "\u2039")
    .replace(/>/g, "\u203a")
  return truncate(s.trim(), max || 120)
}

// "https://x.teamwork.com" or "" when the value isn't a bare https origin.
function cleanSiteUrl(value) {
  var s = String(value || "").trim().replace(/\/+$/, "")
  var m = /^https:\/\/([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+)(:\d{1,5})?$/i.exec(s)
  if (!m) return ""
  return "https://" + m[1].toLowerCase() + (m[5] || "")
}

function taskUrl(siteUrl, taskId) {
  var site = cleanSiteUrl(siteUrl)
  var n = id(taskId)
  return site && n ? site + "/app/tasks/" + n : ""
}

// Whether to send the "no timer running" nag now.
//   s.nowMs, s.phase ("working" etc.), s.configured, s.nagEnabled,
//   s.hasRunningTimer, s.dataFresh, s.intervalMin, s.lastNagMs,
//   s.idleSinceMs (when no timer was first seen running), s.segmentStartMs
function shouldNag(s) {
  if (!s || !s.configured || !s.nagEnabled || s.hasRunningTimer || !s.dataFresh) return false
  if (s.phase !== "working") return false
  var interval = Math.max(1, Number(s.intervalMin) || 15) * 60000
  var since = Math.max(Number(s.lastNagMs) || 0, Number(s.idleSinceMs) || 0, Number(s.segmentStartMs) || 0)
  return s.nowMs - since >= interval
}

// The next poll delay after `failures` consecutive failures: the configured
// interval, doubling per failure, capped at ten minutes.
function backoffMs(intervalSec, failures) {
  var base = Math.max(15, Number(intervalSec) || 60) * 1000
  var n = Math.max(0, Math.min(10, Number(failures) || 0))
  return Math.min(Math.max(base, 600000), base * Math.pow(2, n))
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    parseResult: parseResult,
    cleanSnapshot: cleanSnapshot,
    currentTimer: currentTimer,
    runningTimer: runningTimer,
    liveSeconds: liveSeconds,
    unloggedSeconds: unloggedSeconds,
    timersByTask: timersByTask,
    timerForTask: timerForTask,
    filterTasks: filterTasks,
    GROUPS: GROUPS,
    COLLAPSED_BY_DEFAULT: COLLAPSED_BY_DEFAULT,
    dayNumber: dayNumber,
    localIsoDate: localIsoDate,
    dueInfo: dueInfo,
    groupTasks: groupTasks,
    compareTasks: compareTasks,
    resumeTarget: resumeTarget,
    truncate: truncate,
    notifySafe: notifySafe,
    cleanSiteUrl: cleanSiteUrl,
    taskUrl: taskUrl,
    shouldNag: shouldNag,
    backoffMs: backoffMs
  }
}
