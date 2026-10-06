import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Zapret control window (Super+Z). All the work is done by ~/.local/bin/zapret-toggle:
// this only reads its state and runs its subcommands.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string cli: Quickshell.env("HOME") + "/.local/bin/zapret-toggle"

  // Russian for ru locales, English for everything else.
  readonly property bool russian: {
    var lang = Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || Qt.locale().name
    return String(lang).toLowerCase().indexOf("ru") === 0
  }

  function tr(ru, en) {
    return root.russian ? ru : en
  }

  property bool opened: false
  property string view: "main"        // main | strategy
  property int selectedIndex: 0
  property bool busy: false
  property string pendingView: ""
  property var zapret: ({ on: false, strategy: "", autostart: false, strategies: [], logo: "" })
  readonly property var rows: root.view === "strategy" ? root.strategyRows() : root.mainRows()

  property string fontFamily: Style.font.menuFamily
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int detailRowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int rowSpacing: Style.spacing.xs
  property int cardWidth: Math.min(Style.space(360), panel.width - Style.gapsOut * 2)

  function mainRows() {
    return [
      { icon: "󰐥", label: root.tr("Включён", "Enabled"), detail: "", checked: root.zapret.on, kind: "run", args: ["toggle"] },
      { icon: "󰑓", label: root.tr("Автозапуск", "Autostart"), detail: "", checked: root.zapret.autostart, kind: "run", args: ["autostart", "toggle"] },
      { icon: "󰒓", label: root.tr("Стратегия", "Strategy"), detail: "", value: root.zapret.strategy, checked: false, kind: "menu", args: [] },
      { icon: "󰄴", label: root.tr("Проверка", "Check"), detail: "", checked: false, kind: "term", args: ["check"] },
      { icon: "󰙨", label: root.tr("Автоподбор", "Autopick"), detail: "", checked: false, kind: "term", args: ["test"] },
      { icon: "󰈙", label: root.tr("Список доменов", "Hostlist"), detail: "", checked: false, kind: "term", args: ["hosts"] }
    ]
  }

  function strategyRows() {
    var list = root.zapret.strategies || []
    var rows = []
    for (var i = 0; i < list.length; i++) {
      rows.push({
        icon: "󰒃",
        label: list[i].name,
        detail: root.tr(list[i].description_ru || list[i].description, list[i].description),
        checked: list[i].name === root.zapret.strategy,
        kind: "strategy",
        args: ["strategy", list[i].name]
      })
    }
    return rows
  }

  // Payload {"view":"strategy"} opens the window straight on the strategy list.
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.view = "main"
    root.selectedIndex = 0
    root.opened = true
    root.pendingView = payload.view || ""
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "gnome627.zapret")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function refresh() {
    if (stateProc.running) return
    stateProc.collected = ""
    stateProc.command = [root.cli, "state"]
    stateProc.running = true
  }

  function select(delta) {
    var count = root.rows.length
    if (count === 0) return
    root.selectedIndex = Math.max(0, Math.min(count - 1, root.selectedIndex + delta))
    rowList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function showStrategies() {
    root.view = "strategy"
    var index = 0
    var list = root.zapret.strategies || []
    for (var i = 0; i < list.length; i++) {
      if (list[i].name === root.zapret.strategy) index = i
    }
    root.selectedIndex = index
    Qt.callLater(function() { rowList.positionViewAtIndex(index, ListView.Center) })
  }

  function goBack() {
    if (root.view === "main") return false
    root.view = "main"
    root.selectedIndex = 2
    return true
  }

  function activate(index) {
    if (root.busy || index < 0 || index >= root.rows.length) return
    var row = root.rows[index]

    if (row.kind === "menu") {
      root.showStrategies()
    } else if (row.kind === "term") {
      Quickshell.execDetached([root.cli, "term"].concat(row.args))
      root.dismiss()
    } else {
      // The window stays open: re-read the state after the command so the
      // check marks show what actually happened.
      root.busy = true
      actionProc.returnToMain = row.kind === "strategy"
      actionProc.command = [root.cli].concat(row.args)
      actionProc.running = true
    }
  }

  Process {
    id: stateProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { stateProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) return
      try { root.zapret = JSON.parse(stateProc.collected) } catch (e) {}
      if (root.pendingView === "strategy") root.showStrategies()
      root.pendingView = ""
    }
  }

  Process {
    id: actionProc
    property bool returnToMain: false
    onExited: function(exitCode, exitStatus) {
      root.busy = false
      if (actionProc.returnToMain) root.goBack()
      root.refresh()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-zapret"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(content.implicitHeight + card.contentTopInset + card.contentBottomInset, panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (!root.goBack()) root.dismiss()
          } else if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Left || event.key === Qt.Key_H) {
            root.goBack()
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.select(-1)
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.select(1)
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right || event.key === Qt.Key_L || event.key === Qt.Key_Space) {
            root.activate(root.selectedIndex)
          } else {
            return
          }
          event.accepted = true
        }
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // Logo: the same text the terminal shows, but drawn as rectangles,
        // because block characters rendered as a font come out with gaps.
        Canvas {
          id: logoText
          readonly property var lines: (root.zapret.logo || "").replace(/\n+$/, "").split("\n")
          readonly property int columns: {
            var widest = 0
            for (var i = 0; i < lines.length; i++) widest = Math.max(widest, lines[i].length)
            return widest
          }
          readonly property int cell: Math.max(2, Math.min(3, Math.floor(content.width / Math.max(1, columns))))
          readonly property color ink: root.selectedText

          anchors.horizontalCenter: parent.horizontalCenter
          visible: columns > 0
          width: columns * cell
          height: Style.space(8) + lines.length * cell * 2 + Style.space(12)
          onLinesChanged: requestPaint()
          onCellChanged: requestPaint()
          onInkChanged: requestPaint()

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.fillStyle = ink
            var top = Style.space(8)
            // All cells go into one path and are filled at once: filled one by
            // one they show seams between them at fractional display scales.
            ctx.beginPath()
            for (var y = 0; y < lines.length; y++) {
              for (var x = 0; x < lines[y].length; x++) {
                var ch = lines[y][x]
                if (ch === "█") ctx.rect(x * cell, top + y * cell * 2, cell, cell * 2)
                else if (ch === "▀") ctx.rect(x * cell, top + y * cell * 2, cell, cell)
                else if (ch === "▄") ctx.rect(x * cell, top + y * cell * 2 + cell, cell, cell)
              }
            }
            ctx.fill()
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          visible: root.view === "strategy"
          text: root.tr("Стратегия…", "Strategy…")
          color: root.foreground
          opacity: 0.58
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideMiddle
        }

        ListView {
          id: rowList
          width: parent.width
          height: Math.min(contentHeight, panel.height - Style.gapsOut * 2 - root.contentMargin * 2 - logoText.height - Style.space(80))
          model: root.rows
          clip: true
          spacing: root.rowSpacing
          boundsBehavior: Flickable.StopAtBounds

          delegate: BorderSurface {
            id: row
            required property int index
            required property var modelData

            readonly property bool hasCursor: row.index === root.selectedIndex

            width: ListView.view.width
            height: row.modelData.detail ? root.detailRowHeight : root.rowHeight
            radius: root.cornerRadius
            color: row.hasCursor ? root.selectedBackground : "transparent"
            borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()
            opacity: root.busy ? 0.6 : 1

            Text {
              id: iconText
              textFormat: Text.PlainText
              text: row.modelData.icon
              color: row.hasCursor ? root.selectedText : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
              width: Style.space(36)
              horizontalAlignment: Text.AlignHCenter
              anchors.left: parent.left
              anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              anchors.left: iconText.right
              anchors.leftMargin: Style.space(6)
              anchors.right: valueText.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: row.modelData.label
                color: row.hasCursor ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: row.modelData.detail ? Style.font.title : Style.font.heading
                font.weight: Font.Medium
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: text.length > 0
                text: row.modelData.detail
                color: root.foreground
                opacity: 0.52
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            // Current value of the row (the selected strategy, for example).
            Text {
              id: valueText
              textFormat: Text.PlainText
              text: row.modelData.value || ""
              color: root.foreground
              opacity: 0.52
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: Math.min(implicitWidth, row.width * 0.55)
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideMiddle
              anchors.right: trail.left
              anchors.rightMargin: text.length > 0 ? Style.space(4) : 0
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: trail
              textFormat: Text.PlainText
              text: row.modelData.checked ? "✓" : (row.modelData.kind === "menu" ? "›" : "")
              color: row.hasCursor ? root.selectedText : root.foreground
              opacity: row.modelData.checked ? 1 : 0.36
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              width: Style.space(18)
              horizontalAlignment: Text.AlignHCenter
              anchors.right: parent.right
              anchors.rightMargin: root.rowReservedBorderRight + Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onPositionChanged: root.selectedIndex = row.index
              onClicked: root.activate(row.index)
            }
          }
        }

      }
    }
  }
}
