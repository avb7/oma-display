// Run: node test/model.test.js   (no deps)
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(".pragma library", "")
const M = new Function(src + "; return { fromHyprctl, logicalSize, moveTo, reseat, tidy, cleanScale, scaleOptions, payload, overlaps, rect, normalize, sameLayout }")()

const hypr = JSON.stringify([
  { name: "eDP-1", description: "LG Display 0x06AA", make: "LG Display", model: "0x06AA", width: 3840, height: 2400, refreshRate: 60, x: 0, y: 0, scale: 2, transform: 0, disabled: false, focused: true, availableModes: ["3840x2400@60.00Hz"] },
  { name: "HDMI-A-1", description: "JHW Z34B 0000000000001", make: "JHW", model: "Z34B", width: 3440, height: 1440, refreshRate: 75, x: 1920, y: 0, scale: 1, transform: 0, disabled: false, focused: false, availableModes: ["3440x1440@75.00Hz", "3440x1440@100.00Hz", "2560x1440@120.00Hz"] }
])

let t = 0
function test(name, fn) { fn(); t++; console.log("ok -", name) }

const list = M.fromHyprctl(hypr)

test("parses monitors and keys outputs", () => {
  assert.strictEqual(list.length, 2)
  assert.strictEqual(list[0].output, "eDP-1")
  assert.strictEqual(list[1].output, "desc:JHW Z34B 0000000000001")
  assert.strictEqual(list[0].mode, "3840x2400@60.00")
  assert.deepStrictEqual(list[1].modes, ["3440x1440@75.00", "3440x1440@100.00", "2560x1440@120.00"])
})

test("logical size honours scale and rotation", () => {
  assert.deepStrictEqual(M.logicalSize(list[0]), { w: 1920, h: 1200 })
  assert.deepStrictEqual(M.logicalSize(Object.assign({}, list[1], { transform: 1 })), { w: 1440, h: 3440 })
})

test("drag external to the left of laptop snaps flush and normalizes", () => {
  const out = M.moveTo(list, 1, -3000, 50)
  assert.deepStrictEqual([out[1].x, out[1].y, out[0].x, out[0].y], [0, 0, 3440, 0])
  assert.ok(!M.overlaps(M.rect(out[0]), M.rect(out[1])))
})

test("drag external above laptop centers when close", () => {
  const out = M.moveTo(list, 1, -700, -1500)
  // centered: (1920-3440)/2 = -760 -> after normalize ext at 0, laptop at 760
  assert.strictEqual(out[1].y, 0)
  assert.strictEqual(out[0].y, 1440)
  assert.strictEqual(out[0].x - out[1].x, 760)
})

test("rotating external reseats without overlap", () => {
  const rot = M.normalize(list.map((m, i) => i === 1 ? Object.assign({}, m, { transform: 1 }) : m))
  const out = M.reseat(rot, 1)
  assert.ok(!M.overlaps(M.rect(out[0]), M.rect(out[1])))
  assert.strictEqual(out[1].x, 1920)
})

test("laptop scale change from 2 to 1 reseats external", () => {
  const changed = list.map((m, i) => i === 0 ? Object.assign({}, m, { scale: 1 }) : m)
  const out = M.reseat(changed, 0)
  assert.ok(!M.overlaps(M.rect(out[0]), M.rect(out[1])))
})

test("clean scales are valid for the panel", () => {
  assert.strictEqual(M.cleanScale(2, "3840x2400@60"), 2)
  assert.strictEqual(M.cleanScale(1.25, "3840x2400@60"), 1.25)
  const opts = M.scaleOptions("3440x1440@75")
  assert.ok(opts.includes(1) && opts.includes(2))
})

test("payload shape and disabled monitors", () => {
  const p = JSON.parse(M.payload([list[0], Object.assign({}, list[1], { disabled: true })]))
  assert.deepStrictEqual(p[0], { output: "eDP-1", mode: "3840x2400@60.00", x: 0, y: 0, scale: 2, transform: 0 })
  assert.deepStrictEqual(p[1], { output: "desc:JHW Z34B 0000000000001", disabled: true })
})

test("tidy fixes overlapping layout", () => {
  const broken = list.map(m => Object.assign({}, m, { x: 0, y: 0 }))
  const out = M.tidy(broken)
  assert.ok(!M.overlaps(M.rect(out[0]), M.rect(out[1])))
})

test("three monitors: placement avoids third", () => {
  const three = M.fromHyprctl(JSON.stringify([
    { name: "eDP-1", width: 1920, height: 1080, refreshRate: 60, x: 0, y: 0, scale: 1 },
    { name: "DP-1", description: "A", width: 1920, height: 1080, refreshRate: 60, x: 1920, y: 0, scale: 1 },
    { name: "DP-2", description: "B", width: 1920, height: 1080, refreshRate: 60, x: 3840, y: 0, scale: 1 }
  ]))
  const out = M.moveTo(three, 2, 1900, 10)
  const r = out.map(M.rect)
  assert.ok(!M.overlaps(r[0], r[2]) && !M.overlaps(r[1], r[2]) && !M.overlaps(r[0], r[1]))
})

console.log(`\n${t} tests passed`)
