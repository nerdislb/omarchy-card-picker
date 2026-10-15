import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons

FloatingWindow {
  id: win
  visible: true
  implicitWidth: __W__; implicitHeight: __H__
  color: "#111419"
  Picker { id: pk; host: "test"; statePath: "__STATE__"; stateDir: "__FIXTURE__/current" }
  Loader { anchors.fill: parent; active: pk.opened; sourceComponent: Deck { picker: pk } }
  FileView { id: result; path: "__FIXTURE__/setter-mode"; atomicWrites: true }
  Timer {
    interval: 700; running: true
    onTriggered: {
      try { test.test_workflow(); console.log("RENDER_DONE native"); Qt.quit() }
      catch (e) { console.error("NATIVE_FAILED " + e); Qt.exit(1) }
    }
  }
  TestCase {
    id: test
    name: "CardPickerNative"
    when: false
    function ready(mode) {
      verify(pk.open(mode))
      tryCompare(pk, "loading", false, 5000)
      tryVerify(function() { return !!pk.deck && pk.entries.length === 5 && pk.themeName === "fixture" }, 5000)
      wait(250)
      pk.deck.forceActiveFocus()
    }
    function choose(name) {
      pk.filter = ""
      for (var i=0; i<pk.shown.length; i++) if (pk.shown[i].name === name) { pk.selected=i; return }
      fail("Missing entry " + name)
    }
    function test_workflow() {
      tryCompare(pk, "stateReady", true)
      ready("wallpaper")
      compare(pk.focusedEntry.name, "1-chrom")
      keyClick(Qt.Key_C); keyClick(Qt.Key_H); keyClick(Qt.Key_R); keyClick(Qt.Key_O); keyClick(Qt.Key_M)
      compare(pk.filter, "chrom")
      compare(pk.shown.length, 1)
      keyClick(Qt.Key_Escape)
      compare(pk.filter, "")
      compare(pk.opened, true)
      choose("2-other")
      var favKey=pk.keyOf(pk.focusedEntry)
      keyClick(Qt.Key_F, Qt.ControlModifier)
      verify(pk.favourites.indexOf(favKey)>=0)
      keyClick(Qt.Key_Tab)
      compare(pk.shown.length, 1)
      keyClick(Qt.Key_Tab)
      compare(pk.shown.length, 5)
      keyClick(Qt.Key_S, Qt.ControlModifier)
      compare(pk.sortBy, "colour")
      compare(pk.keyOf(pk.focusedEntry), favKey)
      keyClick(Qt.Key_S, Qt.ControlModifier)
      compare(pk.sortBy, "newest")
      tryVerify(function(){ return Object.keys(pk.mtimes).length === 5 }, 5000)
      compare(pk.shown[0].name, "5-animation")
      keyClick(Qt.Key_S, Qt.ControlModifier)
      compare(pk.sortBy, "name")
      choose("3-video-a")
      keyClick(Qt.Key_P, Qt.ControlModifier)
      tryVerify(function(){ return pk.deck.mediaState.playing && pk.deck.mediaState.position>0 }, 8000)
      choose("4-video-b")
      tryVerify(function(){ return pk.deck.mediaState.source.indexOf("4-video-b")>=0 && pk.deck.mediaState.playing && pk.deck.mediaState.position>0 }, 8000)
      choose("5-animation")
      tryVerify(function(){ return pk.deck.mediaState.animated && !pk.deck.mediaState.video })
      Style.reduceMotion=true
      tryVerify(function(){ return !pk.deck.mediaState.animated && !pk.deck.mediaState.video })
      Style.reduceMotion=false
      choose("1-chrom")
      tryVerify(function(){ return !pk.deck.mediaState.video && !pk.deck.mediaState.animated })
      // Real process failure keeps the hand usable; no setter is the host setter.
      result.setText("fail")
      wait(150)
      keyClick(Qt.Key_Return)
      tryCompare(pk, "applying", false, 5000)
      verify(pk.opened && !pk.growing)
      verify(pk.notice.indexOf("Could not apply")>=0)
      // Slow successful setter must not be masked by the 700 ms animation.
      result.setText("slow")
      wait(150)
      keyClick(Qt.Key_Return)
      verify(pk.applying)
      verify(pk.growing)
      keyClick(Qt.Key_Right)
      compare(pk.focusedEntry.name, "1-chrom")
      wait(950)
      verify(pk.opened, "must stay open until setter completes")
      tryCompare(pk, "opened", false, 5000)
      // Persisted preferences survive reopening; late jobs cannot overwrite a new mode.
      ready("theme")
      pk.close(); pk.open("wallpaper"); pk.close(); ready("wallpaper")
      verify(pk.favourites.indexOf(favKey)>=0)
      compare(pk.live,true)
      compare(pk.mode,"wallpaper")
      wait(500)
      compare(pk.mode,"wallpaper")
      Style.reduceMotion=true
      result.setText("ok")
      wait(150)
      keyClick(Qt.Key_Return)
      verify(!pk.growing)
      tryCompare(pk,"opened",false,5000)
      Style.reduceMotion=false
      console.log("NATIVE_WORKFLOW_PASSED keyboard favourites sort video-switch animation reduced-motion apply-failure apply-wait reopen")
    }
  }
}
