## Focused letter-region BG vs sprite coverage for logo 1px gap.
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

proc isLit(p, bd: ColorRGBA): bool =
  abs(p.r.int - bd.r.int) + abs(p.g.int - bd.g.int) + abs(p.b.int - bd.b.int) > 40

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

  # Logo letters roughly y=70..130 from OAM
  const y0 = 70
  const y1 = 130
  const x0 = 15
  const x1 = 240
  # Find bottom-most BG-lit row in logo band
  var bot = y0
  for y in countdown(y1, y0):
    var n = 0
    for x in x0 .. x1:
      if isLit(bgOnly[x, y], bd): inc n
    if n > 20:
      bot = y
      break
  echo &"logo BG bottom row y={bot}"
  for y in (bot - 6) .. (bot + 3):
    var bgN, sprN, bgNoSpr, sprNoBg = 0
    for x in x0 .. x1:
      let bL = isLit(bgOnly[x, y], bd)
      let sL = isLit(sprOnly[x, y], bd)
      if bL: inc bgN
      if sL: inc sprN
      if bL and not sL: inc bgNoSpr
      if sL and not bL: inc sprNoBg
    echo &"  y={y:3}: bg={bgN:4} spr={sprN:4} bg_no_spr={bgNoSpr:4} spr_no_bg={sprNoBg:4}"

  # Sprite Y extent
  var minSY = 999; var maxSY = 0
  for sprite in 0 .. 127:
    let y = snes.oam[sprite * 4 + 1].int
    if y >= 224: continue
    let extra = snes.oam[512 + sprite div 4]
    let large = ((extra shr ((sprite mod 4) * 2 + 1)) and 1) != 0
    let sz = if large: 16 else: 8
    if y < minSY: minSY = y
    if y + sz - 1 > maxSY: maxSY = y + sz - 1
  echo &"sprite Y span: {minSY} .. {maxSY}"

  # Check if shifting sprites +1 or -1 reduces bg_no_spr on bottom row
  for dy in [-2, -1, 0, 1, 2]:
    var gap = 0
    for x in x0 .. x1:
      if not isLit(bgOnly[x, bot], bd): continue
      let sy = bot - dy
      var hasSpr = false
      if sy >= 0 and sy < 224:
        hasSpr = isLit(sprOnly[x, sy], bd)
      # Actually to simulate shift: sample spr at bot-dy for pixel that was at bot
      # shift sprites down by dy means sprite content that was at y is now at y+dy
      # so for gap at bot, check if sprOnly[x, bot-dy] was lit
      if dy != 0:
        let srcY = bot - dy
        hasSpr = srcY >= 0 and srcY < 224 and isLit(sprOnly[x, srcY], bd)
      else:
        hasSpr = isLit(sprOnly[x, bot], bd)
      if not hasSpr: inc gap
    echo &"  dy={dy:+d}: bg bottom row gap pixels (no glow under letter)={gap}"

when isMainModule: main()
