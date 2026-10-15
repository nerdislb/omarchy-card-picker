import QtQuick
import QtQuick.Shapes
import QtMultimedia
import qs.Commons
import qs.Commons as Commons
import "Logic.js" as Logic

// What the picker shows: the card in front at full size behind the hand, the
// fanned hand along the bottom, the switches above it, and the card that grows
// into the screen when it is set. All state lives in the Picker (`picker`);
// this only draws and turns keys into its calls, so tests can place it in a
// window of their own.
FocusScope {
  id: deck

  required property var picker
  readonly property var p: picker

  // Shibumi's Hearthstone proportions.
  readonly property real cardW: Style.space(232)
  readonly property real cardH: Style.space(330)
  readonly property real stepX: Style.space(128)
  readonly property real lift: Style.space(54)
  readonly property real focusScale: 1.24
  readonly property real spreadDegrees: 6
  readonly property int reach: 5
  // the hand, the switches and the hints fade out while the chosen card grows
  readonly property real chrome: Math.max(0, 1 - p.grow * 2.4)

  readonly property var mediaState: ({video: videoLoader.active,
    playing: videoLoader.item ? videoLoader.item.media.playbackState === MediaPlayer.PlayingState : false,
    position: videoLoader.item ? videoLoader.item.media.position : 0,
    source: videoLoader.item ? videoLoader.item.media.source.toString() : "",
    animated: animatedLoader.active})
  focus: true
  opacity: p.closing ? 0 : 1
  Behavior on opacity { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
  Component.onCompleted: { p.deck = deck; forceActiveFocus() }
  Component.onDestruction: if (p.deck === deck) p.deck = null

  // the focused card's rectangle on screen, as drawn (lifted and enlarged): the grow starts there
  function focusedCardRect() {
    var item = cards.itemAt(p.selected)
    if (!item) return [(width - cardW) / 2, height - cardH, cardW, cardH]
    var a = item.mapToItem(deck, 0, 0), b = item.mapToItem(deck, item.width, item.height)
    return [Math.min(a.x, b.x), Math.min(a.y, b.y), Math.abs(b.x - a.x), Math.abs(b.y - a.y)]
  }
  function fileUrl(path) { return path ? "file://" + path.split("/").map(encodeURIComponent).join("/") : "" }

  Keys.onPressed: function(event) {
    var k = event.key, ctrl = event.modifiers & Qt.ControlModifier
    if ((p.growing || p.applying) && k !== Qt.Key_Escape) { event.accepted = true; return }
    if (k === Qt.Key_Escape) { if (p.filter !== "") p.filter = ""; else p.close() }
    else if (k === Qt.Key_Left || k === Qt.Key_Up) p.move(-1)
    else if (k === Qt.Key_Right || k === Qt.Key_Down) p.move(1)
    else if (k === Qt.Key_Home) p.selected = 0
    else if (k === Qt.Key_End) p.selected = Math.max(0, p.shown.length - 1)
    else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) p.activate()
    else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) p.toggleView()
    else if (ctrl && k === Qt.Key_F) p.toggleFavourite()
    else if (ctrl && k === Qt.Key_S) p.cycleSort()
    else if (ctrl && k === Qt.Key_P) p.toggleLive()
    else if (k === Qt.Key_Backspace) { p.filter = p.filter.slice(0, -1); p.syncSelection() }
    else if (event.text && event.text.length === 1 && event.text >= " " && !ctrl) {
      p.filter += event.text
      p.selected = 0
    } else return
    event.accepted = true
  }

  // ------------------------------------------------------------ the desktop dims, the preview fills the screen
  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.55 * p.deal)
  }

  Item {
    id: preview
    anchors.fill: parent
    opacity: p.deal
    // two stills that cross-fade; a new one is loaded once the hand rests for a moment
    property Image front: stillA
    property string want: ""
    Timer { id: settle; interval: 70; onTriggered: preview.want = deck.fileUrl(deck.p.previewPath) }
    Connections {
      target: deck.p
      function onPreviewPathChanged() { if (preview.want === "") preview.want = deck.fileUrl(deck.p.previewPath); else settle.restart() }
    }
    onWantChanged: {
      if (want === "" || front.source.toString() === want) return
      var back = front === stillA ? stillB : stillA
      if (back.source.toString() === want && back.status === Image.Ready) { front = back; return }
      back.source = want
    }
    Component.onCompleted: want = deck.fileUrl(deck.p.previewPath)
    function arrived(img) { if (img !== front && img.source.toString() === want && img.status === Image.Ready) front = img }

    Image {
      id: stillA
      anchors.fill: parent
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize: Qt.size(deck.width, deck.height)
      opacity: preview.front === stillA ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(180) } }
      onStatusChanged: preview.arrived(stillA)
    }
    Image {
      id: stillB
      anchors.fill: parent
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize: Qt.size(deck.width, deck.height)
      opacity: preview.front === stillB ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(180) } }
      onStatusChanged: preview.arrived(stillB)
    }

    // live preview: a moving background plays, an animated GIF/WebP runs (muted, looping)
    readonly property var entry: deck.p.focusedEntry
    readonly property bool liveVideo: !Style.reduceMotion && deck.p.live && deck.p.mode === "wallpaper" && !!entry && entry.video && !deck.p.growing
    readonly property bool liveAnimated: !Style.reduceMotion && deck.p.live && deck.p.mode === "wallpaper" && !!entry && entry.animated && !deck.p.growing
    Loader {
      anchors.fill: parent
      id: videoLoader
      active: preview.liveVideo
      sourceComponent: Item {
        readonly property var media: player
        MediaPlayer {
          id: player
          source: deck.fileUrl(preview.entry ? preview.entry.path : "")
          loops: MediaPlayer.Infinite
          videoOutput: video
          onSourceChanged: if (source.toString() !== "") play()
          Component.onCompleted: play()
          Component.onDestruction: stop()
        }
        VideoOutput {
          id: video
          anchors.fill: parent
          fillMode: VideoOutput.PreserveAspectCrop
          opacity: player.playbackState === MediaPlayer.PlayingState && player.position > 0 ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(240) } }
        }
      }
    }
    Loader {
      anchors.fill: parent
      id: animatedLoader
      active: preview.liveAnimated
      sourceComponent: AnimatedImage {
        source: deck.fileUrl(preview.entry ? preview.entry.path : "")
        fillMode: Image.PreserveAspectCrop
        playing: true
      }
    }
  }

  // shade under the hand and the switches, so they read on any picture
  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: parent.height * 0.62
    opacity: p.deal * deck.chrome
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0) }
      GradientStop { position: 0.45; color: Qt.rgba(0, 0, 0, 0.42) }
      GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.72) }
    }
  }

  // a click outside the hand closes; the wheel moves
  MouseArea {
    anchors.fill: parent
    enabled: !p.growing
    onClicked: p.close()
    onWheel: function(wheel) { p.move(wheel.angleDelta.y > 0 || wheel.angleDelta.x > 0 ? -1 : 1) }
  }

  // ------------------------------------------------------------ title, switches
  Column {
    id: head
    anchors.horizontalCenter: parent.horizontalCenter
    // above the lifted, enlarged focus card
    anchors.bottom: hand.top
    anchors.bottomMargin: deck.lift + deck.cardH * (deck.focusScale - 1) + Style.space(10)
    spacing: Style.space(10)
    opacity: p.deal * deck.chrome

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: (p.mode === "theme" ? "THEME" : "WALLPAPER") + "      "
        + (p.shown.length ? (p.selected + 1) + " / " + p.shown.length : (p.loading ? "…" : "0"))
        + (p.filter ? "      “" + p.filter + "”" : "")
      color: Qt.rgba(0.94, 0.94, 0.96, 0.72)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 2
      textFormat: Text.PlainText
      renderType: Text.NativeRendering
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(8)
      Chip { label: "All"; lit: p.view === "all"; onPicked: if (p.view !== "all") p.toggleView() }
      Chip { label: "♥ Favourites  " + p.favourites.length; lit: p.view === "favourites"; onPicked: if (p.view !== "favourites") p.toggleView() }
      Item { width: Style.space(10); height: 1 }
      Chip { label: "Sort: " + Logic.SORT_LABELS[p.sortBy]; lit: p.sortBy !== "name"; onPicked: p.cycleSort() }
      Chip { visible: p.mode === "wallpaper"; label: "▶ Live preview: " + (p.live ? "on" : "off"); lit: p.live; onPicked: p.toggleLive() }
    }
  }

  component Chip: Rectangle {
    id: chip
    property string label: ""
    property bool lit: false
    signal picked()
    implicitWidth: chipText.implicitWidth + Style.space(24)
    implicitHeight: chipText.implicitHeight + Style.space(10)
    radius: height / 2
    color: lit ? Qt.rgba(1, 1, 1, 0.92) : (chipMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(1, 1, 1, 0.10))
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, lit ? 0 : 0.28)
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.label
      textFormat: Text.PlainText
      color: chip.lit ? "#16181c" : "#eeeef0"
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      renderType: Text.NativeRendering
    }
    MouseArea { id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !deck.p.growing && !deck.p.applying; onClicked: chip.picked() }
  }

  Text {
    visible: !p.loading && p.shown.length === 0
    anchors.centerIn: hand
    opacity: p.deal
    text: p.view === "favourites" && !p.filter ? "No favourites yet · Ctrl+F marks the card in front" : "Nothing matches"
    color: Qt.rgba(0.94, 0.94, 0.96, 0.8)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
  }

  // ------------------------------------------------------------ the hand
  Item {
    id: hand
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: hints.top
    anchors.bottomMargin: Style.space(30)
    height: deck.cardH + deck.lift + Style.space(40)
    opacity: deck.chrome

    Repeater {
      id: cards
      model: deck.p.shown

      delegate: Item {
        id: card
        required property int index
        required property var modelData
        readonly property int relative: index - deck.p.selected
        readonly property bool focused: relative === 0
        readonly property bool nearby: Math.abs(relative) <= deck.reach
        readonly property bool isCurrent: deck.p.mode === "theme"
          ? modelData.name === deck.p.current : modelData.path === deck.p.current
        readonly property bool favourite: deck.p.favourites.indexOf(deck.p.keyOf(modelData)) !== -1
        readonly property real shade: focused ? 0 : Math.min(0.62, 0.30 + Math.abs(relative) * 0.05)
        // the card that grows is drawn by the flyer
        readonly property bool flying: focused && deck.p.growing

        visible: nearby && !flying
        width: deck.cardW
        height: deck.cardH
        transformOrigin: Item.Bottom
        x: (hand.width - width) / 2 + relative * deck.stepX * deck.p.deal
        y: hand.height - height - (focused ? deck.lift * deck.p.deal : 0)
        z: focused ? 1000 : 500 - Math.min(Math.abs(relative), 40)
        rotation: relative * deck.spreadDegrees * deck.p.deal
        scale: focused ? 1 + (deck.focusScale - 1) * deck.p.deal : 1
        opacity: deck.p.deal

        readonly property bool settled: deck.p.deal >= 0.999
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
            source: card.nearby ? deck.fileUrl(card.modelData.thumb) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            sourceSize.width: Math.round(deck.cardW * 2)
            sourceSize.height: Math.round(deck.cardH * 2)
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

        CardFrame { anchors.fill: parent; accent: card.focused }

        // the active theme / wallpaper
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
        // a favourite, and a moving background
        Row {
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(13)
          spacing: Style.space(6)
          z: 5
          Badge { visible: card.modelData.video || card.modelData.animated; glyph: "▶" }
          Badge { visible: card.favourite; glyph: "♥"; tint: "#ff6b7d" }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          enabled: !deck.p.growing && !deck.p.applying
          onClicked: card.focused ? deck.p.activate() : (deck.p.selected = card.index)
        }
      }
    }
  }

  component Badge: Rectangle {
    id: badge
    property string glyph: ""
    property color tint: "#f2f2f4"
    width: Style.space(22)
    height: width
    radius: width / 2
    color: Qt.rgba(0, 0, 0, 0.55)
    Text {
      anchors.centerIn: parent
      text: badge.glyph
      color: badge.tint
      font.pixelSize: Style.space(11)
      textFormat: Text.PlainText
    }
  }

  // Card frame: a rounded mat around the picture; the focused card gets the accent edge.
  component CardFrame: Shape {
    id: frame
    property bool accent: false
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
      strokeColor: frame.accent ? Commons.Color.accent : "transparent"
      strokeWidth: frame.accent ? Style.space(2) : 0
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

  Text {
    id: hints
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(26)
    opacity: p.deal * 0.8 * deck.chrome
    text: "← →  choose     Enter  apply     type  filter     Tab  favourites     Ctrl+F  ♥     Ctrl+S  sort"
      + (p.mode === "wallpaper" ? "     Ctrl+P  live" : "") + "     Esc  close"
    color: Qt.rgba(0.94, 0.94, 0.96, 0.62)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
  }

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: Style.space(36)
    width: parent.width * 0.8
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    text: p.notice || (p.applying ? "Applying…" : "")
    color: "white"
    style: Text.Outline
    styleColor: "#99000000"
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
    z: 4000
  }

  // ------------------------------------------------------------ the card that grows into the screen
  Item {
    id: flyer
    visible: p.growing && !!p.growEntry
    z: 3000
    readonly property var r: Logic.growRect(p.growFrom, [0, 0, deck.width, deck.height], p.grow)
    // the mat and the round corners go as it grows
    readonly property real gone: Math.min(1, Math.max(0, (p.grow - 0.35) / 0.35))
    x: r[0]; y: r[1]; width: r[2]; height: r[3]

    Rectangle {
      anchors.fill: parent
      radius: Style.space(18) * (1 - flyer.gone)
      color: Commons.Color.popups.background
    }
    Item {
      anchors.fill: parent
      anchors.margins: Style.space(8) * (1 - flyer.gone)
      clip: true
      Image {
        anchors.fill: parent
        source: deck.fileUrl(!p.growEntry ? "" : (p.mode === "wallpaper" && p.growEntry.video ? p.growEntry.thumb : p.growEntry.path))
        fillMode: Image.PreserveAspectCrop
        asynchronous: false
        sourceSize: Qt.size(deck.width, deck.height)
      }
      Rectangle { anchors.fill: parent; color: "white"; opacity: Logic.growGlow(p.grow) }
    }
    Rectangle {
      anchors.fill: parent
      color: "transparent"
      radius: Style.space(18) * (1 - flyer.gone)
      border.width: Style.space(2)
      border.color: Commons.Color.accent
      opacity: 1 - flyer.gone
    }
  }
}
