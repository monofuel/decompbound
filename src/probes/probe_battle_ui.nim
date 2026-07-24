## Inspect battle UI-over-BG failure from ebSt PNG or raw state.
import
  std/[os, strformat, options, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, png_state]

proc readRom(p: string): seq[uint8] =
  let d = readFile(p)
  var s = 0
  if d.len mod 1024 == 512: s = 512
  result = newSeq[uint8](d.len - s)
  for i in 0..<result.len: result[i] = d[s+i].uint8

proc main() =
  let path = paramStr(1)
  let snes = newSnesBus(readRom("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  let raw =
    if path.endsWith(".png"):
      extractState(cast[seq[uint8]](readFile(path))).get
    else:
      cast[seq[uint8]](readFile(path))
  deserializeState(raw, snes, cpu)
  let mode = snes.ppuRegs[0x05]
  echo fmt"MODE={mode:02X} low3={mode and 7} bg3prio={(mode and 8)!=0}"
  echo fmt"TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X} TMW={snes.ppuRegs[0x2E]:02X} TSW={snes.ppuRegs[0x2F]:02X}"
  echo fmt"CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X} INIDISP={snes.ppuRegs[0x00]:02X}"
  echo fmt"BG1SC={snes.ppuRegs[0x07]:02X} BG2SC={snes.ppuRegs[0x08]:02X} BG3SC={snes.ppuRegs[0x09]:02X}"
  echo fmt"BG12NBA={snes.ppuRegs[0x0B]:02X} BG34NBA={snes.ppuRegs[0x0C]:02X}"
  echo fmt"BG1V={snes.bgScroll[1]:04X} BG2V={snes.bgScroll[3]:04X} BG3V={snes.bgScroll[5]:04X}"
  # Render full, bg only layers, etc
  let full = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  full.fill(ppu.bgr555ToColor(snes.cgram[0]))
  for line in 0..<224:
    ppu.renderScanline(snes, full, line)
  ppu.renderSprites(snes, full)
  ppu.overlayForegroundBg(snes, full)
  full.writeFile("bin/battle_ui_full.png")

  # Per layer
  for bg in 0..2:
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    img.fill(ColorRGBA(r:0,g:0,b:0,a:255))
    let bpp = if bg == 2: 2 else: 4
    for line in 0..<224:
      ppu.renderBgScanline(snes, img, line, bg, bpp, 0, -1)
    img.writeFile(fmt"bin/battle_ui_bg{bg}.png")
    # high prio only
    let hi = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    hi.fill(ColorRGBA(r:0,g:0,b:0,a:255))
    for line in 0..<224:
      ppu.renderBgScanline(snes, hi, line, bg, bpp, 0, 1)
    hi.writeFile(fmt"bin/battle_ui_bg{bg}_hi.png")
    let lo = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    lo.fill(ColorRGBA(r:0,g:0,b:0,a:255))
    for line in 0..<224:
      ppu.renderBgScanline(snes, lo, line, bg, bpp, 0, 0)
    lo.writeFile(fmt"bin/battle_ui_bg{bg}_lo.png")

  # Sample mid-dialogue region and status band: is purple BG over white text area?
  # Count "purple battle bg-ish" vs "window white" in status band y=160-200
  var purple, white, other = 0
  for y in 160..200:
    for x in 20..100:
      let p = full[x,y]
      if p.r > 100 and p.g < 80 and p.b > 80: inc purple
      elif p.r > 200 and p.g > 200 and p.b > 200: inc white
      else: inc other
  echo fmt"status-band sample purpleish={purple} white={white} other={other}"
  # dialogue box area y=20-50
  purple=0; white=0; other=0
  for y in 20..50:
    for x in 20..200:
      let p = full[x,y]
      if p.r > 80 and p.g < 100 and p.b > 80 and p.r < 200: inc purple
      elif p.r > 180 and p.g > 180 and p.b > 180: inc white
      else: inc other
  echo fmt"dialogue area purpleish={purple} white={white} other={other}"

when isMainModule: main()
