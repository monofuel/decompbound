## Load ebSt, run one frame of HDMA+scanline render (play-accurate).
import
  std/[os, options, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, png_state, save_state]

const InstrPerLine = 150

proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512: start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8

proc main() =
  if paramCount() < 3:
    echo "Usage: nim r src/tools/rerender_state.nim <rom> <png> <out.png>"
    quit(1)
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(paramStr(2)))).get, snes, cpu)
  echo &"INIDISP={snes.ppuRegs[0x00]:02X} CGAD={snes.ppuRegs[0x31]:02X} TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X}"
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  img.fill(ppu.bgr555ToColor(snes.cgram[0]))
  snes.initHdma()
  for line in 0 ..< 224:
    snes.runHdma()
    if (snes.ppuRegs[0x00] and 0x80) == 0:
      ppu.renderScanline(snes, img, line)
  ppu.renderSprites(snes, img)
  ppu.overlayForegroundBg(snes, img)
  img.writeFile(paramStr(3))
  var lit=0; var red=0; var yg=0; var dark=0
  for px in img.data:
    let s = px.r.int+px.g.int+px.b.int
    if s < 30: inc dark
    if s > 40: inc lit
    if px.r > 50 and px.r > px.g+15 and px.r > px.b+15: inc red
    if px.g > 50 and px.g+5 >= px.r and px.g >= px.b: inc yg
  echo &"wrote {paramStr(3)} dark={dark} lit={lit} redish={red} greenish={yg}"

when isMainModule: main()
