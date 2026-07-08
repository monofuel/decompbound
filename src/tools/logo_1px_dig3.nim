## Classify letter-core vs glow pixels; test BG/OBJ 1px vertical shifts.
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

proc isBackdrop(p, bd: ColorRGBA): bool =
  abs(p.r.int - bd.r.int) + abs(p.g.int - bd.g.int) + abs(p.b.int - bd.b.int) < 25

proc isOrangeLetter(p: ColorRGBA): bool =
  ## Hot orange/yellow logo body.
  p.r > 140 and p.g > 60 and p.g < 200 and p.b < 120 and p.r > p.b + 40

proc isPaleGlow(p: ColorRGBA): bool =
  ## Soft white/lavender fringe (not pure backdrop, not hot orange).
  let s = p.r.int + p.g.int + p.b.int
  s > 120 and p.r > 80 and p.g > 60 and not isOrangeLetter(p)

proc main() =
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(paramStr(2)))).get, snes, cpu)
  let bd = ppu.bgr555ToColor(snes.cgram[0])
  let tm = snes.ppuRegs[0x2C]

  let bgOnly = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  bgOnly.fill(bd)
  snes.ppuRegs[0x2C] = tm and not 0x10'u8
  for line in 0 ..< 224:
    ppu.renderScanline(snes, bgOnly, line)
  snes.ppuRegs[0x2C] = tm

  let sprOnly = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  sprOnly.fill(bd)
  ppu.renderSprites(snes, sprOnly)

  let full = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  full.fill(bd)
  for line in 0 ..< 224:
    ppu.renderScanline(snes, full, line)
  ppu.renderSprites(snes, full)

  const x0 = 20
  const x1 = 235
  # Find orange letter vertical extent on FULL composite
  var oMin = 224
  var oMax = 0
  for y in 0 ..< 224:
    for x in x0 .. x1:
      if isOrangeLetter(full[x, y]):
        if y < oMin: oMin = y
        if y > oMax: oMax = y
  echo &"orange letter extent y={oMin}..{oMax}"

  for y in (oMax - 5) .. (oMax + 3):
    var orange, glow, oNoG, gNoO = 0
    var oBg, oSpr, gBg, gSpr = 0
    for x in x0 .. x1:
      let f = full[x, y]
      let b = bgOnly[x, y]
      let s = sprOnly[x, y]
      if isOrangeLetter(f):
        inc orange
        if isPaleGlow(f): discard
        if not isPaleGlow(s) and not isOrangeLetter(s) and isPaleGlow(b):
          discard
        if isOrangeLetter(b): inc oBg
        if isOrangeLetter(s): inc oSpr
        if not isPaleGlow(s) and not isOrangeLetter(s):
          # letter with no sprite at all under/over
          if not isPaleGlow(b):
            inc oNoG
      if isPaleGlow(f):
        inc glow
        if isPaleGlow(b): inc gBg
        if isPaleGlow(s): inc gSpr
    echo &"  y={y:3}: orange={orange:4} (bg={oBg} spr={oSpr}) glow={glow:4} (bg={gBg} spr={gSpr})"

  # Per-letter: scan bottom edge of orange for missing pale-glow neighbor below
  var missingBelow = 0
  var totalBot = 0
  for x in x0 .. x1:
    # find lowest orange pixel in column
    var bot = -1
    for y in countdown(oMax + 2, oMin):
      if isOrangeLetter(full[x, y]):
        bot = y
        break
    if bot < 0: continue
    inc totalBot
    # check pixel below for glow
    if bot + 1 < 224:
      let below = full[x, bot + 1]
      if isBackdrop(below, bd) or isOrangeLetter(below):
        # no pale glow directly below letter bottom
        if not isPaleGlow(below):
          inc missingBelow
    # also check same pixel for glow fringe on bottom of letter itself
  echo &"columns with orange: {totalBot}; bottom edge without pale glow below: {missingBelow}"

  # Same analysis with sprites shifted down by 1 (sample spr at y-1 for screen y)
  var missingShift = 0
  for x in x0 .. x1:
    var bot = -1
    for y in countdown(oMax + 2, oMin):
      if isOrangeLetter(bgOnly[x, y]):  # letter on BG
        bot = y
        break
    if bot < 0: continue
    # glow from sprite shifted down 1: content at bot comes from spr bot-1
    let sy = bot - 1
    let hasGlow = sy >= 0 and (isPaleGlow(sprOnly[x, sy]) or isOrangeLetter(sprOnly[x, sy]))
    if not hasGlow:
      # also check unshifted
      discard
    let hasGlow2 = sy >= 0 and isPaleGlow(sprOnly[x, sy])
    if not hasGlow2 and not isPaleGlow(sprOnly[x, bot]):
      # still gap
      if not isPaleGlow(bgOnly[x, bot + 1]) and not isPaleGlow(bgOnly[x, bot]):
        inc missingShift
  echo &"(rough) after spr+1 still gaps-ish: {missingShift}"

  # What is the glow - BG or sprite? Sample a known fringe pixel
  # Find first pale glow pixel
  var samples = 0
  for y in oMin .. oMax:
    for x in x0 .. x1:
      if samples > 5: break
      if isPaleGlow(full[x, y]):
        let b = bgOnly[x, y]
        let s = sprOnly[x, y]
        echo &"  glow sample ({x},{y}) full=({full[x,y].r},{full[x,y].g},{full[x,y].b}) bg_lit={not isBackdrop(b,bd)} spr_lit={not isBackdrop(s,bd)} bg=({b.r},{b.g},{b.b}) spr=({s.r},{s.g},{s.b})"
        inc samples

when isMainModule: main()
