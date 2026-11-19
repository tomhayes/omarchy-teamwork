// Work-time maths for the Teamwork widget, kept out of the QML so it can be
// tested with node (ui-tests/worktime.test.js). Pure functions only: every
// "now" is passed in as a Date in local time.
//
// A work day runs from workStart to workEnd on the configured ISO weekdays
// (1 = Monday ... 7 = Sunday), less the lunch break where it overlaps.

var DEFAULTS = {
  workDays: "1,2,3,4,5",
  workStart: "09:00",
  workEnd: "17:30",
  lunchStart: "12:30",
  lunchEnd: "13:30"
}

// "HH:MM" (24h) to minutes after midnight, or null when it isn't one.
function parseHHMM(value) {
  var m = /^\s*(\d{1,2}):(\d{2})\s*$/.exec(String(value === undefined || value === null ? "" : value))
  if (!m) return null
  var h = Number(m[1])
  var min = Number(m[2])
  if (h > 23 || min > 59) return null
  return h * 60 + min
}

// Minutes after midnight back to "HH:MM".
function formatHHMM(minutes) {
  var total = Math.max(0, Math.min(24 * 60 - 1, Math.round(Number(minutes) || 0)))
  var h = Math.floor(total / 60)
  var m = total % 60
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

// "1,2,3,4,5" to a sorted, de-duplicated array of ISO weekdays. Anything
// unparseable leaves an empty list (no work days), never a throw.
function parseWorkDays(value) {
  var parts = String(value === undefined || value === null ? "" : value).split(/[\s,]+/)
  var out = []
  for (var i = 0; i < parts.length; i++) {
    if (!/^\d$/.test(parts[i])) continue
    var n = Number(parts[i])
    if (n >= 1 && n <= 7 && out.indexOf(n) === -1) out.push(n)
  }
  out.sort(function(a, b) { return a - b })
  return out
}

function formatWorkDays(days) {
  return parseWorkDays((days || []).join(",")).join(",")
}

// ISO weekday of a local Date: Monday 1 ... Sunday 7.
function isoWeekday(date) {
  var d = date.getDay()
  return d === 0 ? 7 : d
}

// Settings strings to the config the rest of this file works with. Invalid
// times fall back to the defaults, so a typo never yields NaN maths.
function makeConfig(settings) {
  var s = settings || {}
  function pick(key) {
    var v = parseHHMM(s[key])
    return v === null ? parseHHMM(DEFAULTS[key]) : v
  }
  var workDaysRaw = s.workDays === undefined || s.workDays === null ? DEFAULTS.workDays : s.workDays
  return {
    workDays: parseWorkDays(workDaysRaw),
    start: pick("workStart"),
    end: pick("workEnd"),
    lunchStart: pick("lunchStart"),
    lunchEnd: pick("lunchEnd")
  }
}

function overlap(a0, a1, b0, b1) {
  return Math.max(0, Math.min(a1, b1) - Math.max(a0, b0))
}

// Lunch clipped to the work day; empty when it falls outside or is inverted.
function lunchWindow(cfg) {
  var s = Math.max(cfg.lunchStart, cfg.start)
  var e = Math.min(cfg.lunchEnd, cfg.end)
  return e > s ? { start: s, end: e } : { start: cfg.start, end: cfg.start }
}

// Working minutes in a full work day.
function dayMinutes(cfg) {
  if (!(cfg.end > cfg.start)) return 0
  var lunch = lunchWindow(cfg)
  return (cfg.end - cfg.start) - (lunch.end - lunch.start)
}

function isWorkDay(date, cfg) {
  return cfg.workDays.indexOf(isoWeekday(date)) !== -1
}

// Minutes after local midnight, fractional.
function minuteOfDay(date) {
  return date.getHours() * 60 + date.getMinutes() + date.getSeconds() / 60 + date.getMilliseconds() / 60000
}

// Working minutes elapsed so far on `date`'s day, up to `date`'s time.
function elapsedMinutesOn(date, cfg) {
  if (!isWorkDay(date, cfg) || !(cfg.end > cfg.start)) return 0
  var t = Math.min(Math.max(minuteOfDay(date), cfg.start), cfg.end)
  var lunch = lunchWindow(cfg)
  return (t - cfg.start) - overlap(cfg.start, t, lunch.start, lunch.end)
}

// Where `date` falls in its day: "off" (not a work day), "before", "working",
// "lunch" or "after".
function phase(date, cfg) {
  if (!isWorkDay(date, cfg) || !(cfg.end > cfg.start)) return "off"
  var t = minuteOfDay(date)
  if (t < cfg.start) return "before"
  if (t >= cfg.end) return "after"
  var lunch = lunchWindow(cfg)
  if (lunch.end > lunch.start && t >= lunch.start && t < lunch.end) return "lunch"
  return "working"
}

function atMinute(date, minutes) {
  var d = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0, 0)
  d.setMinutes(Math.round(minutes))
  return d
}

