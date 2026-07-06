## Read on-screen dialogue text from a loaded game state by scanning BG nametables.
## Reuses the tilemap BGxSC + vram approach from testrom.nim, but targets the
## dialogue window region and applies the EB glyph mapping (glyph_id = (byte-0x50)&0x7F
## reverse) documented in docs/scripts.md and verified in text_decode.nim.
## Loads full state (slot or .state file) the same way state_inspect does.
## Output is readable text to stdout only (user-local, never committed).
## Usage: nim r src/tools/read_text.nim <rom> [--slot N|--state path.state]
##
## Reports the text tilemap location (BG + map base) used.

import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state]

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
  ## glyph = (storage - 0x50) & 0x7F ; storage = ascii + 0x30 => char = ((tile-fontBase)+0x50)&0x7F - 0x30
  let g = tile - fontBase
  if g < 0 or g > 0x7F:
    return '\0'
  let storage = (g + 0x50) and 0x7F
  # Storage encoding: printable byte = ascii + 0x30 (verified in docs/scripts.md + text_decode).
  let chVal = storage - 0x30
  if chVal >= 0x20 and chVal <= 0x7E:
    return char(chVal)
  return '\0'

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
    echo "Usage: nim r src/tools/read_text.nim <rom> [--slot N | --state path.state]"
    echo "  --slot 99   loads bin/states/slot99.state (or use after saveState in other tool)"
    echo "  --state foo.state  loads any .state produced by serializeState"
    quit(1)

  var romPath = ""
  var slot = -1
  var statePath = ""
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
    elif not a.startsWith("--"):
      if romPath.len == 0: romPath = a
    inc i

  if romPath.len == 0:
    romPath = "bin/Earthbound (U) [!].smc"
  if slot < 0 and statePath.len == 0:
    echo "ERROR: provide --slot N or --state path.state"
    quit(1)
  if not fileExists(romPath):
    echo &"ERROR: ROM not found: {romPath}"
    quit(1)

  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()

  if statePath.len > 0:
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

when isMainModule:
  main()
