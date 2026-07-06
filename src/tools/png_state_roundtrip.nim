## Headless byte-exact round-trip test for state <-> PNG ebSt chunk.
## - load slot1.state into SnesBus+Cpu
## - serializeState
## - render a 256x224 frame (via pixie + ppu fns for a valid PNG)
## - embedState
## - write temp to bin/ (gitignored)
## - read back, extractState, deserialize to FRESH SnesBus+Cpu
## - serialize the fresh one, assert bytes identical to first
## - also assert the embedded PNG still decodes as valid 256x224 via pixie
##
## Usage: nim r src/tools/png_state_roundtrip.nim [rom]
## (rom defaults to the gold EB image; slot1.state must exist and match it)
## Prints PASS/FAIL + compression stats. Exits non-zero on failure.

import
  std/[os, strformat, options],
  pixie,
  zippy,
  ../decompbound/[ppu, save_state, snesbus, png_state]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM, strip optional 512-byte copier header (same as state_inspect).
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc renderFrame(snes: SnesBus): seq[uint8] =
  ## Render current state to a 256x224 PNG bytes (pixie). Mirrors the
  ## render path in state_inspect so we get a real image for embed test.
  let image = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let backdrop = ppu.bgr555ToColor(snes.cgram[0])
  image.fill(backdrop)
  snes.initHdma()
  for line in 0..<ppu.ScreenHeight:
    snes.runHdma()
    if (snes.ppuRegs[0x00] and 0x80) == 0:
      ppu.renderScanline(snes, image, line)
  ppu.renderSprites(snes, image)
  ppu.overlayForegroundBg(snes, image)
  let pngStr = image.encodeImage(PngFormat)
  var bytes = newSeq[uint8](pngStr.len)
  if bytes.len > 0:
    copyMem(addr bytes[0], unsafeAddr pngStr[0], bytes.len)
  bytes

proc main() =
  ## Run the full round-trip and print results.
  var argBase = 1
  if paramCount() >= 1 and paramStr(1) == "--":
    argBase = 2
  let romPath =
    if paramCount() >= argBase:
      paramStr(argBase)
    else:
      "bin/Earthbound (U) [!].smc"

  if not fileExists(romPath):
    echo &"ERROR: ROM not found at {romPath}"
    echo "Provide path to a ROM that matches bin/states/slot1.state"
    quit(1)
  if not fileExists("bin/states/slot1.state"):
    echo "ERROR: bin/states/slot1.state not found (create it first via play or similar)"
    quit(1)

  let rom = readRomFile(romPath)
  let romH = romHashOf(rom)
  echo &"ROM: {romPath}  size={rom.len}  hash=0x{romH:08X}"

  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  loadState(snes, cpu, 1)
  echo "Loaded slot 1 state"

  let stateOrig = serializeState(snes, cpu)
  echo &"serializeState: {stateOrig.len} bytes raw (~{stateOrig.len div 1024} KB)"

  # Render to obtain a base PNG (real frame from the state)
  let basePng = renderFrame(snes)
  echo &"rendered frame PNG: {basePng.len} bytes"

  # Embed
  let embedded = embedState(basePng, stateOrig, romH)
  echo &"embedState: {embedded.len} bytes (delta +{embedded.len - basePng.len})"

  # Persist to gitignored bin/ for the read-back leg
  let tmpPngPath = "bin/state_screenshot_roundtrip.png"
  writeFile(tmpPngPath, cast[string](embedded))
  echo &"wrote {tmpPngPath} (gitignored)"

  # Read back and extract
  let readBytes = readFile(tmpPngPath)
  var readPng = newSeq[uint8](readBytes.len)
  if readPng.len > 0:
    copyMem(addr readPng[0], unsafeAddr readBytes[0], readPng.len)
  let extractedOpt = extractState(readPng)
  if extractedOpt.isNone:
    echo "FAIL: extractState returned none (bad chunk / magic / version / uncompress)"
    quit(1)
  let extracted = extractedOpt.get
  echo &"extractState: {extracted.len} bytes"

  # Fresh objects + deserialize
  let snes2 = newSnesBus(rom)
  var cpu2 = snes2.resetCpu()
  deserializeState(extracted, snes2, cpu2)
  let stateRound = serializeState(snes2, cpu2)

  let statesIdentical = stateOrig == stateRound
  let stateMsg = if statesIdentical: "PASS" else: "FAIL"
  echo &"state round-trip byte-identical: {stateMsg}"
  if not statesIdentical:
    echo &"  orig.len={stateOrig.len} round.len={stateRound.len}"
    var diffAt = -1
    for i in 0..<min(stateOrig.len, stateRound.len):
      if stateOrig[i] != stateRound[i]:
        diffAt = i
        break
    if diffAt >= 0:
      echo &"  first diff @ {diffAt}: {stateOrig[diffAt]:02X} != {stateRound[diffAt]:02X}"
    quit(1)

  # PNG validity: still decodes as 256x224 image (ancillary chunk ignored)
  var pngValid = false
  try:
    let decoded = decodeImage(cast[string](embedded))
    pngValid = (decoded.width == ppu.ScreenWidth) and (decoded.height == ppu.ScreenHeight)
    let pngMsg = if pngValid: "PASS" else: "FAIL"
    echo &"embedded PNG decodes as {decoded.width}x{decoded.height}: {pngMsg}"
  except CatchableError as e:
    echo &"embedded PNG decode FAILED: {e.msg}"
  if not pngValid:
    quit(1)

  # Compression numbers (raw state vs deflate payload)
  let comp = compress(stateOrig, DefaultCompression, dfDeflate)
  let ratio = if comp.len > 0: stateOrig.len.float / comp.len.float else: 0.0
  echo &"compression: raw {stateOrig.len} -> {comp.len}  ratio ~{ratio:.2f}x"

  echo "ALL PASS"

when isMainModule:
  main()