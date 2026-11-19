import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "WorkTime.js" as WorkTime

// The panel's settings page. Non-secret values are edited as drafts on the
// host (Panel.qml) and written to shell.json by its saveSettings(); the API
// key is handed straight to the helper's stdin and the field is cleared.
Column {
  id: view

  property var host: null

  readonly property color fg: host ? host.foreground : Commons.Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(fg, 1.55)
  readonly property string family: host ? host.fontFamily : Style.font.family
  readonly property var errors: host ? host.draftErrors : ({})
  readonly property var draftDays: host ? WorkTime.parseWorkDays(host.draft.workDays) : []

  function tr(key) { return host ? host.tr(key) : key }
  function timeError(key) {
    var code = errors[key]
    if (!code) return ""
    if (code === "time") return tr("settings.timeInvalid")
    return key === "workEnd" ? tr("settings.endBeforeStart") : tr("settings.lunchOrder")
  }
  function submitKey() {
    if (keyField.text.trim() === "" || host.keyBusy) return
    host.saveKey(keyField.text, function(ok) { if (ok) keyField.text = "" })
    // Nothing keeps the key once it has gone to the helper.
    keyField.text = ""
  }

  spacing: Style.space(12)

  PanelHero {
    width: parent.width
    title: view.tr("settings.title")
    meta: view.tr("settings.meta")
    foreground: view.fg
    fontFamily: view.family
    iconComponent: Component {
      Text {
        textFormat: Text.PlainText
        text: view.host ? view.host.glyphCog : ""
        color: view.fg
        font.family: view.family
        font.pixelSize: Style.font.display
      }
    }
  }

  // ---------------------------------------------------------------- account
  PanelSeparator { foreground: view.fg }
  PanelSectionHeader { text: view.tr("settings.sectionAccount"); foreground: view.fg; fontFamily: view.family }

  Column {
    width: parent.width
    spacing: Style.spacing.md

    FieldLabel { text: view.tr("settings.site") }

    TextField {
      id: siteField
      width: parent.width
      text: view.host ? String(view.host.draft.siteUrl || "") : ""
      placeholderText: "https://yourcompany.teamwork.com"
      foreground: view.fg
      font.family: view.family
      maximumLength: 300
      inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase
      onTextEdited: view.host.setDraft("siteUrl", text)
      Keys.onReturnPressed: view.host.saveSettings()
      Keys.onEscapePressed: view.host.focusPanel()
    }

    ErrorLine { text: view.errors.siteUrl === "site" ? view.tr("settings.siteInvalid") : "" }

    HelpLine {
      visible: view.errors.siteUrl === "empty"
      text: view.tr("settings.siteHelp")
    }
  }

  Column {
    width: parent.width
    spacing: Style.spacing.md

    Item {
      width: parent.width
      implicitHeight: Math.max(keyLabel.implicitHeight, keyState.implicitHeight)

      FieldLabel { id: keyLabel; anchors.left: parent.left; text: view.tr("settings.apiKey") }

      Text {
        id: keyState
        anchors.right: parent.right
        textFormat: Text.PlainText
        text: !view.host || !view.host.hasKey ? view.tr("settings.keyMissing")
          : view.host.keyStorage === "file" ? view.tr("settings.keySavedFile")
          : view.host.keyStorage === "keyring" ? view.tr("settings.keySaved")
          : view.tr("settings.keySavedUnknown")
        color: view.host && view.host.hasKey ? Commons.Color.accent : view.dim
        font.family: view.family
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: keyField
        width: parent.width - saveKeyButton.width - (removeKeyButton.visible ? removeKeyButton.width + parent.spacing : 0) - parent.spacing
        password: true
        placeholderText: view.tr("settings.keyPlaceholder")
        foreground: view.fg
        font.family: view.family
        maximumLength: 200
        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
        enabled: !view.host || !view.host.keyBusy
        Keys.onReturnPressed: view.submitKey()
        Keys.onEnterPressed: view.submitKey()
        Keys.onEscapePressed: { keyField.text = ""; view.host.focusPanel() }
      }

      Button {
        id: saveKeyButton
        anchors.verticalCenter: keyField.verticalCenter
        text: view.tr("settings.keySave")
        foreground: view.fg
        fontFamily: view.family
        fontSize: Style.font.bodySmall
        bordered: true
        enabled: keyField.text.trim() !== "" && !!view.host && !view.host.keyBusy
        opacity: enabled ? 1 : 0.5
        onClicked: view.submitKey()
      }

      Button {
        id: removeKeyButton
        visible: !!view.host && view.host.hasKey
        anchors.verticalCenter: keyField.verticalCenter
        text: view.tr("settings.keyRemove")
        foreground: view.host ? view.host.urgent : Commons.Color.urgent
        fontFamily: view.family
        fontSize: Style.font.bodySmall
        enabled: !!view.host && !view.host.keyBusy
        onClicked: view.host.clearKey()
      }
    }

    Text {
      visible: text !== ""
      width: parent.width
      textFormat: Text.PlainText
      text: view.host ? view.host.keyMessage : ""
      color: view.host && view.host.keyMessageError ? view.host.urgent : view.fg
      font.family: view.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    HelpLine { text: view.tr("settings.keyHelp") }
  }

  // ------------------------------------------------------------------ tasks
  PanelSeparator { foreground: view.fg }
  PanelSectionHeader { text: view.tr("settings.sectionTasks"); foreground: view.fg; fontFamily: view.family }

  Column {
    width: parent.width
    spacing: Style.spacing.md

    FieldLabel { text: view.tr("settings.sortField") }

    TextField {
      id: sortFieldInput
      width: parent.width
      text: view.host ? String(view.host.draft.sortField || "") : ""
      placeholderText: view.tr("settings.sortFieldPlaceholder")
      foreground: view.fg
      font.family: view.family
      maximumLength: 100
      inputMethodHints: Qt.ImhNoPredictiveText
      onTextEdited: view.host.setDraft("sortField", text)
      Keys.onReturnPressed: view.host.saveSettings()
      Keys.onEscapePressed: view.host.focusPanel()
    }

    HelpLine { text: view.tr("settings.sortFieldHelp") }
  }

  // -------------------------------------------------------------- work time
  PanelSeparator { foreground: view.fg }
  PanelSectionHeader { text: view.tr("settings.sectionHours"); foreground: view.fg; fontFamily: view.family }

  Column {
    width: parent.width
    spacing: Style.spacing.md

    FieldLabel { text: view.tr("settings.workDays") }

    Row {
      id: dayRow
      width: parent.width
      spacing: Style.space(4)
      readonly property real cellWidth: (width - spacing * 6) / 7

      Repeater {
        model: [1, 2, 3, 4, 5, 6, 7]

        Button {
          required property int modelData
          width: dayRow.cellWidth
          text: view.host ? view.host.dayShortName(modelData) : ""
          foreground: view.fg
          fontFamily: view.family
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.spacing.sm
          bordered: true
          selected: view.draftDays.indexOf(modelData) !== -1
          onClicked: view.host.toggleDraftDay(modelData)
        }
      }
    }
  }

  TimeRange {
    label: view.tr("settings.workHours")
    startKey: "workStart"
    endKey: "workEnd"
  }

  TimeRange {
    label: view.tr("settings.lunch")
    startKey: "lunchStart"
    endKey: "lunchEnd"
  }

  // -------------------------------------------------------------- reminders
  PanelSeparator { foreground: view.fg }
  PanelSectionHeader { text: view.tr("settings.sectionReminders"); foreground: view.fg; fontFamily: view.family }

  Toggle {
    width: parent.width
    label: view.tr("settings.nag")
    description: view.tr("settings.nagDesc")
    foreground: view.fg
    fontFamily: view.family
    checked: !!view.host && view.host.draft.nagEnabled !== false
    onClicked: view.host.setDraft("nagEnabled", !checked)
  }

  Toggle {
    width: parent.width
    label: view.tr("settings.afterHours")
    description: view.tr("settings.afterHoursDesc")
    foreground: view.fg
    fontFamily: view.family
    checked: !!view.host && view.host.draft.notifyAfterHours !== false
    onClicked: view.host.setDraft("notifyAfterHours", !checked)
  }

  Flow {
    width: parent.width
    spacing: Style.space(12)

    NumberField {
      label: view.tr("settings.nagInterval")
      from: 5
      to: 120
      stepSize: 5
      value: view.host ? Number(view.host.draft.nagIntervalMin) || 15 : 15
      foreground: view.fg
      fontFamily: view.family
      onModified: function(v) { view.host.setDraft("nagIntervalMin", v) }
    }

    NumberField {
      label: view.tr("settings.longTimer")
      from: 0
      to: 24
      stepSize: 1
      value: view.host ? Number(view.host.draft.longTimerWarnHours) || 0 : 3
      foreground: view.fg
      fontFamily: view.family
      onModified: function(v) { view.host.setDraft("longTimerWarnHours", v) }
    }

    NumberField {
      label: view.tr("settings.refresh")
      from: 15
      to: 3600
      stepSize: 15
      value: view.host ? Number(view.host.draft.refreshIntervalSec) || 60 : 60
      foreground: view.fg
      fontFamily: view.family
      onModified: function(v) { view.host.setDraft("refreshIntervalSec", v) }
    }
  }

  // ------------------------------------------------------------------ save
  PanelSeparator { foreground: view.fg }

  Row {
    width: parent.width
    spacing: Style.space(10)

    Button {
      id: saveButton
      text: view.tr("settings.save")
      iconText: view.host ? view.host.glyphCheck : ""
      foreground: view.fg
      fontFamily: view.family
      fontSize: Style.font.bodySmall
      bordered: true
      enabled: !!view.host && view.host.draftValid && view.host.draftDirty
      opacity: enabled ? 1 : 0.5
      onClicked: view.host.saveSettings()
    }

    Text {
      anchors.verticalCenter: saveButton.verticalCenter
      width: parent.width - saveButton.width - parent.spacing
      textFormat: Text.PlainText
      text: view.host ? view.host.settingsMessage : ""
      color: view.host && view.host.settingsMessageError ? view.host.urgent : Commons.Color.accent
      font.family: view.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // ------------------------------------------------------------- components
  component FieldLabel: Text {
    textFormat: Text.PlainText
    color: Qt.darker(view.fg, 1.4)
    font.family: view.family
    font.pixelSize: Style.font.bodySmall
  }

  component HelpLine: Text {
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    color: view.dim
    font.family: view.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  component ErrorLine: Text {
    visible: text !== ""
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    color: view.host ? view.host.urgent : Commons.Color.urgent
    font.family: view.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // A labelled pair of HH:MM fields.
  component TimeRange: Column {
    id: range
    property string label: ""
    property string startKey: ""
    property string endKey: ""

    width: view.width
    spacing: Style.spacing.md

    FieldLabel { text: range.label }

    Row {
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: view.tr("settings.from")
        color: view.dim
        font.family: view.family
        font.pixelSize: Style.font.caption
      }
      TimeField { key: range.startKey }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: view.tr("settings.to")
        color: view.dim
        font.family: view.family
        font.pixelSize: Style.font.caption
      }
      TimeField { key: range.endKey }
    }

    ErrorLine { text: view.timeError(range.startKey) || view.timeError(range.endKey) }
  }

  component TimeField: TextField {
    property string key: ""
    width: Style.space(72)
    horizontalAlignment: TextInput.AlignHCenter
    text: view.host ? String(view.host.draft[key] || "") : ""
    placeholderText: "HH:MM"
    foreground: view.fg
    font.family: view.family
    maximumLength: 5
    inputMethodHints: Qt.ImhPreferNumbers
    validator: RegularExpressionValidator { regularExpression: /^[0-9]{0,2}:?[0-9]{0,2}$/ }
    onTextEdited: view.host.setDraft(key, text)
    Keys.onReturnPressed: view.host.saveSettings()
    Keys.onEscapePressed: view.host.focusPanel()
  }
}
