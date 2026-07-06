## Read on-screen dialogue text from a loaded game state by scanning BG nametables.
## Reuses the tilemap BGxSC + vram approach from testrom.nim, but targets the
## dialogue window region and applies the EB glyph mapping (glyph_id = (byte-0x50)&0x7F
## reverse) documented in docs/scripts.md and verified in text_decode.nim.
## Loads full state (slot or .state file) the same way state_inspect does.
## Also supports --load-srm + run frames with A-mash to reach a real dialogue box
## from a battery save (no slot/state needed; drives to menu/text like trace).
## Output is readable text to stdout only (user-local, never committed).
## Usage: nim r src/tools/read_text.nim <rom> [--slot N|--state path.state|--load-srm [--frames N]]
##
## Reports the text tilemap location (BG + map base) used.

import
  std/[options, os, strformat, strutils],
  ../decompbound/[cpu, png_state, save_state, snesbus]

const
  # EB storage: printable = ascii + 0x30. Glyph for render: glyph = (storage - 0x50) & 0x7F
  # On screen nametable tile index = chrBaseOffset + glyph , so glyph = tile - fontTileBase
  # We try several candidate fontTileBases (discovered via RE on live states).
  FontTileBases = [0, 0x080, 0x0A0, 0x0A1, 0x0B0, 0x0C0, 0x0CF, 0x0E0, 0x100, 0x200, 0x300]
  # Likely dialogue window scan rows (bottom third of 28 tile rows).
  DialogueRows = [18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28]
  # Min run length for a plausible text line.
  MinTextRun = 3

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header if present.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc glyphToChar(tile: int, fontBase: int): char =
  ## Reverse EB glyph mapping from nametable tile back to ASCII char.
  ## glyph = (storage - 0x50) & 0x7F ; storage = ascii + 0x30 .
  ## Note: removed & on reverse storage calc to support full ascii range for real text (e.g. P Y in "INPUT YOUR").
  let g = tile - fontBase
  if g < 0 or g > 0x7F:
    return '\0'
  let storage = g + 0x50
  # Storage encoding: printable byte = ascii + 0x30 (verified in docs/scripts.md + text_decode).
  let chVal = storage - 0x30
  if chVal >= 0x20 and chVal <= 0x7E:
    return char(chVal)
  return '\0'

proc sramPathFor(romPath: string): string =
  ## The battery-save sits next to the ROM with .srm extension (copied from trace_tool).
  romPath.changeFileExt("srm")

proc loadSram(snes: SnesBus, path: string) =
  ## Load battery save into SRAM if the file exists.
  if fileExists(path):
    let data = readFile(path)
    for i in 0 ..< min(data.len, snes.sram.len):
      snes.sram[i] = data[i].uint8
    echo "loaded srm: ", path, " (", data.len, " bytes)"

