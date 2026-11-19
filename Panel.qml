import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "WorkTime.js" as WorkTime
import "Model.js" as Model

// Teamwork timers in the bar. Everything that talks to Teamwork goes through
// bin/teamwork (one JSON object per call); this file keeps the snapshot, ticks
// the running timer locally, and owns the background poll and reminders.
// refreshIntervalSec 0 turns the poll off: it then refreshes only when the
// panel opens and after an action, and reminders work from that snapshot.
//
// A bar surface exists per monitor, so the first live instance (the leader)
// polls and sends reminders and hands each snapshot to its peers.
Panel {
  id: root
  moduleName: "tomhayes.teamwork"
  ipcTarget: "tomhayes.teamwork"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  function tr(key) { return strings.t(key) }
  function trn(key, count) { return strings.tn(key, count) }

  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/teamwork").toString().replace(/^file:\/\//, ""))

  // ------------------------------------------------------------------ glyphs
  readonly property string glyphTimer: String.fromCodePoint(0xF051B)
  readonly property string glyphPlay: String.fromCodePoint(0xF040A)
  readonly property string glyphPause: String.fromCodePoint(0xF03E4)
  readonly property string glyphCheck: String.fromCodePoint(0xF012C)
  readonly property string glyphDelete: String.fromCodePoint(0xF01B4)
  readonly property string glyphOpen: String.fromCodePoint(0xF03CC)
  readonly property string glyphCog: String.fromCodePoint(0xF0493)
  readonly property string glyphRefresh: String.fromCodePoint(0xF0450)
  readonly property string glyphClose: String.fromCodePoint(0xF0156)
  readonly property string glyphLog: String.fromCodePoint(0xF0150)
  readonly property string glyphChevronDown: String.fromCodePoint(0xF0140)
  readonly property string glyphChevronLeft: String.fromCodePoint(0xF0141)
  readonly property string glyphChevronRight: String.fromCodePoint(0xF0142)
  readonly property string glyphBack: Commons.I18n.rightToLeft ? String.fromCodePoint(0xF0142) : String.fromCodePoint(0xF0141)

  // ------------------------------------------------------------------ theme
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- settings
  // Fallbacks match manifest.json's barWidget.defaults.
  readonly property var defaults: ({
    siteUrl: "",
    workDays: "1,2,3,4,5",
    workStart: "09:00",
    workEnd: "17:30",
    lunchStart: "12:30",
    lunchEnd: "13:30",
    nagEnabled: true,
    nagIntervalMin: 15,
    refreshIntervalSec: 60,
    longTimerWarnHours: 3,
    notifyAfterHours: true,
    sortField: ""
  })
  function settingValue(key) { return setting(key, defaults[key]) }
  function clampInt(v, lo, hi, fallback) {
    var n = Math.round(Number(v))
    return isFinite(n) ? Math.max(lo, Math.min(hi, n)) : fallback
  }

  // "" until the user enters theirs: an empty or invalid site is not configured.
  readonly property string siteUrl: Model.cleanSiteUrl(settingValue("siteUrl"))
  // A task custom field to show as a badge and rank by; "" turns it off.
  function cleanSortField(v) { return String(v === undefined || v === null ? "" : v).replace(/\s+/g, " ").trim().slice(0, 100) }
  readonly property string sortField: cleanSortField(settingValue("sortField"))
  readonly property var workCfg: WorkTime.makeConfig({
    workDays: String(settingValue("workDays")),
    workStart: String(settingValue("workStart")),
    workEnd: String(settingValue("workEnd")),
    lunchStart: String(settingValue("lunchStart")),
    lunchEnd: String(settingValue("lunchEnd"))
  })
  readonly property bool nagEnabled: settingValue("nagEnabled") !== false
  readonly property int nagIntervalMin: clampInt(settingValue("nagIntervalMin"), 5, 120, 15)
  // 0 = no background polling (Model.refreshInterval).
  readonly property int refreshIntervalSec: Model.refreshInterval(settingValue("refreshIntervalSec"))
  readonly property int longTimerWarnHours: clampInt(settingValue("longTimerWarnHours"), 0, 24, 3)
  readonly property bool notifyAfterHours: settingValue("notifyAfterHours") !== false

  // ------------------------------------------------------------------- state
  property bool hasKey: false
  property bool keyChecked: false
  readonly property bool configured: hasKey && siteUrl !== ""
  property var snapshot: null
  property double fetchedMs: 0
  property string lastError: ""
  property string lastErrorCode: ""
  property int failures: 0
  property var statusCall: null
  // A refresh asked for while one is in flight runs again when it lands, so
  // an action's result is never overwritten by a fetch that started before it.
  property bool refreshAgain: false
  property double nowMs: Date.now()

  // "main" or "settings".
  property string view: "main"
  // "", "log" or "discard": the inline form under the current timer.
  property string timerForm: ""
  // The task whose manual-log form is open (0 for none).
  property int logTaskId: 0
  property int busy: 0
  property string actionError: ""

  // The task last seen timing here, for "resume" when no timer exists.
  property var lastTask: null

  // Search: Enter in the filter with no local match asks Teamwork.
  property string filterText: ""
  property string searchQuery: ""
  property bool searchBusy: false
  property var searchResults: null

  // Reminder bookkeeping (leader only).
  property double lastNagMs: 0
  property double idleSinceMs: Date.now()
  property var nagCall: null
  property string nagNotificationId: ""
  property var warnedLong: ({})
  property var warnedBoundary: ({})

  // Settings form drafts (see SettingsView.qml).
  property var draft: ({})
  property string settingsMessage: ""
  property bool settingsMessageError: false
  property bool keyBusy: false
  property string keyMessage: ""
  property bool keyMessageError: false
  property string keyStorage: ""

  // --------------------------------------------------------------- derived
  readonly property var timers: snapshot ? snapshot.timers : []
  readonly property var tasks: snapshot ? snapshot.tasks : []
  readonly property var current: Model.currentTimer(timers)
  readonly property bool running: !!current && current.running
  readonly property int currentSeconds: Model.liveSeconds(current, fetchedMs, nowMs)
  readonly property int unlogged: Model.unloggedSeconds(timers, fetchedMs, nowMs)
  readonly property var todayWork: WorkTime.today(new Date(nowMs), workCfg)
  readonly property var weekWork: WorkTime.week(new Date(nowMs), workCfg)
  // A snapshot from yesterday (or last week) says nothing about today.
  readonly property int loggedToday: snapshot && snapshot.today.date === todayWork.date ? snapshot.today.loggedSeconds : 0
  readonly property int loggedWeek: snapshot && snapshot.week.start === weekWork.start ? snapshot.week.loggedSeconds : 0
  readonly property bool inWorkTime: todayWork.phase === "working"
  readonly property var resumeTarget: Model.resumeTarget(snapshot, lastTask)
  // With polling off the last snapshot counts as fresh, so reminders still run.
  readonly property bool dataFresh: Model.dataFresh(!!snapshot, lastError, nowMs, fetchedMs, refreshIntervalSec)

  // ---------------------------------------------------------------- formats
  function digits(text) {
    var zero = Commons.I18n.zeroDigit
    var s = String(text)
    if (!zero || zero === "0") return s
    var base = zero.charCodeAt(0)
    return s.replace(/[0-9]/g, function(d) { return String.fromCharCode(base + d.charCodeAt(0) - 48) })
  }
  function hm(seconds) { return digits(WorkTime.formatHM(seconds)) }
  function hms(seconds) { return digits(WorkTime.formatHMS(seconds)) }
  function hmMinutes(minutes) { return hm(Math.round(minutes * 60)) }
  function pct(value) { return Commons.I18n.formatNumber(value) }
  function locale() { return Qt.locale(Commons.I18n.formatLocale) }
  function dayShortName(iso) { return locale().dayName(iso % 7, Locale.ShortFormat) }
  function clockText(ms) { return new Date(ms).toLocaleTimeString(locale(), Locale.ShortFormat) }
  function dueText(iso) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || ""))
    if (!m) return ""
    var sameYear = m[1] === root.todayKey.slice(0, 4)
    return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])).toLocaleDateString(locale(), sameYear ? "d MMM" : "d MMM yyyy")
  }
  // A row's due text, compact for its group: what the group header already
  // says isn't repeated. { text, late }
  function dueLabel(iso, group) {
    var info = Model.dueInfo(iso, root.todayKey)
    if (info.group === "noDate") return { text: "", late: false }
    if (info.group === "overdue")
      return { text: trn("due.late", -info.days).arg(Commons.I18n.formatNumber(-info.days)), late: true }
    if (info.group === "today" || info.group === "tomorrow")
      return { text: group === info.group ? "" : tr("due." + info.group), late: false }
    if (info.group === "thisWeek" || info.group === "nextWeek") {
      var day = locale().dayName(info.weekday, Locale.ShortFormat)
      // Outside its own group a weekday alone is ambiguous: next week says so.
      if (group !== info.group && info.group === "nextWeek") return { text: tr("due.nextWeekday").arg(day), late: false }
      return { text: tr("tasks.due").arg(day), late: false }
    }
    return { text: tr("tasks.due").arg(dueText(iso)), late: false }
  }
  function errorText(code, message) {
    if (code === "auth") return tr("error.auth")
    if (code === "network") return tr("error.network")
    if (code === "config") return tr("error.config")
    if (code === "helper") return tr("error.helper")
    return tr("error.generic").arg(String(message || ""))
  }

  // ------------------------------------------------------------------- bar
  readonly property string barGlyph: !configured ? glyphTimer : (running ? glyphPause : glyphPlay)
  readonly property bool showLabel: configured && !(bar && bar.vertical)
  readonly property string barLabel: {
    if (!showLabel) return ""
    if (!current) return tr("bar.noTimer")
    return Model.truncate(current.taskName || current.projectName || "#" + current.taskId, 24) + "  " + hms(currentSeconds)
  }
  readonly property color barBase: barForeground
  readonly property color pillColor: {
    if (!configured) return barBase
    if (running) return accent
    if (!current && inWorkTime && !!snapshot)
      return Qt.tint(barBase, Qt.rgba(urgent.r, urgent.g, urgent.b, 0.6))
    return barBase
  }
  readonly property bool pillDimmed: !configured || (!!current && !running)

  // ---------------------------------------------------------------- peers
  function peers() {
    return root.bar && typeof root.bar.moduleWidgets === "function" ? root.bar.moduleWidgets(root.moduleName) : []
  }
  // The first instance the bar lists leads. One the bar no longer lists (left
  // over from a reload) never does, so it can't poll or nag twice.
  function isLeader() {
    var p = peers()
    return p.length === 0 || p[0] === root
  }
  function shareState() {
    var p = peers()
    for (var i = 0; i < p.length; i++) {
      if (p[i] && p[i] !== root && typeof p[i].receiveState === "function")
        p[i].receiveState({ snapshot: root.snapshot, fetchedMs: root.fetchedMs, lastError: root.lastError,
                            lastErrorCode: root.lastErrorCode, failures: root.failures, hasKey: root.hasKey,
                            keyChecked: root.keyChecked, lastTask: root.lastTask })
    }
  }
  function receiveState(s) {
    if (!s) return
    root.snapshot = s.snapshot
    root.fetchedMs = s.fetchedMs
    root.lastError = s.lastError
    root.lastErrorCode = s.lastErrorCode
    root.failures = s.failures
    root.hasKey = s.hasKey
    root.keyChecked = s.keyChecked
    if (s.lastTask) root.lastTask = s.lastTask
    root.schedulePoll()
  }

  // (Re)arms the background poll, or stops it when polling is off.
  function schedulePoll() {
    if (root.configured && root.refreshIntervalSec > 0) pollTimer.restart()
    else pollTimer.stop()
  }

  // -------------------------------------------------------------- helper
  function helperArgs(cmd) {
    var args = [root.helper]
    if (root.siteUrl !== "") args.push("--site", root.siteUrl)
    // One argv entry, so a name starting with "-" can't be read as an option.
    if (root.sortField !== "") args.push("--sort-field=" + root.sortField)
    return args.concat(cmd)
  }

  // Runs bin/teamwork with argv `cmd` (never through a shell); `done` gets
  // the parsed result. `input` goes to its stdin, which is then closed.
  function callHelper(cmd, done, input) {
    var call = helperCallComponent.createObject(root, {
      command: root.helperArgs(cmd),
      handler: done || null,
      input: input || ""
    })
    if (!call) {
      if (done) done({ ok: false, error: "helper", code: "helper" })
      return null
    }
    call.running = true
    return call
  }

  function checkKey() {
    callHelper(["has-key"], function(res) {
      root.keyChecked = true
      if (res.ok) {
        var had = root.hasKey
        root.hasKey = res.hasKey === true
        if (root.lastErrorCode === "helper") { root.lastError = ""; root.lastErrorCode = "" }
        if (root.hasKey && !had) root.refresh()
        if (!root.hasKey) root.snapshot = null
      } else {
        root.lastError = root.errorText(res.code === "usage" ? "helper" : res.code, res.error)
        root.lastErrorCode = res.code
      }
      root.shareState()
    })
  }

  function refresh() {
    if (!root.configured) {
      if (!root.keyChecked) root.checkKey()
      return
    }
    if (root.statusCall) {
      root.refreshAgain = true
      return
    }
    root.refreshAgain = false
    root.statusCall = callHelper(["status"], function(res) {
      root.statusCall = null
      if (root.refreshAgain) {
        // Stale by the time it landed: fetch again instead of showing it.
        Qt.callLater(root.refresh)
        return
      }
      if (res.ok) {
        var snap = Model.cleanSnapshot(res)
        if (snap) {
          root.snapshot = snap
          root.fetchedMs = Date.now()
          root.nowMs = root.fetchedMs
          root.lastError = ""
          root.lastErrorCode = ""
          root.failures = 0
          root.noteCurrent()
        }
      } else if (res.code === "config" && /key/i.test(res.error)) {
        // The key went missing (cleared elsewhere): back to not configured.
        root.hasKey = false
        root.snapshot = null
        root.lastError = ""
      } else {
        root.failures = root.failures + 1
        root.lastError = root.errorText(res.code === "usage" ? "helper" : res.code, res.error)
        root.lastErrorCode = res.code
      }
      root.shareState()
      root.schedulePoll()
      root.housekeeping()
    })
  }

  // Remember what's timing, for resume, and when the timer stopped, so the
  // nag waits a full interval from then.
  function noteCurrent() {
    var r = Model.runningTimer(root.timers)
    if (r && r.taskId) root.lastTask = { id: r.taskId, name: r.taskName }
  }
  onRunningChanged: if (!running) idleSinceMs = Date.now()

  // Patch a timer the helper just returned into the snapshot, so the bar
  // answers at once; the refresh that follows settles the rest.
  function applyTimer(raw, exclusive) {
    if (!root.snapshot || !raw) return
    var cleaned = Model.cleanSnapshot({ ok: true, timers: [raw] }).timers[0]
    if (!cleaned) return
    var next = []
    var found = false
    for (var i = 0; i < root.snapshot.timers.length; i++) {
      var t = root.snapshot.timers[i]
      if (t.id === cleaned.id) { next.push(cleaned); found = true }
      else next.push(exclusive && cleaned.running ? Object.assign({}, t, { running: false }) : t)
    }
    if (!found) next.unshift(cleaned)
    // Carry the running timer's local tick over to the new fetch time.
    var now = Date.now()
    for (var j = 0; j < next.length; j++)
      if (next[j].running && next[j].id !== cleaned.id)
        next[j] = Object.assign({}, next[j], { elapsedSeconds: Model.liveSeconds(next[j], root.fetchedMs, now) })
    root.snapshot = Object.assign({}, root.snapshot, { timers: next })
    root.fetchedMs = now
    root.nowMs = now
    root.noteCurrent()
    root.shareState()
  }

  function removeTimer(timerId) {
    if (!root.snapshot) return
    var now = Date.now()
    var next = []
    for (var i = 0; i < root.snapshot.timers.length; i++) {
      var t = root.snapshot.timers[i]
      if (t.id === timerId) continue
      next.push(t.running ? Object.assign({}, t, { elapsedSeconds: Model.liveSeconds(t, root.fetchedMs, now) }) : t)
    }
    root.snapshot = Object.assign({}, root.snapshot, { timers: next })
    root.fetchedMs = now
    root.shareState()
  }

  function actionDone(res, onOk) {
    root.busy = Math.max(0, root.busy - 1)
    if (res.ok) {
      root.actionError = ""
      if (onOk) onOk(res)
    } else {
      root.actionError = root.errorText(res.code === "usage" ? "helper" : res.code, res.error)
      if (!root.opened) root.notify(root.tr("notify.actionFailed"), root.actionError, [], null)
    }
    Qt.callLater(root.refresh)
  }

  function runAction(cmd, onOk) {
    root.busy = root.busy + 1
    root.actionError = ""
    callHelper(cmd, function(res) { root.actionDone(res, onOk) })
  }

  function startTask(taskId, name) {
    if (!Model.cleanSiteUrl(root.siteUrl) || !(taskId > 0)) return
    root.lastTask = { id: taskId, name: String(name || "") }
    runAction(["start", String(taskId)], function(res) { root.applyTimer(res.timer, true) })
  }
  function pauseTimer(timerId) {
    if (!(timerId > 0)) return
    runAction(["pause", String(timerId)], function(res) { root.applyTimer(res.timer, false) })
  }
  function resumeTimer(timerId) {
    if (!(timerId > 0)) return
    runAction(["resume", String(timerId)], function(res) { root.applyTimer(res.timer, true) })
  }
  function completeTimer(timerId, description) {
    if (!(timerId > 0)) return
    var cmd = ["complete", String(timerId)]
    var desc = String(description || "").trim()
    // --opt=value keeps a description that starts with "-" an argument.
    if (desc !== "") cmd.push("--description=" + desc)
    runAction(cmd, function() { root.removeTimer(timerId); root.timerForm = "" })
  }
  function discardTimer(timerId) {
    if (!(timerId > 0)) return
    runAction(["discard", String(timerId)], function() { root.removeTimer(timerId); root.timerForm = "" })
  }
  function logTime(taskId, minutes, description) {
    var mins = Math.round(Number(minutes))
    if (!(taskId > 0) || !(mins >= 1 && mins <= 1440)) return false
    var cmd = ["log", String(taskId), "--minutes=" + mins]
    var desc = String(description || "").trim()
    if (desc !== "") cmd.push("--description=" + desc)
    runAction(cmd, function() { root.logTaskId = 0 })
    return true
  }

  // The bar's play/pause: toggles the current timer; with none, resumes the
  // last task; with nothing known, opens the panel.
  function toggleTimer() {
    if (!root.configured) { root.openSettings(); return }
    if (root.busy > 0) return
    if (root.current) {
      if (root.current.running) root.pauseTimer(root.current.id)
      else root.resumeTimer(root.current.id)
      return
    }
    var target = root.resumeTarget
    if (target) root.startTask(target.id, target.name)
    else root.open()
  }

  function search(query) {
    var q = String(query || "").trim()
    if (q === "" || !root.configured) return
    root.searchQuery = q.slice(0, 200)
    root.searchBusy = true
    root.searchResults = []
    // "--" so a query starting with "-" stays the query.
    callHelper(["search", "--", root.searchQuery], function(res) {
      if (q.slice(0, 200) !== root.searchQuery) return
      root.searchBusy = false
      if (res.ok) {
        root.searchResults = Model.cleanSnapshot({ ok: true, tasks: res.tasks }).tasks.slice(0, 30)
        root.actionError = ""
      } else {
        root.searchResults = []
        root.actionError = root.errorText(res.code, res.error)
      }
    })
  }
  function clearSearch() {
    root.searchQuery = ""
    root.searchResults = null
    root.searchBusy = false
  }

  function openTask(taskId) {
    var url = Model.taskUrl(root.siteUrl, taskId)
    if (url === "") return
    var p = openerComponent.createObject(root, { command: ["xdg-open", url] })
    if (p) p.running = true
  }

  // Back to the panel's key handling, out of whichever field had focus.
  function focusPanel() {
    if (panel.loadedContent) panel.loadedContent.forceActiveFocus()
  }

  function openSettings() {
    root.loadDrafts()
    root.view = "settings"
    root.open()
  }

  // ------------------------------------------------------- notifications
  // notify-send waits while a notification has actions, printing its id
  // (-p) first and then the action picked. Each runs in its own Process.
  function notify(summary, body, actions, onAction) {
    var args = ["notify-send", "-a", "Teamwork", "-i", "teamwork", "-p"]
    for (var i = 0; i < actions.length; i++) args.push("--action=" + actions[i].id + "=" + actions[i].label)
    args.push("--", Model.notifySafe(summary, 80), Model.notifySafe(body, 200))
    var p = notifyComponent.createObject(root, { command: args, actionHandler: onAction || null })
    if (p) p.running = true
    return p
  }

  function sendNag() {
    var actions = []
    var startAction = null
    if (root.current && !root.current.running) {
      actions.push({ id: "start", label: Model.notifySafe(root.tr("notify.resume").arg(Model.truncate(root.current.taskName, 40)), 60) })
      startAction = { timerId: root.current.id }
    } else if (root.resumeTarget) {
      actions.push({ id: "start", label: Model.notifySafe(root.tr("notify.start").arg(Model.truncate(root.resumeTarget.name, 40)), 60) })
      startAction = { taskId: root.resumeTarget.id, name: root.resumeTarget.name }
    }
    actions.push({ id: "open", label: root.tr("notify.open") })

    var args = ["notify-send", "-a", "Teamwork", "-i", "teamwork", "-p"]
    // Replace the last nag rather than stacking another beside it.
    if (/^\d+$/.test(root.nagNotificationId)) args.push("-r", root.nagNotificationId)
    for (var i = 0; i < actions.length; i++) args.push("--action=" + actions[i].id + "=" + actions[i].label)
    args.push("--", root.tr("notify.nagTitle"), Model.notifySafe(root.tr("notify.nagBody"), 200))

    if (root.nagCall) root.nagCall.running = false
    var p = notifyComponent.createObject(root, {
      command: args,
      idHandler: function(id) { root.nagNotificationId = id },
      actionHandler: function(action) {
        if (action === "start" && startAction) {
          if (startAction.timerId) root.resumeTimer(startAction.timerId)
          else root.startTask(startAction.taskId, startAction.name)
        } else if (action === "open") {
          root.summonPanel()
        }
      }
    })
    root.nagCall = p
    if (p) p.running = true
  }

  function summonPanel() {
    var ok = root.bar && root.bar.shell && typeof root.bar.shell.summon === "function"
      ? root.bar.shell.summon(root.moduleName, "") : false
    if (!ok) root.open()
  }

  function timerActions(timerId) {
    return {
      actions: [{ id: "pause", label: root.tr("notify.pause") }, { id: "open", label: root.tr("notify.open") }],
      handler: function(action) {
        if (action === "pause") root.pauseTimer(timerId)
        else if (action === "open") root.summonPanel()
      }
    }
  }

  // Runs every 30 s on the leader, and after each refresh.
  function housekeeping() {
    root.nowMs = Date.now()
    if (!root.isLeader()) return
    var now = new Date(root.nowMs)

    if (root.statusCall && root.statusCall.startedAt && root.nowMs - root.statusCall.startedAt > 120000)
      root.statusCall.running = false

    if (Model.shouldNag({
      nowMs: root.nowMs, phase: root.todayWork.phase, configured: root.configured, nagEnabled: root.nagEnabled,
      hasRunningTimer: root.running, dataFresh: root.dataFresh, intervalMin: root.nagIntervalMin,
      lastNagMs: root.lastNagMs, idleSinceMs: root.idleSinceMs, segmentStartMs: WorkTime.segmentStartMs(now, root.workCfg) || 0
    })) {
      root.lastNagMs = root.nowMs
      root.sendNag()
    }

    if (!root.running || !root.dataFresh) return
    var t = root.current
    var name = Model.truncate(t.taskName || t.projectName, 60)

    if (root.longTimerWarnHours > 0 && root.currentSeconds >= root.longTimerWarnHours * 3600 && !root.warnedLong[t.id]) {
      var warned = Object.assign({}, root.warnedLong)
      warned[t.id] = true
      root.warnedLong = warned
      var a = root.timerActions(t.id)
      // One pass, so a "%2" in the task name stays as typed.
      root.notify(root.tr("notify.longTitle"), Model.formatArgs(root.tr("notify.longBody"), [name, root.hm(root.currentSeconds)]), a.actions, a.handler)
    }

    var phase = root.todayWork.phase
    if (root.notifyAfterHours && root.todayWork.workDay && (phase === "lunch" || phase === "after")) {
      var key = root.todayWork.date + ":" + phase
      if (!root.warnedBoundary[key]) {
        var marked = Object.assign({}, root.warnedBoundary)
        marked[key] = true
        root.warnedBoundary = marked
        var b = root.timerActions(t.id)
        if (phase === "lunch")
          root.notify(root.tr("notify.lunchTitle"), root.tr("notify.lunchBody").arg(name), b.actions, b.handler)
        else
          root.notify(root.tr("notify.afterTitle"), root.tr("notify.afterBody").arg(name), b.actions, b.handler)
      }
    }
  }

  // --------------------------------------------------------------- settings
  function currentValues() {
    var out = {}
    for (var key in root.defaults) out[key] = root.settingValue(key)
    return out
  }
  function loadDrafts() {
    var v = root.currentValues()
    v.workDays = WorkTime.formatWorkDays(WorkTime.parseWorkDays(v.workDays))
    root.draft = v
    root.settingsMessage = ""
    root.keyMessage = ""
  }
  function setDraft(key, value) {
    var next = Object.assign({}, root.draft)
    next[key] = value
    root.draft = next
    root.settingsMessage = ""
  }
  function toggleDraftDay(iso) {
    var days = WorkTime.parseWorkDays(root.draft.workDays)
    var i = days.indexOf(iso)
    if (i === -1) days.push(iso)
    else days.splice(i, 1)
    root.setDraft("workDays", WorkTime.formatWorkDays(days))
  }
  readonly property var draftErrors: {
    var errors = WorkTime.validate(root.draft).errors
    if (String(root.draft.siteUrl || "").trim() === "") errors.siteUrl = "empty"
    else if (Model.cleanSiteUrl(root.draft.siteUrl) === "") errors.siteUrl = "site"
    return errors
  }
  readonly property bool draftValid: Object.keys(draftErrors).length === 0
  readonly property bool draftDirty: JSON.stringify(normalizedDraft()) !== JSON.stringify(currentValues())

  function normalizedDraft() {
    var d = root.draft
    return {
      siteUrl: Model.cleanSiteUrl(d.siteUrl) || String(d.siteUrl || ""),
      workDays: WorkTime.formatWorkDays(WorkTime.parseWorkDays(d.workDays)),
      workStart: WorkTime.parseHHMM(d.workStart) !== null ? WorkTime.formatHHMM(WorkTime.parseHHMM(d.workStart)) : String(d.workStart || ""),
      workEnd: WorkTime.parseHHMM(d.workEnd) !== null ? WorkTime.formatHHMM(WorkTime.parseHHMM(d.workEnd)) : String(d.workEnd || ""),
      lunchStart: WorkTime.parseHHMM(d.lunchStart) !== null ? WorkTime.formatHHMM(WorkTime.parseHHMM(d.lunchStart)) : String(d.lunchStart || ""),
      lunchEnd: WorkTime.parseHHMM(d.lunchEnd) !== null ? WorkTime.formatHHMM(WorkTime.parseHHMM(d.lunchEnd)) : String(d.lunchEnd || ""),
      nagEnabled: d.nagEnabled !== false,
      nagIntervalMin: root.clampInt(d.nagIntervalMin, 5, 120, 15),
      refreshIntervalSec: Model.refreshInterval(d.refreshIntervalSec),
      longTimerWarnHours: root.clampInt(d.longTimerWarnHours, 0, 24, 3),
      notifyAfterHours: d.notifyAfterHours !== false,
      sortField: root.cleanSortField(d.sortField)
    }
  }

  // Writes the non-secret settings to this widget's shell.json entry: the
  // whole entry, merged, since the shell replaces it with what it's given.
  function saveSettings() {
    if (!root.draftValid) return
    if (!root.draftDirty) {
      root.settingsMessage = root.tr("settings.unchanged")
      root.settingsMessageError = false
      return
    }
    var api = root.bar ? root.bar.shell : null
    if (!api || typeof api.updateEntryInline !== "function") {
      root.settingsMessage = root.tr("settings.saveFailed")
      root.settingsMessageError = true
      return
    }
    var entry = {}
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    var values = root.normalizedDraft()
    for (var key in values) entry[key] = values[key]
    api.updateEntryInline(root.moduleName, entry)
    root.settingsMessage = root.tr("settings.saved")
    root.settingsMessageError = false
    Qt.callLater(root.refresh)
  }

  // The key goes to the helper's stdin and nowhere else.
  function saveKey(key, done) {
    var k = String(key || "").trim()
    if (k === "") return
    if (root.siteUrl === "") {
      root.keyMessage = root.tr("settings.keyNeedsSite")
      root.keyMessageError = true
      return
    }
    root.keyBusy = true
    root.keyMessage = root.tr("settings.keyChecking")
    root.keyMessageError = false
    callHelper(["set-key"], function(res) {
      root.keyBusy = false
      if (res.ok) {
        root.hasKey = true
        root.keyChecked = true
        root.keyStorage = String(res.storage || "") === "file" ? "file" : "keyring"
        var who = res.user && typeof res.user === "object" ? Model.truncate(String(res.user.name || ""), 60) : ""
        root.keyMessage = root.tr("settings.keyOk").arg(who)
        root.keyMessageError = false
        root.lastError = ""
        root.failures = 0
        Qt.callLater(root.refresh)
      } else {
        root.keyMessage = res.code === "auth" ? root.tr("settings.keyRejected")
          : res.code === "usage" && /key/i.test(res.error) ? root.tr("settings.keyInvalid")
          : root.errorText(res.code, res.error)
        root.keyMessageError = true
      }
      root.shareState()
      if (done) done(res.ok === true)
    }, k + "\n")
    // Drop this function's references to the key; the Process clears its own.
    k = ""
    key = ""
  }

  function clearKey() {
    root.keyBusy = true
    callHelper(["clear-key"], function(res) {
      root.keyBusy = false
      if (res.ok) {
        root.hasKey = false
        root.snapshot = null
        root.keyStorage = ""
        root.lastError = ""
        root.keyMessage = root.tr("settings.keyRemoved")
        root.keyMessageError = false
      } else {
        root.keyMessage = root.errorText(res.code, res.error)
        root.keyMessageError = true
      }
      root.shareState()
    })
  }

  // ------------------------------------------------------------ lifecycle
  Component.onCompleted: Qt.callLater(function() {
    // A peer already showing a snapshot (another monitor's bar) lends it, so
    // this one doesn't start empty; the key is checked here either way.
    var p = root.peers()
    for (var i = 0; i < p.length; i++) {
      if (p[i] && p[i] !== root && p[i].snapshot) {
        root.receiveState({ snapshot: p[i].snapshot, fetchedMs: p[i].fetchedMs, lastError: p[i].lastError,
                            lastErrorCode: p[i].lastErrorCode, failures: p[i].failures, hasKey: p[i].hasKey,
                            keyChecked: false, lastTask: p[i].lastTask })
        break
      }
    }
    root.checkKey()
  })

  onOpenedChanged: {
    if (opened) {
      if (!root.configured && root.view === "main") root.loadDrafts()
      if (!root.configured) root.view = "settings"
      root.nowMs = Date.now()
      if (!root.keyChecked) root.checkKey()
      else root.refresh()
    } else {
      root.timerForm = ""
      root.logTaskId = 0
      if (root.view === "settings" && root.configured) root.view = "main"
    }
  }

  onConfiguredChanged: if (configured) Qt.callLater(refresh)

  Timer {
    id: pollTimer
    interval: Model.backoffMs(root.refreshIntervalSec, root.failures)
    running: root.configured && root.refreshIntervalSec > 0
    repeat: false
    onTriggered: {
      if (root.isLeader()) root.refresh()
      else root.schedulePoll()
    }
  }

  // Ticks the running timer; only while something shows it moving.
  Timer {
    interval: 1000
    repeat: true
    running: root.running || root.opened
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.housekeeping()
  }

  ShellIpc {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function settings(): void { root.openSettings() }
    function refresh(): string { root.refresh(); return "ok" }
    function toggleTimer(): string { root.toggleTimer(); return "ok" }
    function state(): string {
      return JSON.stringify({
        configured: root.configured, keyChecked: root.keyChecked, running: root.running,
        timer: root.current ? { id: root.current.id, taskId: root.current.taskId, seconds: root.currentSeconds } : null,
        tasks: root.tasks.length, phase: root.todayWork.phase, error: root.lastError,
        leader: root.isLeader(), opened: root.opened, view: root.view
      })
    }
  }

  // -------------------------------------------------------------- processes
  Component {
    id: helperCallComponent
    Process {
      id: call
      property var handler: null
      property string input: ""
      property bool delivered: false
      property double startedAt: Date.now()

      stdinEnabled: input !== ""
      onStarted: {
        call.startedAt = Date.now()
        if (call.input !== "") {
          call.write(call.input)
          call.input = ""
        }
      }
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: call.deliver(text)
      }
      onExited: Qt.callLater(function() {
        call.deliver("")
        call.destroy()
      })

      function deliver(text) {
        if (call.delivered) return
        call.delivered = true
        var res = Model.parseResult(text)
        if (!res.ok && text === "") res = { ok: false, error: "helper", code: "helper" }
        if (call.handler) call.handler(res)
      }
    }
  }

  Component {
    id: notifyComponent
    Process {
      id: note
      property var idHandler: null
      property var actionHandler: null
      property bool sawId: false

      stdout: SplitParser {
        onRead: function(line) {
          var value = String(line).trim()
          if (!note.sawId && /^\d+$/.test(value)) {
            note.sawId = true
            if (note.idHandler) note.idHandler(value)
          } else if ((value === "start" || value === "open" || value === "pause") && note.actionHandler) {
            note.actionHandler(value)
          }
        }
      }
      onExited: {
        if (root.nagCall === note) root.nagCall = null
        note.destroy()
      }
    }
  }

  Component {
    id: openerComponent
    Process {
      id: opener
      onExited: opener.destroy()
    }
  }

  // ------------------------------------------------------------------- bar
  implicitWidth: pill.implicitWidth
  implicitHeight: pill.implicitHeight

  Row {
    id: pill
    height: parent.height

    BarIconButton {
      id: glyphButton
      bar: root.bar
      text: root.barGlyph
      foreground: root.pillColor
      dimmed: root.pillDimmed
      tooltipText: ""
      onPressed: function(button) {
        if (button === Qt.RightButton) root.toggle()
        else if (button === Qt.MiddleButton) root.refresh()
        else root.toggleTimer()
      }
    }

    WidgetButton {
      id: labelButton
      bar: root.bar
      text: root.barLabel
      foreground: root.pillColor
      dimmed: root.pillDimmed
      horizontalMargin: 2
      tooltipText: ""
      // The stock press shrink (to 0.9) suits a glyph but makes a long label look broken.
      pressFeedbackButtons: Qt.NoButton
      onPressed: function(button) {
        if (button === Qt.MiddleButton) root.refresh()
        else root.toggle()
      }
    }
  }

  // ----------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: pill
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(680))

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: column.implicitHeight

      // Typing in a field goes to the field.
      blocked: {
        var f = keyCatcher.Window.activeFocusItem
        return !!f && f !== keyCatcher && ("cursorPosition" in f)
      }

      function scrollBy(dy) {
        flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy))
      }

      onMoveRequested: function(dx, dy) { if (dy !== 0) keyCatcher.scrollBy(dy * Style.space(56)) }
      onCloseRequested: {
        if (root.timerForm !== "") root.timerForm = ""
        else if (root.logTaskId !== 0) root.logTaskId = 0
        else if (root.view === "settings" && root.configured) root.view = "main"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if ((t === "p" || t === "P") && root.view === "main") root.toggleTimer()
        else if ((t === "/" || t === "f") && root.view === "main" && root.configured) filterField.forceActiveFocus()
        else if (t === "s" || t === "S") {
          if (root.view === "settings") { if (root.configured) root.view = "main" }
          else { root.loadDrafts(); root.view = "settings" }
          flick.contentY = 0
        }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          // ===================== Main view =====================
          Column {
            id: mainView
            visible: root.view === "main"
            width: parent.width
            spacing: Style.space(12)

            // ---------- Current timer ----------
            PanelHero {
              width: parent.width
              foreground: root.foreground
              fontFamily: root.fontFamily
              title: !root.configured ? root.tr("hero.title")
                : root.current ? (root.current.taskName || ("#" + root.current.taskId))
                : root.tr("hero.noTimer")
              meta: !root.configured ? root.tr("hero.notConfigured")
                : root.current ? ((root.running ? "" : root.tr("hero.paused") + " · ") + root.current.projectName)
                : root.tr("hero.pickTask")
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: root.glyphTimer
                  color: root.running ? root.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                Text {
                  visible: !!root.current
                  textFormat: Text.PlainText
                  text: root.hms(root.currentSeconds)
                  color: root.running ? root.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                  font.bold: true
                }
              }
            }

            Text {
              visible: !root.configured
              width: parent.width
              textFormat: Text.PlainText
              text: root.tr("hero.notConfiguredDetail")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Button {
              visible: !root.configured
              text: root.tr("action.openSettings")
              iconText: root.glyphCog
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: { root.loadDrafts(); root.view = "settings" }
            }

            // Timer actions.
            Item {
              visible: root.configured && !!root.current && root.timerForm === ""
              width: parent.width
              implicitHeight: timerButtons.implicitHeight

              Row {
                id: timerButtons
                anchors.left: parent.left
                spacing: Style.space(6)

                Button {
                  text: root.running ? root.tr("action.pause") : root.tr("action.resume")
                  iconText: root.running ? root.glyphPause : root.glyphPlay
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  enabled: root.busy === 0
                  opacity: enabled ? 1 : 0.5
                  onClicked: root.toggleTimer()
                }
                Button {
                  text: root.tr("action.logIt")
                  iconText: root.glyphCheck
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  onClicked: root.timerForm = "log"
                }
                Button {
                  text: root.tr("action.discard")
                  iconText: root.glyphDelete
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  onClicked: root.timerForm = "discard"
                }
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.verticalCenter: timerButtons.verticalCenter
                iconText: root.glyphOpen
                tooltipText: root.tr("action.openBrowser")
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.current) root.openTask(root.current.taskId)
              }
            }

            // Log it: optional description, then complete.
            Column {
              id: logForm
              visible: root.configured && !!root.current && root.timerForm === "log"
              width: parent.width
              spacing: Style.space(8)

              onVisibleChanged: if (visible) {
                logDescription.text = root.current ? root.current.description : ""
                Qt.callLater(function() { logDescription.forceActiveFocus() })
              }

              TextField {
                id: logDescription
                width: parent.width
                placeholderText: root.tr("log.description")
                foreground: root.foreground
                font.family: root.fontFamily
                maximumLength: 1000
                Keys.onReturnPressed: if (root.current) root.completeTimer(root.current.id, text)
                Keys.onEnterPressed: if (root.current) root.completeTimer(root.current.id, text)
                Keys.onEscapePressed: { root.timerForm = ""; root.focusPanel() }
              }

              Row {
                anchors.right: parent.right
                spacing: Style.space(6)
                Button {
                  text: root.tr("action.cancel")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: { root.timerForm = ""; root.focusPanel() }
                }
                Button {
                  text: root.tr("action.confirmLog")
                  iconText: root.glyphCheck
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  enabled: root.busy === 0
                  opacity: enabled ? 1 : 0.5
                  onClicked: if (root.current) root.completeTimer(root.current.id, logDescription.text)
                }
              }
            }

            // Discard: confirm first.
            Column {
              visible: root.configured && !!root.current && root.timerForm === "discard"
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.tr("discard.confirm")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Row {
                anchors.right: parent.right
                spacing: Style.space(6)
                Button {
                  text: root.tr("action.cancel")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.timerForm = ""
                }
                Button {
                  text: root.tr("action.confirmDiscard")
                  iconText: root.glyphDelete
                  foreground: root.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  enabled: root.busy === 0
                  opacity: enabled ? 1 : 0.5
                  onClicked: if (root.current) root.discardTimer(root.current.id)
                }
              }
            }

            // No timer: offer the last task.
            Button {
              visible: root.configured && !root.current && !!root.resumeTarget
              width: Math.min(implicitWidth, parent.width)
              text: root.resumeTarget ? root.tr("action.startTask").arg(Model.truncate(root.resumeTarget.name, 40)) : ""
              iconText: root.glyphPlay
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              enabled: root.busy === 0
              onClicked: root.toggleTimer()
            }

            Text {
              visible: root.actionError !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: root.actionError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // ---------- Today and this week ----------
            PanelSeparator { visible: root.configured && !!root.snapshot; foreground: root.foreground }

            SummaryBlock {
              visible: root.configured && !!root.snapshot
              width: parent.width
              heading: root.tr("summary.today")
              logged: root.loggedToday
              timer: root.unlogged
              elapsedMinutes: root.todayWork.elapsedMinutes
              fullMinutes: root.todayWork.fullMinutes
              targetKey: "summary.dayTarget"
              emptyText: !root.todayWork.workDay ? root.tr("summary.dayOff")
                : root.todayWork.phase === "before" ? root.tr("summary.notStarted").arg(root.digits(WorkTime.formatHHMM(root.workCfg.start)))
                : ""
            }

            SummaryBlock {
              visible: root.configured && !!root.snapshot
              width: parent.width
              heading: root.tr("summary.week")
              logged: root.loggedWeek
              timer: root.unlogged
              elapsedMinutes: root.weekWork.elapsedMinutes
              fullMinutes: root.weekWork.fullMinutes
              targetKey: "summary.weekTarget"
              emptyText: root.workCfg.workDays.length === 0 ? root.tr("summary.noWorkDays")
                : root.weekWork.elapsedMinutes <= 0 ? root.tr("summary.notStarted").arg(root.digits(WorkTime.formatHHMM(root.workCfg.start)))
                : ""
            }

            // Logged hours per work day, Monday first.
            Row {
              id: weekRow
              visible: root.configured && !!root.snapshot && root.workCfg.workDays.length > 0
              width: parent.width
              spacing: Style.space(6)
              readonly property int count: Math.max(1, root.workCfg.workDays.length)
              readonly property real cellWidth: (width - spacing * (count - 1)) / count

              Repeater {
                model: root.workCfg.workDays

                DayBar {
                  required property int modelData
                  width: weekRow.cellWidth
                  iso: modelData
                }
              }
            }

            // ---------- Tasks ----------
            PanelSeparator { visible: root.configured; foreground: root.foreground }

            TextField {
              id: filterField
              visible: root.configured
              width: parent.width
              placeholderText: root.tr("tasks.filter")
              foreground: root.foreground
              font.family: root.fontFamily
              maximumLength: 200
              text: root.filterText
              onTextEdited: {
                root.filterText = text
                if (root.searchResults !== null) root.clearSearch()
              }
              Keys.onReturnPressed: root.filterEnter()
              Keys.onEnterPressed: root.filterEnter()
              Keys.onEscapePressed: {
                if (text !== "") { root.filterText = ""; root.clearSearch() }
                else root.focusPanel()
              }
            }

            Item {
              visible: root.configured
              width: parent.width
              implicitHeight: Math.max(taskHeader.implicitHeight, clearSearchButton.visible ? clearSearchButton.implicitHeight : 0)

              PanelSectionHeader {
                id: taskHeader
                anchors.left: parent.left
                anchors.right: clearSearchButton.visible ? clearSearchButton.left : parent.right
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: root.searchResults !== null
                  ? root.tr("tasks.searchHeader").arg(Model.truncate(root.searchQuery, 40))
                  : root.tr("tasks.header") + "  ·  " + root.trn("tasks.count", root.visibleTasks.length).arg(Commons.I18n.formatNumber(root.visibleTasks.length))
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              PanelActionButton {
                id: clearSearchButton
                visible: root.searchResults !== null
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.glyphClose
                tooltipText: root.tr("action.clearSearch")
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.clearSearch()
              }
            }

            Text {
              visible: root.configured && text !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: {
                if (root.searchResults !== null) {
                  if (root.searchBusy) return root.tr("tasks.searching")
                  return root.searchResults.length === 0 ? root.tr("tasks.searchEmpty") : ""
                }
                if (!root.snapshot) return ""
                if (root.tasks.length === 0) return root.tr("tasks.empty")
                return root.visibleTasks.length === 0 ? root.tr("tasks.noMatch") : ""
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            // One block per non-empty due group: a header that collapses it,
            // then its rows (up to groupRowCap, the rest counted).
            Column {
              visible: root.configured
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.taskGroups

                Column {
                  id: groupBlock
                  required property var modelData
                  readonly property string key: modelData.key
                  // Filtering or searching shows every match, so groups open while either is active.
                  readonly property bool collapsed: !!root.collapsedGroups[key]
                    && root.filterText.trim() === "" && root.searchResults === null
                  readonly property int more: Math.max(0, modelData.tasks.length - root.groupRowCap)
                  width: parent.width
                  spacing: Style.space(2)

                  GroupHeader {
                    width: parent.width
                    groupKey: groupBlock.key
                    count: groupBlock.modelData.tasks.length
                    collapsed: groupBlock.collapsed
                  }

                  Repeater {
                    model: groupBlock.collapsed ? [] : groupBlock.modelData.tasks.slice(0, root.groupRowCap)

                    TaskRow {
                      required property var modelData
                      width: groupBlock.width
                      host: root
                      task: modelData
                      group: groupBlock.key
                    }
                  }

                  Text {
                    visible: !groupBlock.collapsed && groupBlock.more > 0
                    width: parent.width
                    textFormat: Text.PlainText
                    text: root.trn("tasks.more", groupBlock.more).arg(Commons.I18n.formatNumber(groupBlock.more))
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    horizontalAlignment: Text.AlignHCenter
                  }
                }
              }
            }
          }

          // ===================== Settings view =====================
          SettingsView {
            visible: root.view === "settings"
            width: parent.width
            host: root
          }

          // ---------- Footer: status, refresh, settings ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(footerText.implicitHeight, footerButtons.implicitHeight)

            Text {
              id: footerText
              anchors.left: parent.left
              anchors.right: footerButtons.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.footerStatus
              color: root.lastError !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }

            Row {
              id: footerButtons
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              PanelActionButton {
                visible: root.configured
                iconText: root.glyphRefresh
                tooltipText: root.tr("action.refresh")
                foreground: root.statusCall ? root.accent : root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.refresh()
              }

              PanelActionButton {
                iconText: root.view === "settings" ? root.glyphBack : root.glyphCog
                tooltipText: root.view === "settings" ? root.tr("action.back") : root.tr("action.settings")
                foreground: root.view === "settings" ? root.accent : root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                visible: root.view !== "settings" || root.configured
                onClicked: {
                  if (root.view === "settings") root.view = "main"
                  else { root.loadDrafts(); root.view = "settings" }
                  flick.contentY = 0
                }
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ task list
  readonly property var visibleTasks: searchResults !== null ? searchResults : Model.filterTasks(tasks, filterText)
  // Grouped by due date (Model.GROUPS). todayKey only changes at midnight,
  // so the second tick doesn't rebuild the list.
  readonly property string todayKey: todayWork.date
  readonly property var taskGroups: Model.groupTasks(visibleTasks, todayKey, timers)
  // Rows drawn per group; the rest are counted under it. Every group's
  // header shows, whatever the cap.
  readonly property int groupRowCap: 50
  // Collapsed groups, kept in memory for as long as the shell runs.
  property var collapsedGroups: Object.assign({}, Model.COLLAPSED_BY_DEFAULT)
  function toggleGroup(key) {
    var next = Object.assign({}, root.collapsedGroups)
    next[key] = !next[key]
    root.collapsedGroups = next
  }

  function filterEnter() {
    var q = root.filterText.trim()
    if (q === "") return
    if (root.searchResults === null && Model.filterTasks(root.tasks, q).length > 0) return
    root.search(q)
  }

  readonly property string footerStatus: {
    if (!root.configured) return root.lastError
    if (root.lastError !== "") {
      return root.snapshot
        ? root.tr("footer.stale").arg(root.clockText(root.fetchedMs)).arg(root.lastError)
        : root.lastError
    }
    if (!root.snapshot) return root.tr("footer.loading")
    return root.tr("footer.updated").arg(root.clockText(root.fetchedMs))
  }

  // ------------------------------------------------------------ components
  // A due group's header: chevron, name and count. Clicking it collapses or
  // expands the group; Overdue reads in the urgent colour.
  component GroupHeader: Item {
    id: header
    property string groupKey: ""
    property int count: 0
    property bool collapsed: false
    readonly property color tint: groupKey === "overdue" ? root.urgent : Qt.darker(root.foreground, 1.4)

    implicitHeight: headerRow.implicitHeight + Style.space(6)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: headerMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
    }

    MouseArea {
      id: headerMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleGroup(header.groupKey)
    }

    Row {
      id: headerRow
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: header.collapsed ? (Commons.I18n.rightToLeft ? root.glyphChevronLeft : root.glyphChevronRight) : root.glyphChevronDown
        color: header.tint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.tr("group." + header.groupKey)
        color: header.tint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: Commons.I18n.formatNumber(header.count)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Today or the week: accounted (logged + unlogged timer) against the work
  // time elapsed so far, and against the full target.
  component SummaryBlock: Column {
    id: block
    property string heading: ""
    property int logged: 0
    property int timer: 0
    property real elapsedMinutes: 0
    property real fullMinutes: 0
    property string targetKey: ""
    property string emptyText: ""
    readonly property int accounted: logged + timer
    readonly property var soFar: WorkTime.percent(accounted, elapsedMinutes)
    readonly property var ofTarget: WorkTime.percent(accounted, fullMinutes)

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(blockLabel.implicitHeight, blockValue.implicitHeight)

      Text {
        id: blockLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: block.heading
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        id: blockValue
        anchors.right: parent.right
        anchors.left: blockLabel.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
        textFormat: Text.PlainText
        text: block.soFar !== null ? root.tr("summary.percentSoFar").arg(root.pct(block.soFar)) : block.emptyText
        color: block.soFar !== null && block.soFar >= 100 ? root.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // Track = the full target; solid = logged, accent = unlogged timer time;
    // the tick marks the work time elapsed so far.
    Item {
      id: meter
      width: parent.width
      readonly property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      implicitHeight: thickness + Style.space(4)
      readonly property real perSecond: block.fullMinutes > 0 ? 1 / (block.fullMinutes * 60) : 0

      Rectangle {
        id: meterTrack
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: meter.thickness
        radius: height / 2
        color: root.track
      }
      Rectangle {
        id: loggedFill
        anchors.left: meterTrack.left
        anchors.verticalCenter: meterTrack.verticalCenter
        height: meterTrack.height
        radius: meterTrack.radius
        width: meterTrack.width * Math.min(1, block.logged * meter.perSecond)
        color: root.foreground
        Behavior on width { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
      }
      Rectangle {
        anchors.left: loggedFill.right
        anchors.verticalCenter: meterTrack.verticalCenter
        height: meterTrack.height
        radius: meterTrack.radius
        width: Math.max(0, Math.min(meterTrack.width - loggedFill.width, meterTrack.width * block.timer * meter.perSecond))
        color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.7)
      }
      Rectangle {
        visible: block.fullMinutes > 0 && block.elapsedMinutes > 0 && block.elapsedMinutes < block.fullMinutes
        x: Math.round(meterTrack.width * block.elapsedMinutes / Math.max(1, block.fullMinutes)) - width / 2
        anchors.verticalCenter: meterTrack.verticalCenter
        width: Math.max(2, Style.space(2))
        height: meter.height
        color: root.dim
      }
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.tr("summary.detail").arg(root.hm(block.logged)).arg(root.hm(block.timer))
        .arg(root.hm(block.accounted)).arg(root.hmMinutes(block.elapsedMinutes))
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      visible: block.ofTarget !== null
      width: parent.width
      textFormat: Text.PlainText
      text: root.tr(block.targetKey).arg(root.pct(block.ofTarget === null ? 0 : block.ofTarget)).arg(root.hmMinutes(block.fullMinutes))
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // One work day of this week: logged hours as a small bar against the day's
  // target, today's unlogged timer time on top.
  component DayBar: Column {
    id: dayBar
    property int iso: 1
    readonly property var date: {
      var d = WorkTime.weekStart(new Date(root.nowMs))
      d.setDate(d.getDate() + iso - 1)
      return d
    }
    readonly property string dateIso: WorkTime.isoDate(date)
    readonly property bool isToday: dateIso === root.todayWork.date
    readonly property bool future: dateIso > root.todayWork.date
    readonly property int logged: {
      var days = root.snapshot && root.snapshot.week.start === root.weekWork.start ? root.snapshot.week.days : []
      for (var i = 0; i < days.length; i++) if (days[i].date === dateIso) return days[i].loggedSeconds
      return 0
    }
    readonly property int timer: isToday ? root.unlogged : 0
    readonly property real target: WorkTime.dayMinutes(root.workCfg) * 60

    spacing: Style.space(3)

    Item {
      width: parent.width
      height: Style.space(28)

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        width: Math.min(parent.width, Style.space(18))
        height: parent.height
        radius: Style.cornerRadius > 0 ? Style.space(2) : 0
        color: root.track

        Rectangle {
          id: dayLogged
          anchors.bottom: parent.bottom
          width: parent.width
          radius: parent.radius
          height: dayBar.target > 0 ? parent.height * Math.min(1, dayBar.logged / dayBar.target) : 0
          color: dayBar.isToday ? root.foreground : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
        }
        Rectangle {
          anchors.bottom: dayLogged.top
          width: parent.width
          height: dayBar.target > 0 ? Math.min(parent.height - dayLogged.height, parent.height * dayBar.timer / dayBar.target) : 0
          color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.7)
        }
      }

      MouseArea {
        id: dayHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
      }

      PanelToolTip {
        visible: dayHover.containsMouse
        text: root.tr("summary.dayTooltip").arg(dayBar.date.toLocaleDateString(root.locale(), "ddd d MMM")).arg(root.hm(dayBar.logged))
        fontFamily: root.fontFamily
      }
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: dayBar.future ? "" : root.hm(dayBar.logged + dayBar.timer)
      color: dayBar.isToday ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayBar.isToday
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: root.dayShortName(dayBar.iso)
      color: dayBar.isToday ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayBar.isToday
    }
  }
}
