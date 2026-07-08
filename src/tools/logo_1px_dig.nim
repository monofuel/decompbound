## Dig logo 1px glow gap from ebSt: OAM layout, BG scroll, per-row analysis.
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

proc main() =
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(paramStr(2)))).get, snes, cpu)
  echo &"MODE={snes.ppuRegs[0x05]:02X} TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X}"
  echo &"BG1SC={snes.ppuRegs[0x07]:02X} BG12NBA={snes.ppuRegs[0x0B]:02X} OBSEL={snes.ppuRegs[0x01]:02X}"
  echo &"BG1H={snes.bgScroll[0]:04X} BG1V={snes.bgScroll[1]:04X}"
  echo &"BG2H={snes.bgScroll[2]:04X} BG2V={snes.bgScroll[3]:04X}"
  # Active sprites (not Y=0xE0 offscreen)
  let obsel = snes.ppuRegs[0x01]
  let sizeSelect = (obsel.int shr 5) and 7
  let sizes = case sizeSelect:
    of 0: (8, 16)
    of 1: (8, 32)
    of 2: (8, 64)
    of 3: (16, 32)
    of 4: (16, 64)
    of 5: (32, 64)
    else: (16, 32)
  echo &"OBSEL sizeSelect={sizeSelect} small={sizes[0]} large={sizes[1]}"
  var n = 0
  for sprite in 0 .. 127:
    let base = sprite * 4
    let extra = snes.oam[512 + sprite div 4]
    let extraShift = (sprite mod 4) * 2
    let xHigh = (extra shr extraShift) and 1
    let large = ((extra shr (extraShift + 1)) and 1) != 0
    let y = snes.oam[base + 1].int
    if y >= 224 and y + (if large: sizes[1] else: sizes[0]) <= 256:
      continue
    var x = snes.oam[base].int or (xHigh.int shl 8)
    if x >= 256: x -= 512
    let tile = snes.oam[base + 2]
    let attr = snes.oam[base + 3]
    let prio = (attr shr 4) and 3
    let pal = (attr shr 1) and 7
    let size = if large: sizes[1] else: sizes[0]
    echo &"  spr{sprite:3}: x={x:4} y={y:3} sz={size} tile={tile:02X} attr={attr:02X} prio={prio} pal={pal}"
    inc n
    if n > 40: break
  echo &"active sprites (first 40 listed) count-cap={n}"

  # Render layers separately for gap analysis
  let full = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  full.fill(ppu.bgr555ToColor(snes.cgram[0]))
  for line in 0 ..< 224:
    if (snes.ppuRegs[0x00] and 0x80) == 0:
      ppu.renderScanline(snes, full, line)
  ppu.renderSprites(snes, full)
  full.writeFile("bin/logo_1px_full.png")

  # BG-only (no sprites)
  let bgOnly = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  bgOnly.fill(ppu.bgr555ToColor(snes.cgram[0]))
  let tm = snes.ppuRegs[0x2C]
  snes.ppuRegs[0x2C] = tm and 0x0F  # clear OBJ bit for scanline path - actually composite uses TM
  # renderBg path for mode 3 BG1 only
  let mode = snes.ppuRegs[0x05] and 7
  echo &"mode low3={mode}"
  # restore and use renderScanline without sprites by temporarily clearing TM sprite
  snes.ppuRegs[0x2C] = tm and not 0x10'u8
  for line in 0 ..< 224:
    ppu.renderScanline(snes, bgOnly, line)
  snes.ppuRegs[0x2C] = tm
  bgOnly.writeFile("bin/logo_1px_bg.png")

  # Sprites only on pure backdrop
  let sprOnly = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  sprOnly.fill(ppu.bgr555ToColor(snes.cgram[0]))
  ppu.renderSprites(snes, sprOnly)
  sprOnly.writeFile("bin/logo_1px_spr.png")

  # Find letter bbox from BG (non-backdrop-ish pixels)
  let bd = ppu.bgr555ToColor(snes.cgram[0])
  var minY = 224; var maxY = 0; var minX = 256; var maxX = 0
  for y in 0 ..< 224:
    for x in 0 ..< 256:
      let p = bgOnly[x, y]
      if abs(p.r.int - bd.r.int) + abs(p.g.int - bd.g.int) + abs(p.b.int - bd.b.int) > 30:
        if y < minY: minY = y
        if y > maxY: maxY = y
        if x < minX: minX = x
        if x > maxX: maxX = x
  echo &"BG letter bbox: x={minX}..{maxX} y={minY}..{maxY}"

  # For each y in letter range, count bg-only vs spr-only opaque at bottom rows
  for y in max(0, maxY - 5) .. maxY + 2:
    var bgN = 0; var sprN = 0; var both = 0; var bgOnlyPx = 0
    for x in minX .. maxX:
      let b = bgOnly[x, y]
      let s = sprOnly[x, y]
      let bLit = abs(b.r.int-bd.r.int)+abs(b.g.int-bd.g.int)+abs(b.b.int-bd.b.int) > 30
      let sLit = abs(s.r.int-bd.r.int)+abs(s.g.int-bd.g.int)+abs(s.b.int-bd.b.int) > 30
      if bLit: inc bgN
      if sLit: inc sprN
      if bLit and sLit: inc both
      if bLit and not sLit: inc bgOnlyPx
    echo &"  y={y:3}: bg={bgN:4} spr={sprN:4} both={both:4} bg_without_spr={bgOnlyPx:4}"

when isMainModule: main()