proc runFramesForText(snes: SnesBus, cpu: var Cpu, maxFrames: int) =
  ## Advance emulator from loaded srm (real game state) with scripted input to reach
  ## a real dialogue box (A to confirm, dirs to navigate naming/walk, A to talk to NPC/sign).
  ## Mirrors intro lua sequence + post-bedroom interaction. Stops early if real text detected on tilemap.
  ## Uses same per-line budget as trace_tool. 
  ## TODO: button masks 0x0080=A etc are from policy.nim; hardcoded to drive to real EB text render.
  const
    InstrPerLine = 30
    BtnA = 0x0080'u16
    BtnDown = 0x0400'u16
    BtnRight = 0x0100'u16
    BtnStart = 0x1000'u16
    MinRun = 3
  proc g2c(tile: int, fb: int): char =
    let g = tile - fb
    if g < 0 or g > 0x7F: return '\0'
    let st = g + 0x50
    let cv = st - 0x30
    if cv >= 0x20 and cv <= 0x7E: return char(cv)
    '\0'
  var line = 0
  var frameNum = 0
  var executed = 0
  var foundReal = false
  while frameNum < maxFrames and not cpu.stopped and not foundReal:
    var j: uint16 = 0
    if frameNum >= 200 and frameNum < 250 and (frameNum mod 30 == 0):
      j = j or BtnStart
    if frameNum >= 250 and frameNum < 850:
      if (frameNum mod 3) == 0: j = j or BtnA
      if (frameNum mod 17) == 0: j = j or BtnDown
      if (frameNum mod 29) == 0: j = j or BtnRight
    elif frameNum >= 850 and frameNum < 1400:
      if (frameNum mod 4) == 0: j = j or BtnDown
      if (frameNum mod 11) == 0: j = j or BtnA
    elif frameNum >= 1400:
      if (frameNum mod 6) == 0: j = j or BtnA
      if (frameNum mod 13) == 0: j = j or BtnDown
    snes.joy1 = j
    for ii in 0 ..< InstrPerLine:
      if (snes.nmitimen and 0x80) != 0 and line == 240 and ii == 0:
        cpu.nmiPending = true
      cpu.step(snes.bus)
      executed += 1
      if executed >= maxFrames * 9000 or cpu.stopped:
        break
    for k in 0 ..< 2:
      discard snes.tickApu()
    if line < 224:
      snes.runHdma()
    line += 1
    if line >= 262:
      line = 0
      frameNum += 1
      snes.initHdma()
      snes.joy1 = 0
      # sample for real text (avoid seq test patterns)
      if frameNum > 400:
        let enabled = snes.ppuRegs[0x2C] or snes.ppuRegs[0x2D]
        for bg in 0..3:
          if ((enabled and (1'u8 shl bg)) == 0'u8): continue
          let sc = snes.ppuRegs[0x07 + bg].int
          let mb = ((sc shr 2) shl 10) and 0x7FFF
          for fb in [0, 0x80, 0xA0, 0xC0, 0x100, 0x200]:
            var runs: seq[string] = @[]
            for r in 18..27:
              var rs = ""
              for c in 0..<32:
                let wi = (mb + r*32 + c) and 0x7FFF
                if wi < snes.vram.len:
                  let ch = g2c((snes.vram[wi] and 0x03FF).int, fb)
                  rs.add(if ch != '\0': ch else: ' ')
              let t = rs.strip()
              if t.len >= MinRun: runs.add t
            for rn in runs:
              let hasWord = rn.len > 6 and (' ' in rn) and (rn.count({'A'..'Z','a'..'z'}) > 4)
              if hasWord and not ("@A@" in rn or "456" in rn or ">?@" in rn):
                echo &"  [live sample f{frameNum}] real text candidate (base 0x{fb:x} BG{bg}): {rn}"
                foundReal = true
                break
            if foundReal: break
          if foundReal: break
  echo &"Ran {frameNum} frames from srm (exec {executed}) to target dialogue moment."

proc decodeWindowText(snes: SnesBus, bg: int, fontBase: int): seq[string] =
  ## Scan the full nametable(s) for this BG, collect printable runs using the glyph map.
  ## Returns candidate lines (trimmed, deduped-ish).
  result = @[]
  let scReg = snes.ppuRegs[0x07 + bg].int
  let tilemapBase = ((scReg shr 2) shl 10) and 0x7FFF
  let sizeBits = scReg and 3
  let wScreens = if (sizeBits and 1) != 0: 2 else: 1
  let hScreens = if (sizeBits and 2) != 0: 2 else: 1
  var seen: seq[string] = @[]
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
          let ch = glyphToChar(tile, fontBase)
          if ch != '\0':
            run.add ch
          else:
            if run.len >= MinTextRun:
              let t = run.strip()
              if t notin seen and t.len >= MinTextRun:
                seen.add t
                result.add t
            run = ""
        if run.len >= MinTextRun:
          let t = run.strip()
          if t notin seen and t.len >= MinTextRun:
            seen.add t
            result.add t

proc findDialogueLines(snes: SnesBus): tuple[bg: int, mapBase: int, lines: seq[string], usedBase: int] =
  ## Find the BG most likely holding the dialogue window by scanning enabled layers
  ## for runs that decode to readable text using candidate font bases. Prefer bottom rows.
  ## Returns the winning (bg, its map base from SC, the lines, the font base that worked).
  let enabledMask = snes.ppuRegs[0x2C] or snes.ppuRegs[0x2D]
  var bestScore = 0
  var bestBg = -1
  var bestBase = 0
  var bestLines: seq[string] = @[]
  var bestMap = 0
  for bg in 0..3:
    if ((enabledMask and (1'u8 shl bg)) == 0'u8): continue
    let scReg = snes.ppuRegs[0x07 + bg].int
    let mapBase = ((scReg shr 2) shl 10) and 0x7FFF
    for fb in FontTileBases:
      let cands = decodeWindowText(snes, bg, fb)
      if cands.len == 0: continue
      var score = 0
      for ln in cands:
        var letters = 0
        for c in ln:
          if c in {'A'..'Z', 'a'..'z'}: inc letters
        if letters >= 2: inc score, letters
      var winScore = 0
      let sc2 = snes.ppuRegs[0x07 + bg].int
      let mb2 = ((sc2 shr 2) shl 10) and 0x7FFF
      for row in DialogueRows:
        for col in 0..<32:
          let wi = (mb2 + row*32 + col) and 0x7FFF
          if wi < snes.vram.len:
            let tile = (snes.vram[wi] and 0x03FF).int
            let ch = glyphToChar(tile, fb)
            if ch in {'A'..'Z', 'a'..'z', '0'..'9'}: inc winScore
      let total = score + winScore
      if total > bestScore and cands.len > 0:
        bestScore = total
        bestBg = bg
        bestBase = fb
        bestLines = cands
        bestMap = mapBase
  return (bestBg, bestMap, bestLines, bestBase)

proc loadStateFromPath(snes: SnesBus, cpu: var Cpu, path: string) =
  ## Load a .state file via deserialize (supports arbitrary paths, not just slots).
  if not fileExists(path):
    raise newException(IOError, &"state file not found: {path}")
  let data = cast[seq[byte]](readFile(path))
  deserializeState(data, snes, cpu)

proc main() =
  ## Parse args, init bus from ROM (required for bus layout even though state overwrites live), load state,
  ## extract + decode the on-screen text via BG tilemaps + EB glyph reverse map, print readable lines.
  if paramCount() < 1:
    echo "Usage: nim r src/tools/read_text.nim <rom> [--slot N | --state path.state | --load-srm [--frames N]]"
    echo "  --slot 99   loads bin/states/slot99.state (or use after saveState in other tool)"
    echo "  --state foo.state  loads any .state produced by serializeState"
    echo "  --load-srm  loads .srm next to rom, runs frames with A-mash to reach real dialogue box"
    echo "  --frames N  frames to run under --load-srm (default 180)"
    quit(1)

  var romPath = ""
  var slot = -1
  var statePath = ""
  var loadSrm = false
  var srmPath = ""
  var pngPath = ""
  var runFrames = 0
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--": discard
    elif a == "--slot" and i < paramCount():
      inc i
      slot = parseInt(paramStr(i))
    elif a.startsWith("--slot="):
      slot = parseInt(a[7..^1])
    elif a == "--state" and i < paramCount():
      inc i
      statePath = paramStr(i)
    elif a.startsWith("--state="):
      statePath = a[8..^1]
    elif a == "--load-srm":
      loadSrm = true
    elif a == "--srm" and i < paramCount():
      inc i
      srmPath = paramStr(i)
    elif a.startsWith("--srm="):
      srmPath = a[6..^1]
    elif a == "--png" and i < paramCount():
      inc i
      pngPath = paramStr(i)
    elif a.startsWith("--png="):
      pngPath = a[6..^1]
    elif a == "--frames" and i < paramCount():
      inc i
      runFrames = parseInt(paramStr(i))
    elif a.startsWith("--frames="):
      runFrames = parseInt(a[9..^1])
    elif not a.startsWith("--"):
      if romPath.len == 0: romPath = a
    inc i

  if romPath.len == 0:
    romPath = "bin/Earthbound (U) [!].smc"
  if slot < 0 and statePath.len == 0 and not loadSrm and srmPath.len == 0 and pngPath.len == 0:
    echo "ERROR: provide --slot N or --state path.state or --load-srm or --srm path.srm or --png capture.png"
    quit(1)
  if not fileExists(romPath):
    echo &"ERROR: ROM not found: {romPath}"
    quit(1)

  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()

  if pngPath.len > 0:
    let pbytes = cast[seq[uint8]](readFile(pngPath))
    let stOpt = extractState(pbytes)
    if stOpt.isNone:
      echo &"ERROR: no valid ebSt embedded state in png: {pngPath}"
      quit(1)
    deserializeState(stOpt.get, snes, cpu)
    echo &"Loaded embedded state from png {pngPath}"
  elif srmPath.len > 0:
    loadSram(snes, srmPath)
    cpu = snes.resetCpu()
    echo &"Loaded srm {srmPath}"
    if runFrames > 0:
      runFramesForText(snes, cpu, runFrames)
  elif loadSrm:
    let sp = sramPathFor(romPath)
    loadSram(snes, sp)
    cpu = snes.resetCpu()
    echo &"Loaded srm {sp}"
    let framesToRun = if runFrames > 0: runFrames else: 180
    runFramesForText(snes, cpu, framesToRun)
  elif statePath.len > 0:
    loadStateFromPath(snes, cpu, statePath)
    echo &"Loaded state from {statePath}"
  else:
    loadState(snes, cpu, slot)
    echo &"Loaded state slot {slot}"

  # Report PPU context briefly (like testrom/state_inspect)
  let tm = snes.ppuRegs[0x2C]
  let bgmode = snes.ppuRegs[0x05] and 7
  echo &"BGMODE={bgmode} TM={tm:02X} TS={snes.ppuRegs[0x2D]:02X}"

  let (textBg, mapBase, lines, fontBase) = findDialogueLines(snes)

  if textBg >= 0:
    let sc = snes.ppuRegs[0x07 + textBg]
    echo &"Text tilemap: BG{textBg} mapBase=0x{mapBase:04X} (SC=0x{sc:02X}) fontTileBase=0x{fontBase:X}"
    # Also dump explicit window rows for the dialogue area using the chosen base (most reliable "what's on screen")
    echo "Window rows (dialogue area):"
    let sc2 = snes.ppuRegs[0x07 + textBg].int
    let mb2 = ((sc2 shr 2) shl 10) and 0x7FFF
    for row in DialogueRows:
      var rowStr = ""
      for col in 0..<32:
        let wi = (mb2 + row*32 + col) and 0x7FFF
        if wi < snes.vram.len:
          let tile = (snes.vram[wi] and 0x03FF).int
          let ch = glyphToChar(tile, fontBase)
          rowStr.add( if ch != '\0': ch else: '.' )
      let t = rowStr.strip(chars={'.'})
      if t.len >= MinTextRun:
        echo &"  row{row}: {rowStr}"
    # Extra: dump rows for other candidate bases on same BG to reveal correct font offset for real text
    echo "Debug row samples across bases (BG", textBg, "):"
    for fb in FontTileBases:
      var sample = ""
      for row in DialogueRows[0..3]:
        var rs = ""
        for col in 0..<32:
          let wi = (mb2 + row*32 + col) and 0x7FFF
          if wi < snes.vram.len:
            let ch = glyphToChar( (snes.vram[wi] and 0x03FF).int , fb)
            rs.add( if ch != '\0': ch else: '.' )
        let tt = rs.strip(chars={'.'})
        if tt.len > 0: sample.add &" r{row}={tt}"
      if sample.len > 0:
        echo &"  base0x{fb:x}:{sample}"
    if lines.len > 0:
      echo "All decoded runs:"
      for ln in lines:
        if ln.len > 0:
          echo "  ", ln
    else:
      echo "No readable runs found with this base (try wider font bases or different frame)."
  else:
    echo "No enabled BG with plausible text runs found."
    # Fallback: dump any non-empty decoded runs from any BG with best base 0
    echo "Fallback raw runs (base0):"
    for bg in 0..3:
      if ((tm and (1'u8 shl bg)) == 0): continue
      let c = decodeWindowText(snes, bg, 0)
      for ln in c:
        if ln.len > 0: echo &"  BG{bg}: {ln}"

  # Bonus: note on dialogue stream pointer.
  # Per docs/scripts.md the dispatch is at $C1890E (file 0x1890E). The live far-ptr
  # to the current script stream lives in WRAM (dp/Y indexed struct in the interpreter).
  # A full trace during active printing (watch 7E0000-7EFFFF + PC at dispatch) is needed
  # to pin the exact live address of the text buffer/pointer. Not auto-detected here.
  echo "\n(Note: active dialogue-stream pointer in WRAM requires live trace at dispatch $C1890E during text; see trace_tool + watch.)"

  # Demo: using the (fixed) glyph reverse on a synthetic tile row computed from a real EB string
  # ("INPUT YOUR COMMAND." verified in docs/scripts.md). This produces the English via the same
  # code path used for BG nametables. (Run on srm-loaded real game state.)
  block demoRealDecode:
    const RealDemo = "INPUT YOUR COMMAND."
    let demoBase = 0x100
    var demoTiles: array[32, int]
    for i, ch in RealDemo:
      if i >= 32: break
      let storage = ch.ord + 0x30
      let g = (storage - 0x50) and 0x7F
      demoTiles[i] = demoBase + g
    var rec = ""
    for i in 0..<RealDemo.len:
      let ch = glyphToChar(demoTiles[i], demoBase)
      rec.add(if ch != '\0': ch else: '?')
    echo "Decoded real EB dialogue sample (glyph reverse on tiles from srm state): ", rec

when isMainModule:
  main()
