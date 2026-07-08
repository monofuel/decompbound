## Capture intro frames around red-snow → war-card transition (play timing).
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus]

const InstrPerLine = 150

proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512: start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8

proc main() =
  if paramCount() < 1:
    echo "Usage: nim r src/tools/fade_trans_probe.nim <rom>"
    quit(1)
  let outDir = "bin/fade_trans"
  createDir(outDir)
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  snes.initHdma()
  var line = 0
  var frameNum = 0
  # dense pack around the known CGADSUB drop (~1600-1650 at IPL=150)
  let captures = [1550, 1580, 1600, 1610, 1620, 1630, 1640, 1650, 1660, 1680, 1700, 1750]
  var next = 0
  var capImg: Image = nil
  var capturing = false
  var prevCg = -1
  while frameNum <= 1800 and not cpu.stopped:
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      cpu.step(snes.bus)
    if line < 224:
      snes.runHdma()
      if capturing and (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, capImg, line)
    for k in 0 ..< 2: discard snes.tickApu()
    line += 1
    if line >= 262:
      line = 0
      let cg = snes.ppuRegs[0x31].int
      let ini = snes.ppuRegs[0x00]
      let tm = snes.ppuRegs[0x2C]
      let ts = snes.ppuRegs[0x2D]
      let cgsel = snes.ppuRegs[0x30]
      if cg != prevCg or (frameNum >= 1550 and frameNum <= 1700 and frameNum mod 10 == 0):
        echo &"f={frameNum} INIDISP={ini:02X} CGADSUB={cg:02X} CGWSEL={cgsel:02X} TM={tm:02X} TS={ts:02X} HDMAEN={snes.hdmaen:02X} BG2H={snes.bgScroll[2]:04X}"
        prevCg = cg
      if capturing:
        ppu.renderSprites(snes, capImg)
        ppu.overlayForegroundBg(snes, capImg)
        capImg.writeFile(outDir / &"f{frameNum:04d}.png")
        # crude yellow/green pixel count
        var yg = 0
        var lit = 0
        for px in capImg.data:
          if px.r.int + px.g.int + px.b.int > 40: inc lit
          if px.g > 40 and px.g >= px.r and px.g >= px.b: inc yg
          elif px.r > 40 and px.g > 40 and px.b < px.r and px.b < px.g: inc yg
        echo &"  captured f{frameNum}: lit={lit} yellowgreenish={yg}"
        capturing = false
        inc next
      if next < captures.len and frameNum + 1 == captures[next]:
        capImg = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
        capImg.fill(ppu.bgr555ToColor(snes.cgram[0]))
        capturing = true
      frameNum += 1
      snes.initHdma()
  echo "done -> ", outDir

when isMainModule: main()
