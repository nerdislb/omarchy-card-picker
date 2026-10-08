import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons

// Theme and wallpaper switcher as a fanned hand of cards.
//
// The hand follows Shibumi Shell's "Hearthstone" picker (HANCORE, MIT): the
// cards are dealt out of the centre, fan out a few degrees each, and the
// chosen one rises and grows. The lists, previews and the switch itself are
// Omarchy's own: `omarchy-theme-switcher --print-rows` and
// `omarchy-menu-images --print-rows` (with the video thumbnails Omarchy
// caches), `omarchy-theme-set` and `omarchy-theme-bg-set`.
//
//   ← → / wheel         move      Enter / Space / click   apply
//   type                filter    Esc / click outside     close
// (Every letter goes to the filter: h and l are no move keys, or "chrom"
// would arrive as "crom".)
//
// IPC: omarchy-shell card-picker open|toggle theme|wallpaper, close, state
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/current"

  property bool opened: false
  property string mode: "theme"           // theme | wallpaper
  property var entries: []                // { name, title, path, thumb }
  property string filter: ""
  property int selected: 0
  property string current: ""             // theme name or wallpaper path
  property bool loading: false
  property var targetScreen: null
  property real deal: 0                   // 0 = in the deck, 1 = dealt out

  readonly property var shown: {
    var f = filter.toLowerCase()
    return f === "" ? entries : entries.filter(function(e) { return e.title.toLowerCase().indexOf(f) !== -1 })
  }
  readonly property var focusedEntry: shown.length > 0 ? shown[Math.max(0, Math.min(selected, shown.length - 1))] : null

  // Shibumi's Hearthstone proportions.
  readonly property real cardW: Style.space(232)
  readonly property real cardH: Style.space(330)
  readonly property real stepX: Style.space(128)
  readonly property real lift: Style.space(54)
  readonly property real focusScale: 1.24
  readonly property real spreadDegrees: 6
  readonly property int reach: 5

  Behavior on deal {
    NumberAnimation { duration: Style.duration(root.mode === "theme" ? 260 : 180); easing.type: Easing.OutCubic }
  }

  // ------------------------------------------------------------ lists
  function prettify(name) {
    return String(name || "").replace(/^\d+[-_ ]+/, "").replace(/[-_]+/g, " ")
      .replace(/\b\w/g, function(c) { return c.toUpperCase() })
  }
  function baseName(path) {
    var b = String(path || "").split("/").pop()
    var dot = b.lastIndexOf(".")
    return dot > 0 ? b.substring(0, dot) : b
  }

  function parseRows(text) {
    var out = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var cols = lines[i].split("\t")
      if (cols.length < 2 || !cols[0]) continue
      var name = baseName(cols[0])
      out.push({ name: name, title: prettify(name), path: cols[0], thumb: cols[1] })
    }
    return out
  }

  function syncSelection() {
    for (var i = 0; i < shown.length; i++) {
      var e = shown[i]
      if ((mode === "theme" && e.name === current) || (mode === "wallpaper" && e.path === current)) {
        selected = i
        return
      }
    }
    selected = Math.max(0, Math.min(selected, shown.length - 1))
  }

  Process {
    id: listProc
    property string forMode: ""
    stdout: StdioCollector {
      onStreamFinished: {
        if (listProc.forMode !== root.mode || !root.opened) return
        root.entries = root.parseRows(text)
        root.loading = false
        root.syncSelection()
        root.deal = 1
      }
    }
  }

  Process {
    id: currentProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.current = String(text || "").trim()
        root.syncSelection()
      }
    }
  }

  // ------------------------------------------------------------ open / apply
  function focusedScreen() {
    var screens = Quickshell.screens
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
  }

  function open(nextMode) {
    var m = String(nextMode || "theme")
    if (m !== "theme" && m !== "wallpaper") return false
    deal = 0
    mode = m
    entries = []
    filter = ""
    selected = 0
    current = ""
    loading = true
    targetScreen = focusedScreen()
    opened = true
    listProc.running = false
    listProc.forMode = m
    listProc.command = m === "theme"
      ? ["omarchy-theme-switcher", "--print-rows"]
      : ["sh", "-c", 't=$(cat "$1/theme.name" 2>/dev/null); exec omarchy-menu-images --print-rows "$1/theme/backgrounds" "$HOME/.config/omarchy/backgrounds/$t"', "sh", stateDir]
    listProc.running = true
    currentProc.running = false
    currentProc.command = m === "theme" ? ["cat", stateDir + "/theme.name"] : ["readlink", "-f", stateDir + "/background"]
    currentProc.running = true
    return true
  }

  function close() {
    opened = false
    deal = 0
    listProc.running = false
  }

  function toggle(nextMode) {
    if (opened && mode === String(nextMode || mode)) { close(); return true }
    return open(nextMode)
  }

  function move(delta) {
    if (shown.length === 0) return
    selected = Math.max(0, Math.min(shown.length - 1, selected + delta))
  }

  function activate() {
    var e = focusedEntry
    if (!e) return
    var m = mode
    close()
    if (m === "theme") Quickshell.execDetached(["omarchy-theme-set", e.name])
    else Quickshell.execDetached(["omarchy-theme-bg-set", e.path])
  }

  IpcHandler {
    target: "card-picker"
    function open(mode: string): string { return root.open(mode) ? "ok" : "usage: open theme|wallpaper" }
    function toggle(mode: string): string { return root.toggle(mode) ? "ok" : "usage: toggle theme|wallpaper" }
    function close(): string { root.close(); return "ok" }
    function state(): string {
      return JSON.stringify({ opened: root.opened, mode: root.mode, loading: root.loading, entries: root.entries.length,
        shown: root.shown.length, selected: root.selected, focused: root.focusedEntry ? root.focusedEntry.name : null,
        current: root.current, filter: root.filter, screen: root.targetScreen ? root.targetScreen.name : null })
    }
  }

  // ------------------------------------------------------------ window
  PanelWindow {
    id: win

    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "card-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // Backdrop: dims the desktop; a click outside the hand closes.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.55 * root.deal)
    }
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
      onWheel: function(wheel) { root.move(wheel.angleDelta.y > 0 || wheel.angleDelta.x > 0 ? -1 : 1) }
    }

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true
      Connections {
        target: root
        function onOpenedChanged() { if (root.opened) keys.forceActiveFocus() }
      }
      Keys.onPressed: function(event) {
        var k = event.key
        if (k === Qt.Key_Escape) { if (root.filter !== "") root.filter = ""; else root.close() }
        else if (k === Qt.Key_Left || k === Qt.Key_Up) root.move(-1)
        else if (k === Qt.Key_Right || k === Qt.Key_Down) root.move(1)
        else if (k === Qt.Key_Home) root.selected = 0
        else if (k === Qt.Key_End) root.selected = Math.max(0, root.shown.length - 1)
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) root.activate()
        else if (k === Qt.Key_Backspace) { root.filter = root.filter.slice(0, -1); root.syncSelection() }
        else if (event.text && event.text.length === 1 && event.text >= " " && !(event.modifiers & Qt.ControlModifier)) {
          root.filter += event.text
          root.selected = 0
        } else return
        event.accepted = true
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      // Above the lifted, enlarged focus card.
      anchors.bottom: hand.top
      anchors.bottomMargin: root.lift + root.cardH * (root.focusScale - 1) + Style.space(8)
      opacity: root.deal
      text: (root.mode === "theme" ? "THEME" : "WALLPAPER") + "      "
        + (root.shown.length ? (root.selected + 1) + " / " + root.shown.length : (root.loading ? "…" : "0"))
        + (root.filter ? "      “" + root.filter + "”" : "")
      color: Qt.rgba(0.92, 0.92, 0.94, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 2
      renderType: Text.NativeRendering
    }

    Item {
      id: hand
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -Style.space(16)
      width: parent.width
      height: root.cardH + root.lift + Style.space(40)

      Repeater {
        model: root.shown

        delegate: Item {
          id: card
          required property int index
          required property var modelData
          readonly property int relative: index - root.selected
          readonly property bool focused: relative === 0
          readonly property bool nearby: Math.abs(relative) <= root.reach
          readonly property bool isCurrent: root.mode === "theme"
            ? modelData.name === root.current : modelData.path === root.current
          readonly property real shade: focused ? 0 : Math.min(0.62, 0.30 + Math.abs(relative) * 0.05)

          visible: nearby
          width: root.cardW
          height: root.cardH
          transformOrigin: Item.Bottom
          x: (hand.width - width) / 2 + relative * root.stepX * root.deal
          y: hand.height - height - (focused ? root.lift * root.deal : 0)
          z: focused ? 1000 : 500 - Math.min(Math.abs(relative), 40)
          rotation: relative * root.spreadDegrees * root.deal
          scale: focused ? 1 + (root.focusScale - 1) * root.deal : 1
          opacity: root.deal

          readonly property bool settled: root.deal >= 0.999
          Behavior on x { enabled: card.settled; NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
          Behavior on y { enabled: card.settled; NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
          Behavior on rotation { enabled: card.settled; NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
          Behavior on scale { enabled: card.settled; NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }

          Item {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            clip: true

            Rectangle { anchors.fill: parent; color: Qt.darker(Commons.Color.popups.background, 1.3) }
            Image {
              anchors.fill: parent
              source: card.nearby && card.modelData.thumb ? "file://" + card.modelData.thumb : ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
              sourceSize.width: Math.round(root.cardW * 2)
              sourceSize.height: Math.round(root.cardH * 2)
            }
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Style.space(70)
              gradient: Gradient {
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.72) }
              }
            }
            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(12)
              text: card.modelData.title
              textFormat: Text.PlainText
              color: "#ececee"
              font.family: Style.font.family
              font.pixelSize: Style.space(13)
              font.weight: Font.DemiBold
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              maximumLineCount: 1
            }
            Rectangle {
              anchors.fill: parent
              color: "black"
              opacity: card.shade
              Behavior on opacity { NumberAnimation { duration: Style.duration(180) } }
            }
          }

          // Card frame: a rounded mat around the picture; the focused card
          // gets the accent edge.
          Shape {
            id: frame
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            readonly property real outer: Style.space(18)
            readonly property real mat: Style.space(8)
            readonly property real inner: Style.space(10)
            ShapePath {
              fillRule: ShapePath.OddEvenFill
              fillColor: Commons.Color.popups.background
              strokeColor: "transparent"
              strokeWidth: 0
              startX: frame.outer; startY: 0
              PathLine { x: frame.width - frame.outer; y: 0 }
              PathArc { x: frame.width; y: frame.outer; radiusX: frame.outer; radiusY: frame.outer }
              PathLine { x: frame.width; y: frame.height - frame.outer }
              PathArc { x: frame.width - frame.outer; y: frame.height; radiusX: frame.outer; radiusY: frame.outer }
              PathLine { x: frame.outer; y: frame.height }
              PathArc { x: 0; y: frame.height - frame.outer; radiusX: frame.outer; radiusY: frame.outer }
              PathLine { x: 0; y: frame.outer }
              PathArc { x: frame.outer; y: 0; radiusX: frame.outer; radiusY: frame.outer }
              PathMove { x: frame.mat + frame.inner; y: frame.mat }
              PathLine { x: frame.width - frame.mat - frame.inner; y: frame.mat }
              PathArc { x: frame.width - frame.mat; y: frame.mat + frame.inner; radiusX: frame.inner; radiusY: frame.inner }
              PathLine { x: frame.width - frame.mat; y: frame.height - frame.mat - frame.inner }
              PathArc { x: frame.width - frame.mat - frame.inner; y: frame.height - frame.mat; radiusX: frame.inner; radiusY: frame.inner }
              PathLine { x: frame.mat + frame.inner; y: frame.height - frame.mat }
              PathArc { x: frame.mat; y: frame.height - frame.mat - frame.inner; radiusX: frame.inner; radiusY: frame.inner }
              PathLine { x: frame.mat; y: frame.mat + frame.inner }
              PathArc { x: frame.mat + frame.inner; y: frame.mat; radiusX: frame.inner; radiusY: frame.inner }
            }
            ShapePath {
              fillColor: "transparent"
              strokeColor: card.focused ? Commons.Color.accent : "transparent"
              strokeWidth: card.focused ? Style.space(2) : 0
              startX: frame.outer; startY: 0
              PathLine { x: frame.width - frame.outer; y: 0 }
              PathArc { x: frame.width; y: frame.outer; radiusX: frame.outer; radiusY: frame.outer }
              PathLine { x: frame.width; y: frame.height - frame.outer }
              PathArc { x: frame.width - frame.outer; y: frame.height; radiusX: frame.outer; radiusY: frame.outer }
              PathLine { x: frame.outer; y: frame.height }
              PathArc { x: 0; y: frame.height - frame.outer; radiusX: frame.outer; radiusY: frame.outer }
              PathLine { x: 0; y: frame.outer }
              PathArc { x: frame.outer; y: 0; radiusX: frame.outer; radiusY: frame.outer }
            }
          }

          // The active theme / wallpaper.
          Rectangle {
            visible: card.isCurrent
            width: Style.space(9)
            height: width
            radius: width / 2
            x: Style.space(14)
            y: Style.space(14)
            z: 5
            color: Commons.Color.accent
            border.color: Qt.rgba(0, 0, 0, 0.35)
            border.width: 1
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: card.focused ? root.activate() : (root.selected = card.index)
          }
        }
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: hand.bottom
      anchors.topMargin: Style.space(30)
      opacity: root.deal * 0.8
      text: "← →  choose     Enter  apply     type  filter     Esc  close"
      color: Qt.rgba(0.92, 0.92, 0.94, 0.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      renderType: Text.NativeRendering
    }
  }
}
