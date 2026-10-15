import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "Logic.js" as Logic

// Theme and wallpaper switcher as a fanned hand of cards.
//
// The hand follows Shibumi Shell's "Hearthstone" picker (HANCORE, MIT): the
// cards are dealt out of the centre, fan out a few degrees each, and the
// chosen one rises and grows. The screen behind the hand shows the card in
// front at full size; the card you set comes to the middle and grows into the
// screen (ideas from dhrruvsharma/qs-wallpaperpicker, reimplemented here). The
// lists, previews and the switch itself are Omarchy's own:
// `omarchy-theme-switcher --print-rows` and `omarchy-menu-images --print-rows`
// (with the video thumbnails Omarchy caches), `omarchy-theme-set` and
// `omarchy-theme-bg-set`. Colours for sorting come from ImageMagick (an
// Omarchy base package); nothing recolours the desktop.
//
//   ← → / wheel   move          Enter / Space / click   apply
//   type          filter        Esc / click outside     close
//   Tab           all / favourites      Ctrl+F   favourite
//   Ctrl+S        sort: name, colour, newest
//   Ctrl+P        live preview (moving backgrounds play behind the hand)
// (Every letter goes to the filter: the new keys take Ctrl or Tab, and h and
// l are no move keys, or "chrom" would arrive as "crom".)
//
// IPC: omarchy-shell card-picker open|toggle theme|wallpaper, close, state
Item {
  id: root

  property var shell: null
  property var manifest: null
  // "panel": the overlay window; "test": no window (tests/render.py places a Deck itself)
  property string host: "panel"
  // log the switch instead of running it (tests)
  property bool dryRun: false

  readonly property string home: Quickshell.env("HOME")
  // Omarchy's current theme and background (tests point it at a stand-in)
  property string stateDir: home + "/.local/state/omarchy/current"
  property string statePath: home + "/.local/state/nerdibeard.card-picker/state.json"

  property bool opened: false
  property string mode: "theme"           // theme | wallpaper
  property var entries: []                // Logic.parseRows
  property string filter: ""
  property string view: "all"             // all | favourites
  property int selected: 0
  property string current: ""             // theme name or wallpaper path
  property string themeName: ""
  property bool loading: false
  property var targetScreen: null
  property real deal: 0                   // 0 = in the deck, 1 = dealt out
  property var mtimes: ({})
  property var deck: null                 // the Deck on screen (for the grow's start)

  // saved: sort per mode, live preview, favourites, colour cache
  property var saved: Logic.readState("")
  readonly property string sortBy: saved.sort[mode] || "name"
  readonly property bool live: saved.live
  readonly property var favourites: saved.favourites[mode] || []

  readonly property var shown: Logic.visibleEntries(entries, { mode: mode, theme: themeName, filter: filter, view: view,
    favourites: favourites, sort: sortBy, meta: { colours: saved.colours, mtimes: mtimes } })
  readonly property var focusedEntry: shown.length > 0 ? shown[Math.max(0, Math.min(selected, shown.length - 1))] : null
  readonly property string previewPath: !focusedEntry ? ""
    : (mode === "wallpaper" && focusedEntry.video ? focusedEntry.thumb : focusedEntry.path)

  // the grow on apply
  property bool growing: false
  property real grow: 0
  property var growFrom: [0, 0, 1, 1]
  property var growEntry: null
  property bool closing: false
  property int epoch: 0
  property bool applyDone: false
  property bool applying: false
  property string notice: ""
  property bool stateReady: false
  property bool stateDirty: false
  property bool stateValid: true
  property bool directoryReady: false

  Behavior on deal {
    NumberAnimation { duration: Style.duration(root.mode === "theme" ? 260 : 180); easing.type: Easing.OutCubic }
  }

  // ------------------------------------------------------------ state file
  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      if (root.stateDirty) return
      try { JSON.parse(text() || "{}"); root.stateValid = true }
      catch (e) { root.stateValid = false; root.notice = "Saved preferences could not be read; the file was left unchanged." }
      root.saved = Logic.readState(text())
      root.stateReady = true
    }
    onLoadFailed: { root.stateReady = true }
  }
  Process {
    running: true
    command: ["mkdir", "-p", root.statePath.substring(0, root.statePath.lastIndexOf("/"))]
    onExited: function(code) { root.directoryReady = code === 0; root.flushState() }
  }
  function save(next) {
    if (!stateReady) return
    saved = next
    stateDirty = true
    flushState()
  }
  function flushState() {
    if (stateDirty && directoryReady && stateValid) {
      stateFile.setText(JSON.stringify(saved, null, 1) + "\n")
    }
  }
  function patched(changes) {
    var s = JSON.parse(JSON.stringify(saved))
    changes(s)
    return s
  }

  // ------------------------------------------------------------ lists
  function keyOf(e) { return e ? Logic.favKey(mode, themeName, e) : "" }
  // keep the card in front when the order or the view changes
  function reselect(key) {
    for (var i = 0; i < shown.length; i++) if (keyOf(shown[i]) === key) { selected = i; return }
    selected = Math.max(0, Math.min(selected, shown.length - 1))
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

  // Each request owns its process and epoch. Late results from a closed or
  // reopened picker cannot replace the new hand or its current-theme context.
  Component {
    id: jobFactory
    Process {
      id: job
      property string kind
      property int ticket
      property string output: ""
      stdout: StdioCollector { onStreamFinished: job.output = text }
      stderr: StdioCollector {}
      onExited: function(code, status) {
        root.receive(kind, ticket, output, status === 0 ? code : -1)
        Qt.callLater(function() { job.destroy() })
      }
    }
  }
  function job(kind, argv) {
    var proc = jobFactory.createObject(root, { kind: kind, ticket: epoch, command: argv })
    proc.running = true
  }
  function receive(kind, ticket, text, code) {
    if (kind === "apply") applying = false
    if (ticket !== epoch || !opened) return
    if (kind === "apply") {
      if (code !== 0) {
        stopGrow()
        notice = "Could not apply this selection. Your picker is still open; try again."
      } else {
        applyDone = true
        if (!growing || grow >= 1) fadeOut()
      }
      return
    }
    if (code !== 0) {
      if (kind === "list") { loading = false; deal = 1; notice = "The list could not be loaded. Close and reopen to retry." }
      return
    }
    var lines = String(text || "").split("\n")
    if (kind === "current") {
      themeName = (lines[0] || "").trim()
      current = mode === "theme" ? themeName : (lines[1] || "").trim()
      syncSelection()
    } else if (kind === "list") {
      entries = Logic.parseRows(text)
      loading = false
      syncSelection()
      deal = 1
      measure()
    } else if (kind === "colour") {
      var found = {}
      for (var i = 0; i < lines.length; i++) {
        var tab = lines[i].indexOf("\t")
        if (tab < 1) continue
        var colour = Logic.colourKey(lines[i].substring(tab + 1))
        if (colour) found[lines[i].substring(0, tab)] = colour
      }
      if (Object.keys(found).length === 0) return
      var focusKey = keyOf(focusedEntry)
      save(patched(function(s) { for (var k in found) s.colours[k] = found[k] }))
      reselect(focusKey)
    } else if (kind === "time") {
      var out = {}
      for (var j = 0; j < lines.length; j++) {
        var split = lines[j].indexOf("\t")
        if (split > 0) out[lines[j].substring(split + 1)] = Number(lines[j].substring(0, split)) || 0
      }
      var key = keyOf(focusedEntry)
      mtimes = out
      reselect(key)
    }
  }
  function measure() {
    var missing = []
    for (var i = 0; i < entries.length; i++) {
      var t = entries[i].thumb
      if (t && !saved.colours[t] && missing.indexOf(t) === -1) missing.push(t)
    }
    if (missing.length) {
      job("colour", ["timeout", "30", "sh", "-c",
        'for f in "$@"; do printf "%s\\t" "$f"; timeout 3 magick -limit memory 64MiB -limit map 128MiB "$f" -resize 32x32! -colors 6 -depth 8 -format "%c" histogram:info:- 2>/dev/null | tr "\\n" ";"; printf "\\n"; done',
        "sh"].concat(missing))
    }
    if (mode === "theme") {
      // a theme's age: its folder (your own themes, then Omarchy's)
      job("time", ["timeout", "15", "sh", "-c",
        'for n in "$@"; do d="$HOME/.config/omarchy/themes/$n"; [ -e "$d" ] || d="${OMARCHY_PATH:-$HOME/.local/share/omarchy}/themes/$n"; printf "%s\\t%s\\n" "$(stat -L -c %Y "$d" 2>/dev/null || echo 0)" "$n"; done',
        "sh"].concat(entries.map(function(e) { return e.name })))
    } else {
      job("time", ["timeout", "15", "sh", "-c", 'for f in "$@"; do printf "%s\\t%s\\n" "$(stat -L -c %Y "$f" 2>/dev/null || echo 0)" "$f"; done', "sh"]
        .concat(entries.map(function(e) { return e.path })))
    }
  }

  // ------------------------------------------------------------ open / apply
  function focusedScreen() {
    var screens = Quickshell.screens
    var name = host === "panel" && Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
  }

  function open(nextMode) {
    var m = String(nextMode || "theme")
    if (m !== "theme" && m !== "wallpaper") return false
    if (applying) return false
    epoch++
    stopGrow()
    notice = stateValid ? "" : notice
    closing = false
    deal = 0
    mode = m
    entries = []
    mtimes = ({})
    filter = ""
    view = "all"
    selected = 0
    current = ""
    loading = true
    targetScreen = focusedScreen()
    opened = true
    job("list", m === "theme"
      ? ["omarchy-theme-switcher", "--print-rows"]
      : ["sh", "-c", 't=$(cat "$1/theme.name" 2>/dev/null); exec omarchy-menu-images --print-rows "$1/theme/backgrounds" "$HOME/.config/omarchy/backgrounds/$t"', "sh", stateDir])
    // theme.name ends in a newline: printf keeps exactly one line each
    job("current", ["sh", "-c", 'printf "%s\\n%s\\n" "$(cat "$1/theme.name" 2>/dev/null)" "$(readlink -f "$1/background")"', "sh", stateDir])
    return true
  }

  function close() {
    stopGrow()
    closing = false
    opened = false
    deal = 0
    epoch++
  }

  function toggle(nextMode) {
    if (opened && mode === String(nextMode || mode)) { close(); return true }
    return open(nextMode)
  }

  function move(delta) {
    if (shown.length === 0 || growing || applying) return
    selected = Math.max(0, Math.min(shown.length - 1, selected + delta))
  }

  function toggleFavourite() {
    var e = focusedEntry
    if (!e || growing || applying || !themeName) return
    var key = keyOf(e), m = mode
    save(patched(function(s) { s.favourites[m] = Logic.toggled(s.favourites[m], key) }))
    if (view === "favourites") selected = Math.max(0, Math.min(selected, shown.length - 1))
  }
  function cycleSort() {
    if (growing || applying) return
    var key = keyOf(focusedEntry), m = mode, next = Logic.nextSort(sortBy)
    save(patched(function(s) { s.sort[m] = next }))
    reselect(key)
  }
  function toggleView() {
    if (growing || applying) return
    var key = keyOf(focusedEntry)
    view = view === "all" ? "favourites" : "all"
    reselect(key)
  }
  function toggleLive() {
    if (growing || applying) return
    save(patched(function(s) { s.live = !s.live }))
  }

  function activate() {
    var e = focusedEntry
    if (!e || growing || applying) return
    notice = ""
    var argv = mode === "theme" ? ["omarchy-theme-set", e.name] : ["omarchy-theme-bg-set", e.path]
    applyDone = dryRun
    if (dryRun) console.log("CARD_PICKER_WOULD_RUN " + JSON.stringify(argv))
    else {
      applying = true
      job("apply", argv)
    }
    if (Style.reduceMotion || !deck) { if (applyDone) close(); return }
    growEntry = e
    growFrom = deck.focusedCardRect()
    growing = true
    grow = 0
    growAnim.restart()
  }

  // Finish only when both the animation and Omarchy's setter have completed.
  // A failed setter restores the hand and exposes an actionable error.
  NumberAnimation {
    id: growAnim
    target: root
    property: "grow"
    from: 0; to: 1
    duration: Style.duration(700)
    easing.type: Easing.Linear
    onFinished: if (root.applyDone) root.fadeOut()
  }
  function fadeOut() {
    if (!opened || closing) return
    closing = true
    closeTimer.restart()
  }
  Timer { id: closeTimer; interval: 220; onTriggered: root.close() }
  function stopGrow() {
    growAnim.stop()
    closeTimer.stop()
    growing = false
    grow = 0
    growEntry = null
  }

  IpcHandler {
    target: "card-picker"
    function open(mode: string): string { return root.open(mode) ? "ok" : "usage: open theme|wallpaper" }
    function toggle(mode: string): string { return root.toggle(mode) ? "ok" : "usage: toggle theme|wallpaper" }
    function close(): string { root.close(); return "ok" }
    function state(): string {
      return JSON.stringify({ opened: root.opened, mode: root.mode, loading: root.loading, entries: root.entries.length,
        shown: root.shown.length, selected: root.selected, focused: root.focusedEntry ? root.focusedEntry.name : null,
        current: root.current, theme: root.themeName, filter: root.filter, view: root.view, sort: root.sortBy, live: root.live,
        favourites: root.favourites.length, coloured: Object.keys(root.saved.colours).length, growing: root.growing, applying: root.applying, notice: root.notice, revision: "preview-deck-v2",
        screen: root.targetScreen ? root.targetScreen.name : null })
    }
  }

  // ------------------------------------------------------------ window
  LazyLoader {
    active: root.host === "panel" && root.opened
    component: PanelWindow {
      screen: root.targetScreen
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "card-picker"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

      Deck { anchors.fill: parent; picker: root }
    }
  }
}
