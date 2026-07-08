## Is orange letter on BG or sprites? Is pale glow on BG or sprites?
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

proc isOrange(p: ColorRGBA): bool =
  p.r > 140 and p.g > 50 and p.b < 130 and p.r.int > p.b.int + 30

proc isGlow(p, bd: ColorRGBA): bool =
  let d = abs(p.r.int-bd.r.int)+abs(p.g.int-bd.g.int)+abs(p.b.int-bd.b.int)
  d > 30 and not isOrange(p) and p.r > 70 and p.g > 50

proc main() =
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(paramStr(2)))).get, snes, cpu)
  let bd = ppu.bgr555ToColor(snes.cgram[0])
  let tm = snes.ppuRegs[0x2C]
  let bg = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  bg.fill(bd)
  snes.ppuRegs[0x2C] = tm and not 0x10'u8
  for line in 0 ..< 224: ppu.renderScanline(snes, bg, line)
  snes.ppuRegs[0x2C] = tm
  let sp = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  sp.fill(bd)
  ppu.renderSprites(snes, sp)

  var oBg, oSp, gBg, gSp = 0
  for y in 60 .. 145:
    for x in 20 .. 235:
      if isOrange(bg[x,y]): inc oBg
      if isOrange(sp[x,y]): inc oSp
      if isGlow(bg[x,y], bd): inc gBg
      if isGlow(sp[x,y], bd): inc gSp
  echo &"orange on BG={oBg} on sprites={oSp}"
  echo &"glow-ish on BG={gBg} on sprites={gSp}"

  # Bottom edge alignment: for each x, lowest orange on BG and on spr
  var bgLower = 0  # BG orange extends below sprite orange
  var spLower = 0
  var same = 0
  for x in 20 .. 235:
    var bBot = -1
    var sBot = -1
    for y in countdown(145, 60):
      if bBot < 0 and isOrange(bg[x,y]): bBot = y
      if sBot < 0 and isOrange(sp[x,y]): sBot = y
      if bBot >= 0 and sBot >= 0: break
    if bBot < 0 or sBot < 0: continue
    if bBot > sBot: inc bgLower
    elif sBot > bBot: inc spLower
    else: inc same
  echo &"columns with both orange: BG lower (sticks out below spr)={bgLower} spr lower={spLower} same={same}"

  # Glow below orange: on BG, is there glow row under letter bottom?
  var glowBelow, noGlowBelow, gap1 = 0
  for x in 20 .. 235:
    var bot = -1
    for y in countdown(145, 60):
      if isOrange(bg[x,y]):
        bot = y
        break
    if bot < 0 or bot >= 222: continue
    # check if glow exists in the soft edge below
    if isGlow(bg[x, bot+1], bd):
      inc glowBelow
    elif isOrange(bg[x, bot+1]):
      discard
    else:
      # backdrop at bot+1 - check bot itself for glow fringe in letter?
      inc noGlowBelow
      # 1px gap pattern: orange, then backdrop, then glow?
      if isGlow(bg[x, bot+2], bd):
        inc gap1
  echo &"BG letter bottom: glow directly below={glowBelow} backdrop directly below={noGlowBelow} (of which glow at +2 = 1px gap)={gap1}"

when isMainModule: main()
