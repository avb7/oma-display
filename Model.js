.pragma library
// Pure layout helpers for the oma-display panel. No QML imports, so this
// file is unit-testable with plain node (see test/model.test.js).

function isInternal(name) {
  return /^(eDP|LVDS|DSI)-/.test(String(name || ""))
}

function stripHz(mode) {
  return String(mode || "").replace(/Hz$/, "")
}

function modeString(width, height, refresh) {
  return width + "x" + height + "@" + Number(refresh || 60).toFixed(2)
}

function parseMode(mode) {
  var m = String(mode || "").match(/^(\d+)x(\d+)(?:@([\d.]+))?/)
  if (!m) return null
  return { width: parseInt(m[1], 10), height: parseInt(m[2], 10), refresh: m[3] ? parseFloat(m[3]) : 60 }
}

function uniq(list) {
  var seen = {}, out = []
  for (var i = 0; i < list.length; i++) {
    if (seen[list[i]]) continue
    seen[list[i]] = true
    out.push(list[i])
  }
  return out
}

// hyprctl monitors all -j  ->  editable model
function fromHyprctl(json) {
  var raw = []
  try { raw = JSON.parse(String(json || "[]")) } catch (e) { raw = [] }
  if (!Array.isArray(raw)) raw = []
  var out = []
  for (var i = 0; i < raw.length; i++) {
    var r = raw[i]
    if (!r || !r.name) continue
    var current = modeString(r.width, r.height, r.refreshRate)
    var modes = uniq([current].concat((r.availableModes || []).map(stripHz)))
    var internal = isInternal(r.name)
    out.push({
      name: String(r.name),
      description: String(r.description || ""),
      label: String(((r.make || "") + " " + (r.model || "")).trim() || r.description || r.name),
      // Internal panels are keyed by connector (Omarchy's clamshell watcher
      // reads the eDP rule by name). Externals are keyed by EDID description
      // so the layout follows the screen across ports and docks.
      output: (!internal && r.description) ? "desc:" + r.description : String(r.name),
      internal: internal,
      mode: current,
      modes: modes,
      x: Math.round(r.x || 0),
      y: Math.round(r.y || 0),
      scale: Number(r.scale) || 1,
      transform: Number(r.transform) || 0,
      disabled: r.disabled === true,
      focused: r.focused === true
    })
  }
  out.sort(function(a, b) { return a.x - b.x || a.y - b.y })
  return out
}

function clone(list) {
  return JSON.parse(JSON.stringify(list || []))
}

// Logical (post-scale, post-rotation) size, which is what positions use.
function logicalSize(m) {
  var p = parseMode(m.mode) || { width: 1920, height: 1080 }
  var w = Math.round(p.width / (m.scale || 1))
  var h = Math.round(p.height / (m.scale || 1))
  if (m.transform % 2 === 1) { var t = w; w = h; h = t }
  return { w: w, h: h }
}

function rect(m) {
  var s = logicalSize(m)
  return { x: m.x, y: m.y, w: s.w, h: s.h }
}

