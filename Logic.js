.pragma library

// The card picker's pure logic, kept free of QML so tests/logic.cjs can run it
// in Node: Omarchy's rows, favourite keys, colour keys from ImageMagick's
// histogram, and the three orders of the hand.

var SORTS = ["name", "colour", "newest"]
var SORT_LABELS = { name: "Name", colour: "Colour", newest: "Newest" }

function prettify(name) {
  return String(name || "").replace(/^\d+[-_ ]+/, "").replace(/[-_]+/g, " ")
    .replace(/\b\w/g, function(c) { return c.toUpperCase() })
}

function fileName(path) {
  return String(path || "").split("/").pop()
}

function baseName(path) {
  var b = fileName(path)
  var dot = b.lastIndexOf(".")
  return dot > 0 ? b.substring(0, dot) : b
}

var VIDEO = /\.(mp4|m4v|mov|webm|mkv|avi)$/i
var ANIMATED = /\.(gif|webp)$/i
function isVideo(path) { return VIDEO.test(String(path || "")) }
function isAnimated(path) { return ANIMATED.test(String(path || "")) }

// `omarchy-theme-switcher --print-rows` / `omarchy-menu-images --print-rows`:
// "<preview or file>\t<thumbnail>" per line. `order` keeps Omarchy's own order
// (the "name" sort: for backgrounds the 1- file is the theme's default).
function parseRows(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var cols = lines[i].split("\t")
    if (cols.length < 2 || !cols[0]) continue
    var name = baseName(cols[0])
    out.push({ name: name, title: prettify(name), path: cols[0], thumb: cols[1], order: out.length,
               video: isVideo(cols[0]), animated: isAnimated(cols[0]) })
  }
  return out
}

// A theme is its name. A background is its theme plus its file name: every
// theme's backgrounds are applied under the same folder
// (~/.local/state/omarchy/current/theme/backgrounds), so the path alone would
// mix up "1-…" of different themes.
function favKey(mode, theme, entry) {
  if (!entry) return ""
  return mode === "theme" ? entry.name : String(theme || "") + (String(entry.path).indexOf("/.config/omarchy/backgrounds/") >= 0 ? "/extra/" : "/") + fileName(entry.path)
}

function nextSort(sort) {
  var i = SORTS.indexOf(sort)
  return SORTS[(i + 1) % SORTS.length]
}

function rgbToHsl(r, g, b) {
  r /= 255; g /= 255; b /= 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, h = 0, s = 0
  var d = max - min
  if (d > 0) {
    s = d / (1 - Math.abs(2 * l - 1))
    if (max === r) h = 60 * (((g - b) / d) % 6)
    else if (max === g) h = 60 * ((b - r) / d + 2)
    else h = 60 * ((r - g) / d + 4)
    if (h < 0) h += 360
  }
  return { h: h, s: s, l: l, c: d }
}

// ImageMagick's `-colors N -format %c histogram:info:` lines, e.g.
//   "   731: (6,6,6) #060606 gray(6)" (joined by ";" or newlines).
// The key is the hue of the colour that has the most colour in it (pixel count
// times chroma), so a dark picture with a copper glow sorts as copper. A
// picture without colour sorts as grey, by lightness, after the colours.
function colourKey(histogram) {
  var parts = String(histogram || "").split(/[;\n]/)
  var best = null, total = 0, light = 0
  for (var i = 0; i < parts.length; i++) {
    var m = /^\s*(\d+):\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/.exec(parts[i])
    if (!m) continue
    var n = Number(m[1]), c = rgbToHsl(Number(m[2]), Number(m[3]), Number(m[4]))
    total += n
    light += n * c.l
    var weight = n * c.c
    if (!best || weight > best.weight) best = { weight: weight, h: c.h, chroma: c.c, n: n }
  }
  if (!best || total === 0) return null
  var lightness = light / total
  // grey: the most colourful colour is barely tinted, or covers too little of the picture
  // (less than ~6 % at chroma 0.25)
  var grey = best.chroma < 0.08 || best.weight / total < 0.015
  return { hue: Math.round(best.h), grey: grey, light: Math.round(lightness * 1000) / 1000 }
}

