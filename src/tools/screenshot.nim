## Boots a ROM on the emulator and renders the PPU state to a PNG.
## Milestone 4 probe: what does Earthbound actually show?
## Usage: nim r src/tools/screenshot.nim <rom> <out.png> [instructions|frame:N] [noinput]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus]

const
  # Must match play.nim budget so frame:N lands on the same scene.
  InstrPerLine = 150
  InstructionsPerFrame = InstrPerLine * 262  # ~39300
  DefaultMaxInstructions = 2_000_000

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc main() =
  ## Boot ROM on emulator for the requested number of instructions and write PPU render to PNG.
  if paramCount() < 2:
    echo "Usage: nim r src/tools/screenshot.nim <rom> <out.png> [instructions|frame:N] [noinput]"
    quit(1)

  var
    maxInstructions = DefaultMaxInstructions
    noInput = false
  if paramCount() >= 3:
    let third = paramStr(3)
    if third == "noinput":
      noInput = true
    elif third.startsWith("frame:"):
      let frameNum = parseInt(third[6..^1])
      maxInstructions = frameNum * InstructionsPerFrame
    else:
      maxInstructions = parseInt(third)
  if paramCount() >= 4 and paramStr(4) == "noinput":
    noInput = true

  let rom = readRomFile(paramStr(1))
  let snes = newSnesBus(rom)
  snes.recordMmioTrace = true  # this tool reports hdmaWrites; opt into the trace.
  var cpu = snes.resetCpu()

  var executed = 0
  var line = 0
  var frameNum = 0
  let image = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let backdrop = ppu.bgr555ToColor(snes.cgram[0])
  image.fill(backdrop)
  snes.initHdma()
  while executed < maxInstructions and not cpu.stopped:
    snes.setScanline(line)
    if (snes.nmitimen and 0x80) != 0 and line == 224:
      cpu.nmiPending = true
      snes.raiseNmi()
      if not noInput:
        # Press Start as an EDGE: held ~8 frames, released ~112. A permanently
        # held button never re-triggers a "press Start" advance, so we must
        # release between presses to walk attract -> title -> file-select menu.
        snes.joy1 = if frameNum mod 120 < 8: 0x1000'u16 else: 0
    for i in 0..<InstrPerLine:
      cpu.step(snes.bus)
      executed += 1
      if executed >= maxInstructions or cpu.stopped:
        break
    # Advance the live APU (~2 samples/scanline ~= 533/frame) so the game's
    # boot handshake and sound driver run in step with the main CPU.
    for k in 0 ..< 2:
      discard snes.tickApu()
    if line < 224:
      snes.runHdma()
      # Composited per-line render (post-HDMA state): main + subscreen color
      # math + brightness, so effects like the Giygas red static appear.
      if (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, image, line)
    line += 1
    if line >= 262:
      line = 0
      frameNum += 1
      snes.initHdma()

  # Sprites from final state (typically updated in vblank)
  ppu.renderSprites(snes, image)
  # High-priority BG3 (dialogue/HUD) draws over sprites.
  ppu.overlayForegroundBg(snes, image)
  image.writeFile(paramStr(2))
  echo &"Screenshot written to {paramStr(2)}"
  echo &"BGMODE={snes.ppuRegs[0x05] and 7} TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X} INIDISP={snes.ppuRegs[0x00]:02X}"
  echo &"CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X} COLDATA(last)={snes.ppuRegs[0x32]:02X} fixedR={snes.fixedColorR} G={snes.fixedColorG} B={snes.fixedColorB}"
  echo &"HDMAEN={snes.hdmaen:02X} hdmaBbusWrites={snes.hdmaWrites.len}"

when isMainModule:
  main()
