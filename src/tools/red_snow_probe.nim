## Probe the intro Giygas static window: frame packs + VRAM/WRAM fingerprints.
## Matches play.nim's frame budget (InstrPerLine=150, NMI at line 224).
## Output lands under bin/red_snow/ (git-ignored via bin/).

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus]

const
  InstrPerLine = 150
  CaptureFrames = [1200, 1300, 1400, 1500, 1600, 1700, 1800, 1850, 1900, 1950, 2000]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM and strip a 512-byte copier header if present.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len:
    result[i] = data[start + i].uint8

proc vramChecksum(snes: SnesBus, wordStart, wordCount: int): uint32 =
  ## FNV-ish checksum over a VRAM word range (for frame-to-frame compare).
  var h = 2166136261'u32
  let lim = min(wordStart + wordCount, snes.vram.len)
  for i in wordStart ..< lim:
    let w = snes.vram[i]
    h = (h xor (w and 0xFF).uint32) * 16777619'u32
    h = (h xor ((w shr 8) and 0xFF).uint32) * 16777619'u32
  h

proc wram16(snes: SnesBus, off: uint16): uint16 =
  ## Read little-endian u16 from bank $7E.
  let base = 0x7E0000 + off.int
  snes.bus.mem[base].uint16 or (snes.bus.mem[base + 1].uint16 shl 8)

proc wram8(snes: SnesBus, off: uint16): uint8 =
  ## Read u8 from bank $7E.
  snes.bus.mem[0x7E0000 + off.int]

proc analyzeImage(img: Image): (int, int) =
  ## Return (redishPixelCount, litPixelCount).
  var redish = 0
  var lit = 0
  for px in img.data:
    if px.r > 40 and px.r > px.g + 10 and px.r > px.b + 10:
      inc redish
    if px.r.int + px.g.int + px.b.int > 30:
      inc lit
  (redish, lit)

proc writeFingerprint(snes: SnesBus, cpu: Cpu, frameNum: int, img: Image, outDir: string) =
  ## Write text fingerprint next to a captured PNG.
  let (redish, lit) = analyzeImage(img)
  let f = open(outDir / &"frame_{frameNum:04d}.txt", fmWrite)
  f.writeLine(&"frame={frameNum}")
  f.writeLine(&"PC={cpu.pbr:02X}:{cpu.pc:04X} A={cpu.a:04X} X={cpu.x:04X} Y={cpu.y:04X}")
  f.writeLine(&"BGMODE={snes.ppuRegs[0x05] and 7} TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X}")
  f.writeLine(&"CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X} INIDISP={snes.ppuRegs[0x00]:02X}")
  f.writeLine(&"HDMAEN={snes.hdmaen:02X} dmaTransfers={snes.dmaTransfers}")
  f.writeLine(&"BG1HOFS={snes.bgScroll[0]:04X} BG1VOFS={snes.bgScroll[1]:04X}")
  f.writeLine(&"BG2HOFS={snes.bgScroll[2]:04X} BG2VOFS={snes.bgScroll[3]:04X}")
  f.writeLine(&"vram0_2k={vramChecksum(snes, 0, 2048):08X} vram2k_2k={vramChecksum(snes, 2048, 2048):08X}")
  f.writeLine(&"vram4k_2k={vramChecksum(snes, 4096, 2048):08X} vram6k_2k={vramChecksum(snes, 6144, 2048):08X}")
  f.writeLine(&"vram8k_2k={vramChecksum(snes, 8192, 2048):08X} vramA_2k={vramChecksum(snes, 10240, 2048):08X}")
  var cgH = 2166136261'u32
  for i in 0 ..< 256:
    let w = snes.cgram[i]
    cgH = (cgH xor (w and 0xFF).uint32) * 16777619'u32
    cgH = (cgH xor ((w shr 8) and 0xFF).uint32) * 16777619'u32
  f.writeLine(&"cgram_all={cgH:08X}")
  f.writeLine(&"dp00={wram8(snes, 0x00):02X} dp01={wram8(snes, 0x01):02X} dp0D={wram8(snes, 0x0D):02X}")
  f.writeLine(&"dp28={wram8(snes, 0x28):02X} dp2A={wram8(snes, 0x2A):02X} dp2C={wram8(snes, 0x2C):02X}")
  f.writeLine(&"wram0030={wram8(snes, 0x30):02X}")
  f.writeLine(&"redish_pixels={redish} lit_pixels={lit}")
  f.close()
  echo &"captured frame {frameNum}: CGADSUB={snes.ppuRegs[0x31]:02X} redish={redish} vram0={vramChecksum(snes, 0, 2048):08X}"

proc main() =
  ## Boot ROM with play-like timing; render via per-scanline path (HDMA-correct).
  if paramCount() < 1:
    echo "Usage: nim r src/tools/red_snow_probe.nim <rom> [maxFrame]"
    quit(1)
  let romPath = paramStr(1)
  var maxFrame = 2050
  if paramCount() >= 2:
    maxFrame = parseInt(paramStr(2))

  let outDir = "bin/red_snow"
  createDir(outDir)

  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()

  var captureSet: seq[int]
  for f in CaptureFrames:
    if f <= maxFrame:
      captureSet.add(f)

  snes.initHdma()
  var line = 0
  var frameNum = 0
  var nextCap = 0
  var capImage: Image = nil
  var capturing = false

  while frameNum <= maxFrame and not cpu.stopped:
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      cpu.step(snes.bus)
      if cpu.stopped:
        break
    if line < 224:
      snes.runHdma()
      if capturing and (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, capImage, line)
    for k in 0 ..< 2:
      discard snes.tickApu()
    line += 1
    if line >= 262:
      line = 0
      if capturing:
        ppu.renderSprites(snes, capImage)
        ppu.overlayForegroundBg(snes, capImage)
        capImage.writeFile(outDir / &"frame_{frameNum:04d}.png")
        writeFingerprint(snes, cpu, frameNum, capImage, outDir)
        capturing = false
        inc nextCap
      if nextCap < captureSet.len and frameNum + 1 == captureSet[nextCap]:
        # arm capture for the upcoming frame
        capImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
        let backdrop = ppu.bgr555ToColor(snes.cgram[0])
        capImage.fill(backdrop)
        capturing = true
      if frameNum >= 1100 and frameNum <= 2000 and frameNum mod 25 == 0:
        echo &"f={frameNum} CGADSUB={snes.ppuRegs[0x31]:02X} TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X} HDMAEN={snes.hdmaen:02X} BG2V={snes.bgScroll[3]:04X} dma={snes.dmaTransfers}"
      frameNum += 1
      snes.initHdma()

  echo &"done frames={frameNum} captures in {outDir}"

when isMainModule:
  main()
