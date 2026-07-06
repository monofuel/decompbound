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
  std/[os, sequtils, strformat, strutils],
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
  ## Collect runs of printable ASCII from actual BG nametables using the
  ## BGxSC registers to locate tilemaps. Handles common mappings:
  ## tile index == ASCII directly (most common for these tests; ' ' at tile 0x20)
  ## or tile == ascii-0x20. Extracts full row strings (trimmed) so "Failed",
  ## "Passed", test names are captured reliably regardless of row position.
  var pieces: seq[string] = @[]
  let tm = snes.ppuRegs[0x2C]
  let ts = snes.ppuRegs[0x2D]
  let enabled = tm or ts

  proc addTrimmed(s: string) =
    let t = s.strip()
    if t.len >= 3:
      let lp = t.toLowerAscii()
      let hasLetter = lp.anyIt(it in {'a'..'z'})
      # require at least one letter-run of length 2+ to drop lll / d8 garbage while keeping words
      var hasWord = false
      for i in 0..<lp.len-1:
        if lp[i] in {'a'..'z'} and lp[i+1] in {'a'..'z'}: hasWord = true
      if t notin pieces and (hasWord or "pass" in lp or "fail" in lp or "done" in lp or "test" in lp or "press" in lp or "running" in lp or "gradient" in lp or "echo" in lp):
        pieces.add t

  # Scan enabled BGs using their map bases (primary source)
  for bg in 0..3:
    if ((enabled and (1'u8 shl bg)) == 0'u8): continue
    let scReg = snes.ppuRegs[0x07 + bg].int
    let tilemapBase = ((scReg shr 2) shl 10) and 0x7FFF
    let sizeBits = scReg and 3
    let wScreens = if (sizeBits and 1) != 0: 2 else: 1
    let hScreens = if (sizeBits and 2) != 0: 2 else: 1
    for sy in 0..<hScreens:
      for sx in 0..<wScreens:
        let mb = tilemapBase + sx * 0x400 + sy * (if sizeBits == 3: 0x800 else: 0x400)
        for row in 0..<32:
          var run = ""
          for col in 0..<32:
            let wi = (mb + row * 32 + col) and 0x7FFF
            if wi >= snes.vram.len: continue
            let entry = snes.vram[wi]
            let tile = (entry and 0x03FF).int
            var ch = '\0'
            if tile >= 0x20 and tile <= 0x7E:
              ch = char(tile)
            elif tile >= 0 and tile <= 0x5E:
              ch = char(tile + 0x20)
            if ch >= ' ' and ch <= '~':
              run.add ch
            else:
              addTrimmed(run)
              run = ""
          addTrimmed(run)

  # Fallback scan on common bases (helps if BG regs not yet set or multi-map)
  const FallbackBases = [0, 0x400, 0x800, 0xC00, 0x1000, 0x1C00, 0x2000]
  for base in FallbackBases:
    for row in 0..<32:
      var run = ""
      for col in 0..<32:
        let wi = (base + row*32 + col) and 0x7FFF
        if wi >= snes.vram.len: break
        let entry = snes.vram[wi]
        let tile = (entry and 0x03FF).int
        var ch = '\0'
        if tile >= 0x20 and tile <= 0x7E:
          ch = char(tile)
        elif tile >= 0 and tile <= 0x5E:
          ch = char(tile + 0x20)
        if ch >= ' ' and ch <= '~':
          run.add ch
        else:
          addTrimmed(run)
          run = ""
      addTrimmed(run)

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
  echo &"BGSCs: 1=${snes.ppuRegs[0x07]:02X} 2=${snes.ppuRegs[0x08]:02X} 3=${snes.ppuRegs[0x09]:02X} 4=${snes.ppuRegs[0x0A]:02X}"
  echo &"Status byte @ $7E:6000 = ${status:02X}  region[8]={statusRegion}"
  echo &"Screen-text (tilemap ascii runs): {screenText}"

  # BG map info + result text lines (kept concise)
  block bgInfo:
    let enabled = snes.ppuRegs[0x2C] or snes.ppuRegs[0x2D]
    var shown = false
    for bg in 0..3:
      if shown: break
      if ((enabled and (1'u8 shl bg)) == 0'u8): continue
      let sc = snes.ppuRegs[0x07 + bg].int
      let base = ((sc shr 2) shl 10) and 0x7FFF
      echo &"Active BG{bg} mapBase=${base:04X} (sc=${sc:02X})"
      # Show any rows containing pass/fail or test names (the key result indicators)
      for row in 0..<32:
        var dec = ""
        for col in 0..<32:
          let wi = (base + row*32 + col) and 0x7FFF
          let tile = (snes.vram[wi] and 0x03FF).int
          if tile >= 0x20 and tile <= 0x7E:
            dec.add char(tile)
          else:
            dec.add "."
        let ldec = dec.toLowerAscii()
        var letterCount = 0
        for c in dec:
          if c in {'A'..'Z', 'a'..'z'}: inc letterCount
        if "fail" in ldec or "pass" in ldec or "done" in ldec or "test_" in ldec or "test " in ldec:
          echo &"  row{row}: {dec.strip()}"
      shown = true

  # Scan additional WRAM locations for status/result (some tests use variants)
  var altStatus: uint8 = 0
  var wramResults: seq[string] = @[]
  for off in [0x6000'u32, 0x5FFC'u32, 0x6010'u32, 0x6100'u32, 0x2000'u32]:
    let waddr = 0x7E0000'u32 + off
    let b = if waddr.int < snes.bus.mem.len: snes.bus.mem[waddr.int] else: 0'u8
    if b != 0 and altStatus == 0: altStatus = b
    # also collect short ascii at alt locations
    var run = ""
    for i in 0..<16:
      let bb = if (waddr + i.uint32).int < snes.bus.mem.len: snes.bus.mem[(waddr + i.uint32).int] else: 0
      if bb >= 0x20'u8 and bb <= 0x7E'u8:
        run.add bb.char
      else:
        if run.len >= 3: wramResults.add run
        run = ""
    if run.len >= 3: wramResults.add run
  if altStatus != 0:
    echo &"Alt status near 7E:6000 variants: ${altStatus:02X}"
  if wramResults.len > 0:
    echo &"WRAM result strings: {wramResults.join(\" | \")}"

  let lower = screenText.toLowerAscii()
  # Incorporate alt status from nearby addrs as some test ports differ
  let effStatus = if status != 0: status else: altStatus
  var verdict = "UNKNOWN"
  if "failed" in lower or "fail" in lower:
    verdict = "FAIL"
  elif "passed" in lower or "pass" in lower or "done" in lower:
    verdict = "PASS"
  elif effStatus != 0:
    verdict = "FAIL"
  # Also surface explicit wram strings if they contain verdict words
  for r in wramResults:
    let rl = r.toLowerAscii()
    if ("fail" in rl or "error" in rl) and verdict != "PASS": verdict = "FAIL"
    elif ("pass" in rl or "done" in rl) and verdict == "UNKNOWN": verdict = "PASS"
  echo &"VERDICT: {verdict}"
  echo &"raw status bytes: ${status:02X} (eff=${effStatus:02X}; 0=pass/done-ok or untouched, non-zero=fail; screen-text is primary for these ROMs)"

  echo &"Executed {executed} instructions (~{frameNum} frames)."

when isMainModule:
  main()
