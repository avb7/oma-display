import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Display Arrange — drag monitors into place, pick mode / scale / rotation,
// then Apply. Apply writes a managed block into ~/.config/hypr/monitors.lua
// (via bin/display-arrange) and reloads Hyprland, then asks you to keep the
// layout; if you don't confirm within 15 s it reverts automatically.
Panel {
  id: root
  moduleName: "avb7.display-arrange"
  ipcTarget: "avb7.display-arrange"

  readonly property string script: decodeURIComponent(String(Qt.resolvedUrl("bin/display-arrange")).replace(/^(file|qs):\/\//, ""))
  readonly property int confirmSeconds: 15

  property var live: []        // what Hyprland reports
  property var draft: []       // what the user is editing
  property int selected: 0
  property string busyText: ""
  property string errorText: ""
  property int countdown: 0     // > 0 while waiting for "Keep"

  readonly property bool dirty: !Model.sameLayout(live, draft)
  readonly property var sel: draft.length > selected ? draft[selected] : null
  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string ff: root.bar ? root.bar.fontFamily : Style.font.family

  function refresh() { if (!stateProc.running) stateProc.running = true }

  function setDraft(list) {
    root.draft = list
    if (root.selected >= list.length) root.selected = Math.max(0, list.length - 1)
  }

  function update(idx, patch, reseat) {
    var list = Model.clone(root.draft)
    for (var k in patch) list[idx][k] = patch[k]
    if (patch.mode !== undefined) list[idx].scale = Model.cleanScale(list[idx].scale, list[idx].mode)
    setDraft(reseat ? Model.reseat(list, idx) : Model.normalize(list))
  }

  function setEnabled(idx, on) {
    if (!on && Model.enabled(root.draft).length <= 1) {
      root.errorText = "At least one display must stay on"
      return
    }
    root.errorText = ""
    var list = Model.clone(root.draft)
    list[idx].disabled = !on
    setDraft(Model.tidy(list))
  }

  // Keyboard: arrows dock the selected display to that side of the rest.
  function nudge(dx, dy) {
    if (!root.sel || root.sel.disabled) return
    var b = Model.bounds(root.draft)
    var s = Model.logicalSize(root.sel)
    var x = dx < 0 ? b.x - s.w * 2 : dx > 0 ? b.x + b.w + s.w : root.sel.x
    var y = dy < 0 ? b.y - s.h * 2 : dy > 0 ? b.y + b.h + s.h : root.sel.y
    setDraft(Model.moveTo(root.draft, root.selected, x, y))
  }

  function run(args, label) {
    root.busyText = label
    root.errorText = ""
    actionProc.command = [root.script].concat(args)
    actionProc.running = true
  }

  function apply() {
    if (!root.dirty || actionProc.running) return
    actionProc.after = "confirm"
    run(["apply", Model.payload(root.draft)], "Applying…")
  }

  function keep() {
    confirmTimer.stop()
    root.countdown = 0
  }

  function revert() {
    confirmTimer.stop()
    root.countdown = 0
    actionProc.after = ""
    run(["revert"], "Reverting…")
  }

  function reset() { setDraft(Model.clone(root.live)); root.errorText = "" }

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened && root.countdown === 0) refresh()

  IpcHandler {
    target: "avb7.display-arrange-cli"
    function state(): string { return JSON.stringify({ live: Model.payload(root.live), draft: Model.payload(root.draft), dirty: root.dirty }) }
    function keep(): void { root.keep() }
    function revert(): void { root.revert() }
  }

  Process {
    id: stateProc
    command: [root.script, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var wasClean = !root.dirty
        root.live = Model.fromHyprctl(text)
        if (wasClean || root.draft.length !== root.live.length) root.setDraft(Model.clone(root.live))
      }
    }
  }

  // Monitors hot-plugged while the panel is open.
  Connections {
    target: Quickshell
    function onScreensChanged() { root.refresh() }
  }

  Process {
    id: actionProc
    property string after: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    onExited: function(code) {
      root.busyText = ""
      if (code !== 0) {
        root.errorText = String(actionErr.text || "Failed").trim().split("\n").pop()
        after = ""
      } else if (after === "confirm") {
        root.countdown = root.confirmSeconds
        confirmTimer.start()
      }
      after = ""
      root.live = []
      root.refresh()
    }
  }

  Timer {
    id: confirmTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.countdown -= 1
      if (root.countdown <= 0) root.revert()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍺"
    onPressed: function(b) { root.toggle() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.nudge(dx, dy) }
      onActivateRequested: root.countdown > 0 ? root.keep() : root.apply()
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        if (root.draft.length) root.selected = (root.selected + direction + root.draft.length) % root.draft.length
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Arrange Displays"
          meta: root.countdown > 0 ? "KEEP THIS LAYOUT?"
            : root.dirty ? "UNSAVED CHANGES"
            : Model.enabled(root.live).length + " ACTIVE"
          foreground: root.fg
          fontFamily: root.ff
          iconComponent: Component {
            Text { text: "󰍺"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.display }
          }
        }

        // ---------- Arrangement canvas ----------
        Rectangle {
          id: canvas
          width: parent.width
          height: Style.space(190)
          color: Style.hoverFillFor(root.fg, Commons.Color.accent)
          radius: Style.cornerRadius
          clip: true

          readonly property var box: Model.bounds(root.draft)
          readonly property real pad: Style.space(16)
          readonly property real k: Math.min((width - pad * 2) / Math.max(1, box.w * 1.6),
                                             (height - pad * 2) / Math.max(1, box.h * 1.6))
          readonly property real ox: (width - box.w * k) / 2 - box.x * k
          readonly property real oy: (height - box.h * k) / 2 - box.y * k

          Repeater {
            model: root.draft

            Rectangle {
              id: tile
              required property var modelData
              required property int index
              readonly property var size: Model.logicalSize(modelData)
              readonly property bool isSel: root.selected === index

              // Drag is tracked as an offset from the bound position, so the
              // binding never breaks and the drop point is always known.
              property real dx: 0
              property real dy: 0
              readonly property real baseX: canvas.ox + modelData.x * canvas.k
              readonly property real baseY: canvas.oy + modelData.y * canvas.k

              visible: !modelData.disabled
              x: baseX + dx
              y: baseY + dy
              width: Math.max(8, size.w * canvas.k)
              height: Math.max(8, size.h * canvas.k)
              radius: Math.max(2, Style.cornerRadius)
              color: isSel ? Style.selectedFillFor(root.fg, Commons.Color.accent) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
              border.width: isSel ? 2 : 1
              border.color: isSel ? Commons.Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.45)
              z: drag.active ? 10 : isSel ? 2 : 1

              Behavior on x { enabled: !drag.active; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
              Behavior on y { enabled: !drag.active; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

              Column {
                anchors.centerIn: parent
                width: parent.width - 6
                spacing: 1
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: tile.modelData.internal ? "󰌢" : "󰍹"
                  color: root.fg; font.family: root.ff; font.pixelSize: Style.font.title
                  visible: tile.height > 46
                }
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: tile.modelData.name
                  color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption; font.bold: true
                }
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: tile.size.w + "×" + tile.size.h
                  color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                  visible: tile.height > 34
                }
              }

              MouseArea {
                id: drag
                property bool active: false
                property real startX: 0
                property real startY: 0
                anchors.fill: parent
                preventStealing: true
                cursorShape: active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                onPressed: function(mouse) {
                  root.selected = tile.index
                  var p = mapToItem(canvas, mouse.x, mouse.y)
                  startX = p.x; startY = p.y
                  active = false
                }
                onPositionChanged: function(mouse) {
                  var p = mapToItem(canvas, mouse.x, mouse.y)
                  var ddx = p.x - startX, ddy = p.y - startY
                  if (!active && Math.abs(ddx) + Math.abs(ddy) < 4) return
                  active = true
                  tile.dx = ddx; tile.dy = ddy
                }
                onReleased: {
                  var wasDrag = active
                  var lx = (tile.x - canvas.ox) / canvas.k
                  var ly = (tile.y - canvas.oy) / canvas.k
                  // Re-enable the x/y Behavior first so the tile glides from
                  // the drop point into its snapped slot.
                  active = false
                  tile.dx = 0; tile.dy = 0
                  if (wasDrag) root.setDraft(Model.moveTo(root.draft, tile.index, lx, ly))
                }
                onCanceled: { active = false; tile.dx = 0; tile.dy = 0 }
              }
            }
          }

          Text {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(6)
            text: "drag to arrange · ←↑↓→ dock · tab select"
            color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          }
        }

        // ---------- Display picker (also reaches disabled displays) ----------
        Flow {
          width: parent.width
          spacing: Style.spacing.xs
          Repeater {
            model: root.draft
            Button {
              required property var modelData
              required property int index
              text: modelData.name + (modelData.disabled ? " (off)" : "")
              fontFamily: root.ff
              fontSize: Style.font.caption
              foreground: root.fg
              bordered: true
              active: root.selected === index
              onClicked: root.selected = index
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---------- Selected display settings ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.sel !== null

          Item {
            width: parent.width
            implicitHeight: Math.max(selLabel.implicitHeight, enableSwitch.implicitHeight)

            Column {
              id: selLabel
              anchors.left: parent.left
              anchors.right: enableSwitch.left
              anchors.verticalCenter: parent.verticalCenter
              Text {
                width: parent.width; elide: Text.ElideRight; textFormat: Text.PlainText
                text: root.sel ? root.sel.label : ""
                color: root.fg; font.family: root.ff; font.pixelSize: Style.font.subtitle; font.bold: true
              }
              Text {
                width: parent.width; elide: Text.ElideRight; textFormat: Text.PlainText
                text: root.sel ? root.sel.name + " · " + root.sel.x + "," + root.sel.y : ""
                color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
              }
            }

            ToggleSwitch {
              id: enableSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.fg
              checked: root.sel ? !root.sel.disabled : false
              onToggled: root.setEnabled(root.selected, !checked)
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.sel !== null && !root.sel.disabled

            Dropdown {
              width: parent.width
              label: "Resolution & refresh"
              fontFamily: root.ff
              foreground: root.fg
              options: root.sel ? root.sel.modes.map(function(m) { return { value: m, label: m.replace("@", "  @ ") + " Hz" } }) : []
              value: root.sel ? root.sel.mode : ""
              onChanged: function(v) { root.update(root.selected, { mode: v }, true) }
            }

            PanelSectionHeader { text: "SCALE"; foreground: root.fg; fontFamily: root.ff }
            Grid {
              id: scaleGrid
              width: parent.width
              readonly property var opts: root.sel ? Model.scaleOptions(root.sel.mode) : []
              columns: Math.max(1, opts.length)
              spacing: Style.spacing.xs
              Repeater {
                model: scaleGrid.opts
                Button {
                  required property var modelData
                  width: (scaleGrid.width - scaleGrid.spacing * (scaleGrid.columns - 1)) / scaleGrid.columns
                  text: modelData + "x"
                  fontFamily: root.ff; fontSize: Style.font.caption; foreground: root.fg; bordered: true
                  active: root.sel && Math.abs(root.sel.scale - modelData) < 0.001
                  onClicked: root.update(root.selected, { scale: modelData }, true)
                }
              }
            }

            PanelSectionHeader { text: "ROTATION"; foreground: root.fg; fontFamily: root.ff }
            Grid {
              id: rotGrid
              width: parent.width
              columns: 4
              spacing: Style.spacing.xs
              Repeater {
                model: Model.rotations
                Button {
                  required property var modelData
                  width: (rotGrid.width - rotGrid.spacing * 3) / 4
                  text: modelData.label
                  fontFamily: root.ff; fontSize: Style.font.caption; foreground: root.fg; bordered: true
                  active: root.sel && root.sel.transform === modelData.transform
                  onClicked: root.update(root.selected, { transform: modelData.transform }, true)
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        Text {
          width: parent.width
          visible: text !== ""
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.errorText !== "" ? root.errorText
            : root.busyText !== "" ? root.busyText
            : root.countdown > 0 ? "Reverting in " + root.countdown + "s unless you keep it."
            : ""
          color: root.errorText !== "" ? Commons.Color.urgent : root.dim
          font.family: root.ff; font.pixelSize: Style.font.caption; font.bold: true
        }

        // ---------- Actions ----------
        Row {
          id: actions
          width: parent.width
          spacing: Style.spacing.xs
          readonly property real cell: (width - spacing) / 2

          Button {
            width: actions.cell
            visible: root.countdown === 0
            text: "Reset"
            fontFamily: root.ff; foreground: root.fg; bordered: true
            enabled: root.dirty && root.busyText === ""
            opacity: enabled ? 1 : 0.45
            onClicked: root.reset()
          }
          Button {
            width: actions.cell
            visible: root.countdown === 0
            text: "Apply"
            fontFamily: root.ff; foreground: root.fg; bordered: true
            active: root.dirty
            enabled: root.dirty && root.busyText === ""
            opacity: enabled ? 1 : 0.45
            onClicked: root.apply()
          }
          Button {
            width: actions.cell
            visible: root.countdown > 0
            text: "Revert (" + root.countdown + ")"
            fontFamily: root.ff; foreground: root.fg; bordered: true
            onClicked: root.revert()
          }
          Button {
            width: actions.cell
            visible: root.countdown > 0
            text: "Keep"
            fontFamily: root.ff; foreground: root.fg; bordered: true
            active: true
            onClicked: root.keep()
          }
        }
      }
    }
  }
}
