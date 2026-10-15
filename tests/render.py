#!/usr/bin/env python3
"""Native render of the picker (Deck + Picker), without touching the desktop.

Runs the production Picker.qml (host "test": no layer-shell window, dryRun: nothing is switched) and
Deck.qml in a plain window on a private Xvfb display, with Omarchy's real lists (read-only: the theme
switcher's and the menu image rows, the current theme and background) and stubbed palette/style
tokens. A scripted session (open, move, sort, favourite, the favourites view, live preview, apply with
the grow) saves stills and, with --video, records the display with ffmpeg. The state file lives in the
output folder, never in ~/.local/state.

    python3 tests/render.py --output DIR [--video] [--size 1920x1080]
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SHELL = r'''import QtQuick
import Quickshell
import qs.Commons

FloatingWindow {
  id: win
  visible: true
  implicitWidth: __W__; implicitHeight: __H__
  color: "#000000"
  property int shots: 0

  Item {
    id: canvas
    anchors.fill: parent
    // the desktop under the overlay: a stand-in (the real one is never captured)
    Image { anchors.fill: parent; source: "file://__DESK__"; fillMode: Image.PreserveAspectCrop }
    Loader {
      anchors.fill: parent
      active: pk.opened
      sourceComponent: Deck { picker: pk }
    }
  }
  Picker { id: pk; host: "test"; dryRun: true; statePath: "__STATE__"__STATEDIR__ }
  readonly property var picker: pk

  Timer { id: later; property var action; onTriggered: action() }
  function after(ms, fn) { later.interval = ms; later.action = fn; later.restart() }
  function shot(name, fn) {
    canvas.grabToImage(function(r) {
      if (!r.saveToFile("__OUT__/" + name + ".png")) { console.error("FAIL save " + name); Qt.exit(1); return }
      shots++; console.log("SHOT " + name + " " + JSON.stringify({ mode: picker.mode, shown: picker.shown.length, selected: picker.selected,
        focused: picker.focusedEntry ? picker.focusedEntry.name : null, sort: picker.sortBy, view: picker.view, live: picker.live,
        favourites: picker.favourites.length, coloured: Object.keys(picker.saved.colours).length, growing: picker.growing, grow: picker.grow }))
      fn()
    })
  }
  function key(k, mods) {
    var d = picker.deck
    if (!d) { console.error("FAIL no deck"); Qt.exit(1); return }
    if (k === "left") picker.move(-1); else if (k === "right") picker.move(1)
    else if (k === "fav") picker.toggleFavourite(); else if (k === "sort") picker.cycleSort()
    else if (k === "tab") picker.toggleView(); else if (k === "live") picker.toggleLive()
    else if (k === "enter") picker.activate()
  }
  // a scripted session; each step waits for the hand to settle
  property var steps: __STEPS__
  property int step: -1
  function next() {
    step++
    if (step >= steps.length) { console.log("RENDER_DONE " + shots); Qt.exit(0); return }
    var s = steps[step]
    if (s.open) { picker.open(s.open); after(s.wait || 900, next) }
    else if (s.key) { for (var i = 0; i < (s.times || 1); i++) key(s.key); after(s.wait || 420, next) }
    else if (s.shot) shot(s.shot, function() { after(10, next) })
    else if (s.waitColours) { var t0 = Date.now(); var poll = function() {
        if (Object.keys(picker.saved.colours).length >= picker.entries.length || Date.now() - t0 > 15000) next(); else after(100, poll) }; poll() }
    else if (s.wait) after(s.wait, next)
    else next()
  }
  Component.onCompleted: after(600, next)
}
'''

STUB_COLOR = '''pragma Singleton
import QtQuick
QtObject {
 property color foreground: "__FG__"
 property color accent: "__ACCENT__"
 property color urgent: "#ff6969"
 property color background: "__BG__"
 property QtObject popups: QtObject { property color background: "__BG__"; property color text: "__FG__" }
 property QtObject bar: QtObject { property color background: "__BG__" }
}
'''
STUB_STYLE = '''pragma Singleton
import QtQuick
QtObject {
 property bool reduceMotion: false
 property int cornerRadius: 0
 property QtObject font: QtObject { property string family: "JetBrainsMono Nerd Font"; property int caption: 12; property int body: 14; property int bodySmall: 13 }
 function space(n) { return Math.max(1, Math.round(n)) }
 function duration(n) { return reduceMotion ? 0 : n }
}
'''

STEPS = [
    {'open': 'theme', 'wait': 1200}, {'shot': '01-theme-open'},
    {'key': 'right', 'times': 3, 'wait': 600}, {'shot': '02-theme-moved'},
    {'waitColours': True}, {'key': 'sort', 'wait': 700}, {'shot': '03-theme-sort-colour'},
    {'key': 'sort', 'wait': 500}, {'shot': '04-theme-sort-newest'}, {'key': 'sort', 'wait': 300},
    {'open': 'wallpaper', 'wait': 1200}, {'shot': '05-wallpaper-open'},
    {'key': 'right', 'wait': 500}, {'key': 'fav', 'wait': 300}, {'shot': '06-wallpaper-favourite'},
    {'key': 'tab', 'wait': 500}, {'shot': '07-wallpaper-favourites-view'}, {'key': 'tab', 'wait': 400},
    {'key': 'enter', 'wait': 120}, {'shot': '08-grow-start'}, {'wait': 160}, {'shot': '09-grow-middle'},
    {'wait': 220}, {'shot': '10-grow-late'}, {'wait': 900},
]


def theme_colours():
    state = Path.home() / '.local/state/omarchy/current/theme/colors.toml'
    vals = {}
    try:
        for line in state.read_text().splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                k, v = line.split('=', 1)
                vals[k.strip()] = v.strip().strip('"')
    except OSError:
        pass
    return vals.get('background', '#111419'), vals.get('foreground', '#f0f3f7'), vals.get('accent', '#ffffff')


def free_display():
    for n in range(91, 120):
        if not Path(f'/tmp/.X11-unix/X{n}').exists() and not Path(f'/tmp/.X{n}-lock').exists():
            return n
    raise SystemExit('no free X display')


def run(out, size, video, steps, state_dir=None):
    out.mkdir(parents=True, exist_ok=True)
    w, h = size
    bg, fg, accent = theme_colours()
    desk = Path(os.path.realpath(Path.home() / '.local/state/omarchy/current/background'))
    with tempfile.TemporaryDirectory(prefix='card-picker-') as scratch:
        tmp = Path(scratch)
        commons = tmp / 'Commons'
        commons.mkdir()
        (commons / 'qmldir').write_text('module qs.Commons\nsingleton Color 1.0 Color.qml\nsingleton Style 1.0 Style.qml\n')
        (commons / 'Color.qml').write_text(STUB_COLOR.replace('__BG__', bg).replace('__FG__', fg).replace('__ACCENT__', accent))
        (commons / 'Style.qml').write_text(STUB_STYLE)
        for name in ['Picker.qml', 'Deck.qml', 'Logic.js']:
            shutil.copy2(ROOT / name, tmp / name)
        qml = (SHELL.replace('__W__', str(w)).replace('__H__', str(h)).replace('__OUT__', str(out)).replace('__DESK__', str(desk))
               .replace('__STATE__', str(out / 'state.json')).replace('__STATEDIR__', f'; stateDir: "{state_dir}"' if state_dir else '').replace('__STEPS__', json.dumps(steps)))
        (tmp / 'shell.qml').write_text(qml)
        n = free_display()
        xvfb = subprocess.Popen(['Xvfb', f':{n}', '-screen', '0', f'{w}x{h}x24', '-nolisten', 'tcp'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        rec = None
        try:
            time.sleep(0.8)
            env = {**os.environ, 'DISPLAY': f':{n}', 'QT_QPA_PLATFORM': 'xcb', 'QSG_RHI_BACKEND': 'opengl', 'LIBGL_ALWAYS_SOFTWARE': '1',
                   'QT_LOGGING_RULES': 'quickshell.dbus*:false', 'WAYLAND_DISPLAY': '', 'HYPRLAND_INSTANCE_SIGNATURE': ''}
            env.pop('WAYLAND_DISPLAY'); env.pop('HYPRLAND_INSTANCE_SIGNATURE')
            if video:
                rec = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'x11grab', '-draw_mouse', '0', '-framerate', '30',
                                        '-video_size', f'{w}x{h}', '-i', f':{n}', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '14', '-pix_fmt', 'yuv420p',
                                        str(out / 'session-raw.mp4')], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with (out / 'render.log').open('w') as log:
                proc = subprocess.Popen(['quickshell', '-n', '-p', str(tmp)], env=env, stdout=log, stderr=subprocess.STDOUT, text=True, start_new_session=True)
                try:
                    proc.wait(timeout=180)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=5)
        finally:
            if rec:
                rec.communicate(b'q', timeout=20)
            os.killpg(xvfb.pid, signal.SIGTERM)
        text = (out / 'render.log').read_text()
        done = [l for l in text.splitlines() if 'RENDER_DONE' in l]
        assert proc.returncode == 0 and done, f'render failed ({proc.returncode}):\n' + '\n'.join(text.splitlines()[-30:])
        would = [l.split('CARD_PICKER_WOULD_RUN ', 1)[1] for l in text.splitlines() if 'CARD_PICKER_WOULD_RUN' in l]
        print(done[-1], '| would run:', would)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--size', default='1920x1080')
    ap.add_argument('--video', action='store_true')
    ap.add_argument('--steps', type=Path, help='a JSON list of steps instead of the built-in session')
    ap.add_argument('--state-dir', type=Path, help='a stand-in for ~/.local/state/omarchy/current (theme.name, theme/backgrounds, background)')
    a = ap.parse_args()
    run(a.output.resolve(), tuple(int(x) for x in a.size.split('x')), a.video, json.loads(a.steps.read_text()) if a.steps else STEPS, a.state_dir.resolve() if a.state_dir else None)