function overlaps(a, b) {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

function enabled(list) {
  return list.filter(function(m) { return !m.disabled })
}

function bounds(list) {
  var en = enabled(list)
  if (!en.length) return { x: 0, y: 0, w: 1, h: 1 }
  var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
  for (var i = 0; i < en.length; i++) {
    var r = rect(en[i])
    x0 = Math.min(x0, r.x); y0 = Math.min(y0, r.y)
    x1 = Math.max(x1, r.x + r.w); y1 = Math.max(y1, r.y + r.h)
  }
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
}

// Shift everything so the top-left-most enabled monitor sits at 0,0.
function normalize(list) {
  var b = bounds(list)
  return list.map(function(m) {
    var c = clone([m])[0]
    if (!c.disabled) { c.x -= b.x; c.y -= b.y }
    return c
  })
}

// Place monitor `idx` touching an edge of another enabled monitor, choosing
// the placement nearest to where it was dropped (dropX, dropY in logical px).
// Along the shared edge it snaps to start/center/end alignment when within
// `snap` px, otherwise keeps the dropped offset. Placements that overlap a
// third monitor are skipped.
function snapPlace(list, idx, dropX, dropY, snap) {
  snap = snap === undefined ? 120 : snap
  var me = list[idx]
  var size = logicalSize(me)
  var others = []
  for (var i = 0; i < list.length; i++)
    if (i !== idx && !list[i].disabled) others.push(rect(list[i]))
  if (!others.length) return { x: 0, y: 0 }

  function along(start, len, otherStart, otherLen, dropped) {
    // Keep at least 1px of shared edge so the monitors stay connected.
    var lo = otherStart - len + 1, hi = otherStart + otherLen - 1
    var v = Math.max(lo, Math.min(hi, dropped))
    var anchors = [otherStart, otherStart + otherLen - len, otherStart + Math.round((otherLen - len) / 2)]
    var best = v, bestD = snap + 1
    for (var a = 0; a < anchors.length; a++) {
      var d = Math.abs(anchors[a] - v)
      if (d <= snap && d < bestD) { best = anchors[a]; bestD = d }
    }
    return best
  }

  var candidates = []
  for (var o = 0; o < others.length; o++) {
    var r = others[o]
    candidates.push({ x: r.x - size.w, y: along(0, size.h, r.y, r.h, dropY) })   // left of
    candidates.push({ x: r.x + r.w,    y: along(0, size.h, r.y, r.h, dropY) })   // right of
    candidates.push({ x: along(0, size.w, r.x, r.w, dropX), y: r.y - size.h })   // above
    candidates.push({ x: along(0, size.w, r.x, r.w, dropX), y: r.y + r.h })      // below
  }

  var best = null, bestDist = Infinity
  for (var c = 0; c < candidates.length; c++) {
    var cand = { x: candidates[c].x, y: candidates[c].y, w: size.w, h: size.h }
    var clash = false
    for (var k = 0; k < others.length; k++) if (overlaps(cand, others[k])) { clash = true; break }
    if (clash) continue
    var dist = Math.hypot(cand.x - dropX, cand.y - dropY)
    if (dist < bestDist) { best = cand; bestDist = dist }
  }
  return best ? { x: best.x, y: best.y } : { x: me.x, y: me.y }
}

function moveTo(list, idx, dropX, dropY, snap) {
  var out = clone(list)
  var p = snapPlace(out, idx, dropX, dropY, snap)
  out[idx].x = p.x
  out[idx].y = p.y
  return normalize(out)
}

// After a scale/mode/rotation change the monitor's size changes; re-seat it
// against its neighbours from its current top-left so nothing overlaps.
function reseat(list, idx) {
  if (enabled(list).length < 2 || list[idx].disabled) return normalize(list)
  return moveTo(list, idx, list[idx].x, list[idx].y, 0)
}

// Re-seat every enabled monitor left-to-right so the layout is gap- and
// overlap-free. Used after enabling a monitor.
function tidy(list) {
  var out = normalize(list)
  var order = out.map(function(m, i) { return i }).filter(function(i) { return !out[i].disabled })
  order.sort(function(a, b) { return out[a].x - out[b].x || out[a].y - out[b].y })
  for (var n = 1; n < order.length; n++) out = moveTo(out, order[n], out[order[n]].x, out[order[n]].y, 0)
  return out
}

function gcd(a, b) { while (b) { var t = a % b; a = b; b = t } return a }

// Hyprland only accepts scales that divide the mode into whole logical pixels
// (in 1/120 steps). Round up to the nearest clean value.
function cleanScale(scale, mode) {
  var p = parseMode(mode)
  var s = Number(scale)
  if (!p || !isFinite(s) || s <= 0) return 1
  var divisor = gcd(Math.round(p.width * 120), Math.round(p.height * 120))
  var units = Math.round(s * 120)
  if (units > divisor) units = divisor
  while (divisor % units !== 0) units++
  return Math.round(units / 120 * 1000) / 1000
}

function scaleOptions(mode) {
  var presets = [1, 1.25, 1.5, 1.6, 2, 3]
  return uniq(presets.map(function(s) { return cleanScale(s, mode) }))
}

function payload(list) {
  return JSON.stringify(list.map(function(m) {
    if (m.disabled) return { output: m.output, disabled: true }
    return { output: m.output, mode: m.mode, x: m.x, y: m.y, scale: m.scale, transform: m.transform }
  }))
}

function sameLayout(a, b) {
  return payload(a || []) === payload(b || [])
}

var rotations = [
  { transform: 0, label: "0°" },
  { transform: 1, label: "90°" },
  { transform: 2, label: "180°" },
  { transform: 3, label: "270°" }
]
