import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One task in the panel's list: name, project, task list and due date, time accounted
// today and this week, a paused/running mark, and buttons to log time by hand
// or switch the timer to it. `host` is the Panel.
Item {
  id: row

  property var host: null
  property var task: null
  // The due group the row sits in (Model.GROUPS), which decides how much of
  // the due date is worth repeating.
  property string group: ""

  readonly property var due: host && task ? host.dueLabel(task.dueDate, group) : ({ text: "", late: false })

  readonly property var timer: host && task ? Model.timerForTask(task, host.timers) : null
  readonly property bool timing: !!timer && timer.running
  readonly property bool pausedTimer: !!timer && !timer.running
  readonly property int timerSeconds: timer ? Model.liveSeconds(timer, host.fetchedMs, host.nowMs) : 0
  // Tracked figures are logged time only; a timer's time counts on top.
  readonly property int todaySeconds: (task ? task.trackedTodaySeconds : 0) + timerSeconds
  readonly property int weekSeconds: (task ? task.trackedWeekSeconds : 0) + timerSeconds
  readonly property bool formOpen: !!host && !!task && host.logTaskId === task.id
  readonly property color fg: host ? host.foreground : Commons.Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(fg, 1.55)

  implicitHeight: content.implicitHeight + Style.space(8)

  function submitLog() {
    var ok = row.host.logTime(row.task.id, minutesField.text, descriptionField.text)
    formError.visible = !ok
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: row.timing ? Style.selectedFillFor(row.fg, Commons.Color.accent)
      : (hover.hovered || row.formOpen ? Style.hoverFillFor(row.fg, Commons.Color.accent) : "transparent")
  }

  HoverHandler { id: hover }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: Style.space(4)
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(2)
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(labels.implicitHeight, buttons.implicitHeight)

      Column {
        id: labels
        anchors.left: parent.left
        anchors.right: buttons.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Row {
          width: parent.width
          spacing: Style.space(4)

          Text {
            id: stateGlyph
            visible: row.timing || row.pausedTimer
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: row.timing ? row.host.glyphPlay : row.host.glyphPause
            color: row.timing ? Commons.Color.accent : row.dim
            font.family: row.host ? row.host.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall

            MouseArea {
              id: stateHover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
            }
            PanelToolTip {
              visible: stateHover.containsMouse
              text: row.timing ? row.host.tr("tasks.running") : row.host.tr("tasks.paused")
              fontFamily: row.host ? row.host.fontFamily : Style.font.family
            }
          }

          // The value of the task custom field named in the sortField setting
          // ("1st"), as a small pill; its tooltip names the field.
          Rectangle {
            id: priorityBadge
            visible: !!row.task && row.task.priorityOrder !== ""
            anchors.verticalCenter: parent.verticalCenter
            width: visible ? Math.min(priorityText.implicitWidth, Style.space(80)) + Style.space(8) : 0
            height: priorityText.implicitHeight + Style.space(1)
            radius: height / 2
            color: Style.selectedFillFor(row.fg, Commons.Color.accent)

            Text {
              id: priorityText
              anchors.centerIn: parent
              width: Math.min(implicitWidth, Style.space(80))
              textFormat: Text.PlainText
              text: row.task ? row.task.priorityOrder : ""
              color: Commons.Color.accent
              font.family: row.host ? row.host.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            MouseArea {
              id: priorityHover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
            }
            PanelToolTip {
              visible: priorityHover.containsMouse
              text: row.host ? (row.host.sortField || row.host.tr("tasks.priorityOrder")) : ""
              fontFamily: row.host ? row.host.fontFamily : Style.font.family
            }
          }

          Text {
            width: parent.width - (stateGlyph.visible ? stateGlyph.implicitWidth + parent.spacing : 0)
              - (priorityBadge.visible ? priorityBadge.width + parent.spacing : 0)
            textFormat: Text.PlainText
            text: row.task ? (row.task.name || ("#" + row.task.id)) : ""
            color: row.fg
            font.family: row.host ? row.host.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(metaText.implicitHeight, trackedText.implicitHeight)

          readonly property real available: width - (trackedText.text !== "" ? trackedText.implicitWidth + Style.space(8) : 0)

          Text {
            id: metaText
            anchors.left: parent.left
            width: Math.max(0, Math.min(implicitWidth, parent.available - dueLabel.width))
            textFormat: Text.PlainText
            text: {
              if (!row.task) return ""
              var parts = []
              if (row.task.projectName) parts.push(row.task.projectName)
              if (row.task.tasklistName) parts.push(row.task.tasklistName)
              var s = parts.join(" · ")
              return s !== "" && row.due.text !== "" ? s + " · " : s
            }
            color: row.dim
            font.family: row.host ? row.host.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // Due date, as compact as the group allows ("3 days late", "Fri").
          Text {
            id: dueLabel
            anchors.left: metaText.right
            width: Math.min(implicitWidth, parent.available)
            textFormat: Text.PlainText
            text: row.due.text
            color: row.due.late ? (row.host ? row.host.urgent : Commons.Color.urgent) : row.dim
            font.family: row.host ? row.host.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: trackedText
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: row.todaySeconds > 0 || row.weekSeconds > 0
              ? row.host.tr("tasks.tracked").arg(row.host.hm(row.todaySeconds)).arg(row.host.hm(row.weekSeconds))
              : ""
            color: row.timing ? Commons.Color.accent : row.dim
            font.family: row.host ? row.host.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Row {
        id: buttons
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          iconText: row.host ? row.host.glyphOpen : ""
          tooltipText: row.host ? row.host.tr("action.openBrowser") : ""
          foreground: row.dim
          hoverColor: row.fg
          fontFamily: row.host ? row.host.fontFamily : Style.font.family
          onClicked: row.host.openTask(row.task.id)
        }

        PanelActionButton {
          iconText: row.host ? row.host.glyphLog : ""
          tooltipText: row.host ? row.host.tr("action.logManual") : ""
          foreground: row.formOpen ? Commons.Color.accent : row.dim
          hoverColor: row.fg
          fontFamily: row.host ? row.host.fontFamily : Style.font.family
          onClicked: row.host.logTaskId = row.formOpen ? 0 : row.task.id
        }

        PanelActionButton {
          iconText: row.timing ? row.host.glyphPause : row.host.glyphPlay
          tooltipText: row.timing ? row.host.tr("action.pauseTask") : row.host.tr("action.switchTo")
          foreground: row.timing ? Commons.Color.accent : row.fg
          hoverColor: row.timing ? Commons.Color.accent : row.fg
          fontFamily: row.host ? row.host.fontFamily : Style.font.family
          enabled: row.host && row.host.busy === 0
          onClicked: {
            if (row.timing) row.host.pauseTimer(row.timer.id)
            else row.host.startTask(row.task.id, row.task.name)
          }
        }
      }
    }

    // Log time manually: minutes and an optional description.
    Column {
      visible: row.formOpen
      width: parent.width - Style.space(4)
      spacing: Style.space(6)
      bottomPadding: Style.space(4)

      onVisibleChanged: if (visible) {
        minutesField.text = ""
        descriptionField.text = ""
        formError.visible = false
        Qt.callLater(function() { minutesField.forceActiveFocus() })
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: minutesField
          width: Style.space(80)
          placeholderText: row.host ? row.host.tr("log.minutes") : ""
          foreground: row.fg
          font.family: row.host ? row.host.fontFamily : Style.font.family
          inputMethodHints: Qt.ImhDigitsOnly
          maximumLength: 4
          validator: IntValidator { bottom: 0; top: 1440 }
          Keys.onReturnPressed: row.submitLog()
          Keys.onEnterPressed: row.submitLog()
          Keys.onEscapePressed: { row.host.logTaskId = 0; row.host.focusPanel() }
        }

        TextField {
          id: descriptionField
          width: parent.width - minutesField.width - parent.spacing
          placeholderText: row.host ? row.host.tr("log.description") : ""
          foreground: row.fg
          font.family: row.host ? row.host.fontFamily : Style.font.family
          maximumLength: 1000
          Keys.onReturnPressed: row.submitLog()
          Keys.onEnterPressed: row.submitLog()
          Keys.onEscapePressed: { row.host.logTaskId = 0; row.host.focusPanel() }
        }
      }

      Text {
        id: formError
        visible: false
        width: parent.width
        textFormat: Text.PlainText
        text: row.host ? row.host.tr("log.invalidMinutes") : ""
        color: row.host ? row.host.urgent : Commons.Color.urgent
        font.family: row.host ? row.host.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }

      Row {
        anchors.right: parent.right
        spacing: Style.space(6)

        Button {
          text: row.host ? row.host.tr("action.cancel") : ""
          foreground: row.fg
          fontFamily: row.host ? row.host.fontFamily : Style.font.family
          fontSize: Style.font.bodySmall
          onClicked: { row.host.logTaskId = 0; row.host.focusPanel() }
        }
        Button {
          text: row.host ? row.host.tr("action.confirmLog") : ""
          iconText: row.host ? row.host.glyphCheck : ""
          foreground: row.fg
          fontFamily: row.host ? row.host.fontFamily : Style.font.family
          fontSize: Style.font.bodySmall
          bordered: true
          enabled: row.host && row.host.busy === 0
          opacity: enabled ? 1 : 0.5
          onClicked: row.submitLog()
        }
      }
    }
  }
}
