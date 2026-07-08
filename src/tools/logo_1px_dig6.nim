## Sample exact RGB columns at letter bottoms for the 1px gap.
import
  std/[os, options, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, png_state, save_state]

proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512: start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8

proc dist(p, bd: ColorRGBA): int =
  abs(p.r.int - bd.r.int) + abs(p.g.int - bd.g.int) + abs(p.b.int - bd.b.int)

proc main() =
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(paramStr(2)))).get, snes, cpu)
  let bd = ppu.bgr555ToColor(snes.cgram[0])
  let tm = snes.ppuRegs[0x2C]
  echo &"backdrop=({bd.r},{bd.g},{bd.b}) TM={tm:02X} CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X}"
  echo &"INIDISP={snes.ppuRegs[0x00]:02X} MODE={snes.ppuRegs[0x05]:02X}"
  echo &"BG1SC={snes.ppuRegs[0x07]:02X} BG12NBA={snes.ppuRegs[0x0B]:02X}"
  echo &"scroll BG1H={snes.bgScroll[0]:04X} V={snes.bgScroll[1]:04X}"

  let bg = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  bg.fill(bd)
  snes.ppuRegs[0x2C] = tm and not 0x10'u8
  for line in 0 ..< 224: ppu.renderScanline(snes, bg, line)
  snes.ppuRegs[0x2C] = tm

  let sp = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  sp.fill(bd)
  ppu.renderSprites(snes, sp)

  let full = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  full.fill(bd)
  for line in 0 ..< 224: ppu.renderScanline(snes, full, line)
  ppu.renderSprites(snes, full)

  # Mid-letter x positions (EARTH Bound approximate centers)
  let xs = [30, 50, 70, 90, 110, 130, 150, 170, 190, 210]
  for x in xs:
    echo &"\n=== column x={x} full RGB (y=110..145) ==="
    for y in 110 .. 145:
      let f = full[x, y]
      let b = bg[x, y]
      let s = sp[x, y]
      let fd = dist(f, bd)
      let bdMark = if fd < 20: " <BD" else: ""
      echo &"  y={y:3}: F=({f.r:3},{f.g:3},{f.b:3}) d={fd:3}  B=({b.r:3},{b.g:3},{b.b:3})  S=({s.r:3},{s.g:3},{s.b:3}){bdMark}"

  # Find sandwich: lit, backdrop-ish, lit within 3 rows (true 1px gap)
  var sandwiches = 0
  var examples: seq[string]
  for x in 15 .. 240:
    for y in 100 .. 145:
      let a = dist(full[x, y], bd)
      let b = dist(full[x, y + 1], bd)
      let c = dist(full[x, y + 2], bd)
      # lit, near-backdrop, lit again
      if a > 80 and b < 35 and c > 50:
        inc sandwiches
        if examples.len < 12:
          let p0 = full[x, y]
          let p1 = full[x, y + 1]
          let p2 = full[x, y + 2]
          examples.add(&"  ({x},{y}): ({p0.r},{p0.g},{p0.b}) | ({p1.r},{p1.g},{p1.b}) | ({p2.r},{p2.g},{p2.b})")
  echo &"\nsandwich lit|backdrop|lit count={sandwiches}"
  for e in examples: echo e

  # Same sandwich on BG-only
  var bgSand = 0
  for x in 15 .. 240:
    for y in 100 .. 145:
      let a = dist(bg[x, y], bd)
      let b = dist(bg[x, y + 1], bd)
      let c = dist(bg[x, y + 2], bd)
      if a > 80 and b < 35 and c > 50:
        inc bgSand
  echo &"BG-only sandwich count={bgSand}"

  # Local brightness dip: brighter row, darker middle, brighter below (relative dip)
  var dips = 0
  var dipEx: seq[string]
  for x in 15 .. 240:
    for y in 100 .. 145:
      let s0 = full[x, y].r.int + full[x, y].g.int + full[x, y].b.int
      let s1 = full[x, y + 1].r.int + full[x, y + 1].g.int + full[x, y + 1].b.int
      let s2 = full[x, y + 2].r.int + full[x, y + 2].g.int + full[x, y + 2].b.int
      # sharp dip: middle much darker than both neighbors
      if s0 > 200 and s2 > 120 and s1 < s0 - 100 and s1 < s2 - 40:
        # not pure orange-to-glow soft falloff (which is monotonic-ish)
        inc dips
        if dipEx.len < 15:
          dipEx.add(&"  ({x},{y}): sum {s0}->{s1}->{s2}")
  echo &"brightness dip count={dips}"
  for e in dipEx: echo e

  # Compare user screenshot pixels directly (embedded image vs re-render)
  let shot = readImage(paramStr(2))
  var mismatch = 0
  var maxd = 0
  for y in 70 .. 145:
    for x in 20 .. 235:
      let a = shot[x, y]
      let b = full[x, y]
      let d = abs(a.r.int - b.r.int) + abs(a.g.int - b.g.int) + abs(a.b.int - b.b.int)
      if d > 0:
        inc mismatch
        if d > maxd: maxd = d
  echo &"\nshot vs re-render mismatches in logo band: {mismatch} maxd={maxd}"

  # Dump CGRAM palettes that are non-zero
  echo "\nnon-zero CGRAM entries:"
  for i in 0 .. 255:
    let c = snes.cgram[i]
    if c != 0:
      let col = ppu.bgr555ToColor(c)
      echo &"  [{i:3}] = {c:04X} -> ({col.r},{col.g},{col.b})"

when isMainModule: main()
