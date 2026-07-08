## What do logo sprites actually paint?
import
  std/[os, options, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, png_state, save_state]

proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512: start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8

proc main() =
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(paramStr(2)))).get, snes, cpu)
  let bd = ppu.bgr555ToColor(snes.cgram[0])
  let sprOnly = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  sprOnly.fill(bd)
  ppu.renderSprites(snes, sprOnly)
  sprOnly.writeFile("bin/logo_spr_only.png")

  var n = 0
  var minY = 999
  var maxY = 0
  var minX = 999
  var maxX = 0
  for y in 0 ..< 224:
    for x in 0 ..< 256:
      let p = sprOnly[x, y]
      let d = abs(p.r.int-bd.r.int)+abs(p.g.int-bd.g.int)+abs(p.b.int-bd.b.int)
      if d < 20: continue
      inc n
      if y < minY: minY = y
      if y > maxY: maxY = y
      if x < minX: minX = x
      if x > maxX: maxX = x
  echo &"sprite opaque pixels={n} bbox=({minX},{minY})-({maxX},{maxY})"

  # Compare full vs bg-only: where do sprites change the composite?
  let tm = snes.ppuRegs[0x2C]
  let bgOnly = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  bgOnly.fill(bd)
  snes.ppuRegs[0x2C] = tm and not 0x10'u8
  for line in 0 ..< 224:
    ppu.renderScanline(snes, bgOnly, line)
  snes.ppuRegs[0x2C] = tm
  bgOnly.writeFile("bin/logo_bg_only.png")

  let full = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  full.fill(bd)
  for line in 0 ..< 224:
    ppu.renderScanline(snes, full, line)
  ppu.renderSprites(snes, full)
  full.writeFile("bin/logo_full.png")

  var diff = 0
  var diffBottom = 0  # y >= 120
  for y in 0 ..< 224:
    for x in 0 ..< 256:
      let a = full[x,y]; let b = bgOnly[x,y]
      if a.r != b.r or a.g != b.g or a.b != b.b:
        inc diff
        if y >= 120: inc diffBottom
  echo &"pixels where sprites change composite: {diff} (of which y>=120: {diffBottom})"

  # Bottom edge of orange: for each column, lowest y with orange-ish full pixel
  # Check if that pixel's row has a "hard" bottom (next row much darker) without soft falloff
  var hardEdges = 0
  var softEdges = 0
  for x in 20 .. 235:
    var bot = -1
    for y in countdown(150, 60):
      let p = full[x, y]
      if p.r > 140 and p.g > 50 and p.b < 130 and p.r.int > p.b.int + 30:
        bot = y
        break
    if bot < 0 or bot >= 223: continue
    let cur = full[x, bot]
    let nxt = full[x, bot + 1]
    let curS = cur.r.int + cur.g.int + cur.b.int
    let nxtS = nxt.r.int + nxt.g.int + nxt.b.int
    # hard edge: drops sharply to near-backdrop
    let bdS = bd.r.int + bd.g.int + bd.b.int
    if curS > bdS + 80 and nxtS < bdS + 40:
      inc hardEdges
    elif curS > bdS + 80 and nxtS > bdS + 40:
      inc softEdges
  echo &"orange bottom columns: hard drop to backdrop={hardEdges} soft falloff={softEdges}"

  # Check BG V scroll / mode 3 tile sampling at letter bottom
  echo &"BG1V={snes.bgScroll[1]:04X} MODE={snes.ppuRegs[0x05]:02X}"
  # Sample tile row at y=bot for a mid letter x=80
  let vofs = snes.bgScroll[1].int
  for y in [120, 125, 128, 130, 132]:
    let wy = y + vofs
    echo &"  screen y={y} -> worldY={wy} tileRow={wy div 8} subY={wy mod 8}"

when isMainModule: main()