// The start (ms) of the stretch of work `date` is in: workStart, or lunchEnd
// in the afternoon. null outside working time.
function segmentStartMs(date, cfg) {
  if (phase(date, cfg) !== "working") return null
  var lunch = lunchWindow(cfg)
  var t = minuteOfDay(date)
  var start = (lunch.end > lunch.start && t >= lunch.end) ? lunch.end : cfg.start
  return atMinute(date, start).getTime()
}

// Monday 00:00 local of `date`'s week.
function weekStart(date) {
  var d = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0, 0)
  d.setDate(d.getDate() - (isoWeekday(d) - 1))
  return d
}

function isoDate(date) {
  var m = date.getMonth() + 1
  var d = date.getDate()
  return date.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (d < 10 ? "0" : "") + d
}

// Today's work-time picture at `now`.
function today(now, cfg) {
  var work = isWorkDay(now, cfg)
  return {
    date: isoDate(now),
    workDay: work,
    phase: phase(now, cfg),
    fullMinutes: work ? dayMinutes(cfg) : 0,
    elapsedMinutes: elapsedMinutesOn(now, cfg)
  }
}

// The week (Monday to Sunday) to date at `now`: full-week target, and the
// work time elapsed through earlier days plus today so far.
function week(now, cfg) {
  var start = weekStart(now)
  var todayIso = isoWeekday(now)
  var full = 0
  var elapsed = 0
  var perDay = dayMinutes(cfg)
  for (var i = 1; i <= 7; i++) {
    if (cfg.workDays.indexOf(i) === -1) continue
    full += perDay
    if (i < todayIso) elapsed += perDay
    else if (i === todayIso) elapsed += elapsedMinutesOn(now, cfg)
  }
  return { start: isoDate(start), fullMinutes: full, elapsedMinutes: elapsed }
}

// accounted seconds as a fraction of target minutes; null when there is no
// target (before the day starts, or not a work day).
function fraction(seconds, minutes) {
  var target = Number(minutes) * 60
  if (!(target > 0)) return null
  return Math.max(0, Number(seconds) || 0) / target
}

// Whole percent of a fraction, or null.
function percent(seconds, minutes) {
  var f = fraction(seconds, minutes)
  return f === null ? null : Math.round(f * 100)
}

// Seconds as "H:MM" (truncated, never rounded up past the clock).
function formatHM(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  return h + ":" + (m < 10 ? "0" : "") + m
}

// Seconds as "H:MM:SS".
function formatHMS(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var sec = s % 60
  return formatHM(s) + ":" + (sec < 10 ? "0" : "") + sec
}

// Validates the settings form. Returns { ok, errors: { key: code } } where
// code is a short machine code the QML maps to a translated message.
function validate(settings) {
  var s = settings || {}
  var errors = {}
  var keys = ["workStart", "workEnd", "lunchStart", "lunchEnd"]
  for (var i = 0; i < keys.length; i++)
    if (parseHHMM(s[keys[i]]) === null) errors[keys[i]] = "time"
  if (!errors.workStart && !errors.workEnd && parseHHMM(s.workEnd) <= parseHHMM(s.workStart))
    errors.workEnd = "order"
  if (!errors.lunchStart && !errors.lunchEnd && parseHHMM(s.lunchEnd) < parseHHMM(s.lunchStart))
    errors.lunchEnd = "order"
  return { ok: Object.keys(errors).length === 0, errors: errors }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    DEFAULTS: DEFAULTS,
    parseHHMM: parseHHMM,
    formatHHMM: formatHHMM,
    parseWorkDays: parseWorkDays,
    formatWorkDays: formatWorkDays,
    isoWeekday: isoWeekday,
    makeConfig: makeConfig,
    dayMinutes: dayMinutes,
    isWorkDay: isWorkDay,
    elapsedMinutesOn: elapsedMinutesOn,
    phase: phase,
    segmentStartMs: segmentStartMs,
    weekStart: weekStart,
    isoDate: isoDate,
    today: today,
    week: week,
    fraction: fraction,
    percent: percent,
    formatHM: formatHM,
    formatHMS: formatHMS,
    validate: validate
  }
}
