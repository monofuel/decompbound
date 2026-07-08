## Render a state; dump top 4 scanlines pixel uniqueness + OAM/BG notes.
import
  std/[os, strformat, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state]

proc readRom(p: string): seq[uint8] =
  let d = readFile(p)
  var s = 0
  if d.len mod 1024 == 512: s = 512
  result = newSeq[uint8](d.len - s)
  for i in 0..<result.len: result[i] = d[s+i].uint8

proc main() =
  let path = if paramCount() >= 1: paramStr(1) else: "bin/states/slot1_battle.state"
  let snes = newSnesBus(readRom("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  echo fmt"MODE={snes.ppuRegs[0x05]:02X} TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X} INIDISP={snes.ppuRegs[0x00]:02X}"
  echo fmt"BG1V={snes.bgScroll[1]:04X} BG2V={snes.bgScroll[3]:04X} BG3V={snes.bgScroll[5]:04X}"
  echo fmt"HDMAEN={snes.ppuRegs[0x0C]:02X}"  # wrong reg - HDMAEN is 0x420C via cpuio
  # render full frame via scanlines
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  img.fill(ppu.bgr555ToColor(snes.cgram[0]))
  for line in 0 ..< 224:
    ppu.renderScanline(snes, img, line)
  ppu.renderSprites(snes, img)
  img.writeFile("bin/topline_full.png")
  # per-row unique color count for y=0..7
  for y in 0 .. 7:
    var seen: CountTable[int]
    for x in 0 ..< 256:
      let p = img[x, y]
      seen.inc(p.r.int shl 16 or p.g.int shl 8 or p.b.int)
    echo fmt"y={y}: unique_colors={seen.len} first_px=({img[0,y].r},{img[0,y].g},{img[0,y].b}) mid=({img[128,y].r},{img[128,y].g},{img[128,y].b})"
  # also BG-only top
  let bg = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  bg.fill(ppu.bgr555ToColor(snes.cgram[0]))
  let tm = snes.ppuRegs[0x2C]
  snes.ppuRegs[0x2C] = tm and not 0x10'u8
  for line in 0 ..< 8:
    ppu.renderScanline(snes, bg, line)
  snes.ppuRegs[0x2C] = tm
  bg.writeFile("bin/topline_bg8.png")
  # sprites only
  let sp = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  sp.fill(ColorRGBA(r:0,g:0,b:0,a:255))
  ppu.renderSprites(snes, sp)
  # count lit on y=0
  var lit0, lit1 = 0
  for x in 0..<256:
    let p0 = sp[x,0]
    let p1 = sp[x,1]
    if p0.r.int+p0.g.int+p0.b.int > 10: inc lit0
    if p1.r.int+p1.g.int+p1.b.int > 10: inc lit1
  echo fmt"sprite-lit pixels y0={lit0} y1={lit1}"
  sp.writeFile("bin/topline_spr.png")
  # crop top 8 rows x3 scale for viewing
  let crop = newImage(256, 8)
  for y in 0..7:
    for x in 0..255:
      crop[x,y] = img[x,y]
  crop.writeFile("bin/topline_crop8.png")

when isMainModule: main()