function compareColour(a, b) {
  if (!a && !b) return 0
  if (!a) return 1
  if (!b) return -1
  if (a.grey !== b.grey) return a.grey ? 1 : -1
  if (a.grey) return b.light - a.light            // greys light to dark
  return a.hue - b.hue                             // round the hue wheel from red
}

// entries: parseRows' rows; meta.colours: thumb -> colourKey; meta.mtimes: key -> seconds.
// Stable: equal keys keep Omarchy's order; unknown colours and times go last.
function sortEntries(entries, sort, meta) {
  var list = entries.slice()
  meta = meta || {}
  if (sort === "colour") {
    var colours = meta.colours || {}
    list.sort(function(a, b) { return compareColour(colours[a.thumb], colours[b.thumb]) || a.order - b.order })
  } else if (sort === "newest") {
    var times = meta.mtimes || {}
    list.sort(function(a, b) {
      var ta = times[a.path] || times[a.name] || 0, tb = times[b.path] || times[b.name] || 0
      return (tb - ta) || a.order - b.order
    })
  } else {
    list.sort(function(a, b) { return a.order - b.order })
  }
  return list
}

// The hand: all cards or only the favourites, then the typed filter.
function visibleEntries(entries, opts) {
  var o = opts || {}
  var f = String(o.filter || "").toLowerCase()
  var favs = o.favourites || []
  var list = sortEntries(entries, o.sort || "name", o.meta)
  return list.filter(function(e) {
    if (o.view === "favourites" && favs.indexOf(favKey(o.mode, o.theme, e)) === -1) return false
    return f === "" || e.title.toLowerCase().indexOf(f) !== -1
  })
}

function toggled(list, key) {
  var out = (list || []).slice()
  var i = out.indexOf(key)
  if (i === -1) out.push(key); else out.splice(i, 1)
  return out
}

// The saved state (~/.local/state/nerdibeard.card-picker/state.json); unknown
// or broken values fall back to the defaults.
function readState(text) {
  var s = {}
  try { s = JSON.parse(text || "{}") || {} } catch (e) { s = {} }
  var sort = s.sort || {}
  var fav = s.favourites || {}
  return {
    version: 1,
    sort: { theme: SORTS.indexOf(sort.theme) >= 0 ? sort.theme : "name", wallpaper: SORTS.indexOf(sort.wallpaper) >= 0 ? sort.wallpaper : "name" },
    live: s.live === true,
    favourites: { theme: Array.isArray(fav.theme) ? fav.theme.map(String) : [], wallpaper: Array.isArray(fav.wallpaper) ? fav.wallpaper.map(String) : [] },
    colours: s.colours && typeof s.colours === "object" ? s.colours : {}
  }
}

// The grow on apply, p 0..1: the card comes to the middle, a little larger
// (first 40 %), then grows into the full screen. rect = [x, y, w, h].
function easeInOut(t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2 }
function mixRect(a, b, t) { return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t] }
function growRect(card, screen, p) {
  var cw = card[2] * 1.12, ch = card[3] * 1.12
  var mid = [(screen[2] - cw) / 2, (screen[3] - ch) / 2, cw, ch]
  if (p <= 0.4) return mixRect(card, mid, easeInOut(Math.max(0, p) / 0.4))
  return mixRect(mid, screen, easeInOut(Math.min(1, (p - 0.4) / 0.6)))
}
// the light as it reaches the middle, gone once it fills the screen
function growGlow(p) {
  var d = (p - 0.42) / 0.16
  return 0.22 * Math.exp(-d * d)
}

if (typeof module !== "undefined") module.exports = { SORTS: SORTS, SORT_LABELS: SORT_LABELS, prettify: prettify, fileName: fileName, baseName: baseName,
  isVideo: isVideo, isAnimated: isAnimated, parseRows: parseRows, favKey: favKey, nextSort: nextSort, rgbToHsl: rgbToHsl, colourKey: colourKey,
  compareColour: compareColour, sortEntries: sortEntries, visibleEntries: visibleEntries, toggled: toggled, readState: readState,
  growRect: growRect, growGlow: growGlow }
