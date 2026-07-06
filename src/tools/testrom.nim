## Headless SNES test-ROM runner.
## Boots any ROM (detects LoROM/HiROM via existing snesbus), executes up to N frames
## using the same scanline + NMI + APU + HDMA loop as the screenshot harness,
## then reports test result using two conventions and dumps final frame PNG.
## 
## Blargg-style memory result: watches a status/result code byte at $7E:6000
## (standard convention used by Blargg's test ROMs and ports across NES/GB/SNES;
## 0 often signals pass or "tests finished with no error", non-zero is first failing
## test number or error code; some tests also place a short result string at $7E:6004+).
## 
## Screen-text style: final frame is rendered to bin/testrom_frame.png; additionally
## the VRAM tilemaps are scanned for runs of printable ASCII values used directly
## as tile indices (common pattern in result screens of Blargg, 240p, gradient etc).
## 
## Usage: nim r src/tools/testrom.nim <rom> [frames]
##   frames: approximate frame count to run (default 250). Use small values for
##           quick smoke, larger (e.g. 2000) for slow-booting tests.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus]

const
  InstructionsPerFrame = 8000
  DefaultMaxFrames = 250
  ## WRAM location watched for Blargg-style result code.
  ## Documented convention (Blargg family): byte at $7E:6000 holds primary status
  ## (0 often = pass / finished ok; non-zero = first failing test id or error).
  ## A follow-up result string region is sometimes present starting near $7E:6004;
  ## we also surface raw bytes. Screen text (ascii tile indices) is the other
  ## reliable channel for these ROMs.
  ResultStatusAddr = 0x7E6000'u32
  FrameDumpPath = "bin/testrom_frame.png"

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc collectAsciiFromTilemaps(snes: SnesBus): string =
  ## Collect runs of printable ASCII present as tile indices inside common
  ## VRAM tilemap bases. Many test ROMs (Blargg et al.) draw their PASS/FAIL
  ## text by storing character codes directly in the nametables.
  const Bases = [0, 0x400, 0x800, 0xC00, 0x1000, 0x1C00]
  var pieces: seq[string] = @[]
  for base in Bases:
    var run = ""
    for i in 0..<1024:
      let wi = base + i
      if wi >= snes.vram.len:
        break
      let t = snes.vram[wi].int
      if t >= 0x20 and t <= 0x7E:
        run.add t.char
      else:
        if run.len >= 4:
          pieces.add run
        run = ""
    if run.len >= 4:
      pieces.add run
  result = pieces.join(" | ")

proc main() =
  ## Parse args, boot via snesbus (LoROM supported automatically), run frames,
  ## read both result conventions, print verdict + raw bytes, dump frame.
  if paramCount() < 1:
    echo "Usage: nim r src/tools/testrom.nim <rom> [frames]"
    quit(1)

  # Collect positional args, skipping any leading "--" passed by nim c -r.
  var args: seq[string] = @[]
  for i in 1..paramCount():
    let a = paramStr(i)
    if a == "--": continue
    args.add a

  if args.len < 1:
    echo "Usage: nim r src/tools/testrom.nim <rom> [frames]"
    quit(1)

  let romPath = args[0]
  var maxFrames = DefaultMaxFrames
  if args.len >= 2:
    let arg = args[1]
    if arg.startsWith("--frames="):
      maxFrames = parseInt(arg.split('=')[1])
    else:
      maxFrames = parseInt(arg)

  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()

  var executed = 0
  var line = 0
  var frameNum = 0
  let maxInstructions = maxFrames * InstructionsPerFrame

  let image = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let backdrop = ppu.bgr555ToColor(snes.cgram[0])
  image.fill(backdrop)
  snes.initHdma()

  const InstrPerLine = 30
  while executed < maxInstructions and not cpu.stopped:
    for i in 0..<InstrPerLine:
      if (snes.nmitimen and 0x80) != 0 and line == 240 and i == 0:
        cpu.nmiPending = true
      cpu.step(snes.bus)
      executed += 1
      if executed >= maxInstructions or cpu.stopped:
        break
    for k in 0 ..< 2:
      discard snes.tickApu()
    if line < 224:
      snes.runHdma()
      if (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, image, line)
    line += 1
    if line >= 262:
      line = 0
      frameNum += 1
      snes.initHdma()

  ppu.renderSprites(snes, image)
  ppu.overlayForegroundBg(snes, image)

  createDir("bin")
  image.writeFile(FrameDumpPath)

  let status = snes.bus.mem[ResultStatusAddr.int]
  var statusRegion = ""
  for i in 0..<8:
    if i > 0: statusRegion.add " "
    statusRegion.add toHex(snes.bus.mem[(ResultStatusAddr + i.uint32).int], 2)
  let screenText = collectAsciiFromTilemaps(snes)

  echo &"Frame dumped to {FrameDumpPath}"
  echo &"BGMODE={snes.ppuRegs[0x05] and 7} TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X} INIDISP={snes.ppuRegs[0x00]:02X}"
  echo &"Status byte @ $7E:6000 = ${status:02X}  region[8]={statusRegion}"
  echo &"Screen-text (tilemap ascii runs): {screenText[0 ..< min(screenText.len, 240)]}"

  let lower = screenText.toLowerAscii()
  var verdict = "UNKNOWN"
  if "passed" in lower:
    verdict = "PASS"
  elif "failed" in lower or "fail" in lower:
    verdict = "FAIL"
  elif status != 0:
    verdict = "FAIL"
  echo &"VERDICT: {verdict}"
  echo &"raw status bytes: ${status:02X} (Blargg convention: 0=pass/done-ok or untouched, non-zero=fail code or first-fail id; screen text provides the human label)"

  echo &"Executed {executed} instructions (~{frameNum} frames)."

when isMainModule:
  main()
