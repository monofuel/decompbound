## Save-state inspector for diagnosing PPU/HDMA state (e.g. battle HP/PP black band).
## Loads a captured state slot, dumps PPU+HDMA config + the live HDMA table bytes
## from the direct TM/TS channel, renders a fresh frame, and logs per-scanline
## TM/TS changes produced by runHdma.
## Usage: nim r src/tools/state_inspect.nim <rom> <slot> [out.png]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, save_state, snesbus]

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
  ## Load state, dump config + battle HDMA table, render PNG from it, log per-line TM/TS.
  # Handle the "--" separator that `nim c -r ... --` injects as argv[1].
  var argBase = 1
  if paramCount() >= 1 and paramStr(1) == "--":
    argBase = 2
  if paramCount() < argBase + 1:
    echo "Usage: nim r src/tools/state_inspect.nim <rom> <slot> [out.png]"
    quit(1)

  let romPath = paramStr(argBase)
  let slot = parseInt(paramStr(argBase + 1))
  let outPng = if paramCount() >= argBase + 2: paramStr(argBase + 2) else: ""

  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  loadState(snes, cpu, slot)

  echo &"Loaded state slot {slot}"
  echo ""

  # 1. Dump PPU/HDMA config
  echo "=== PPU/HDMA Config (from loaded state) ==="
  echo &"BGMODE={snes.ppuRegs[0x05]:02X} (mode={(snes.ppuRegs[0x05] and 7)})"
  echo &"TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X}"
  echo &"CGWSEL={snes.ppuRegs[0x30]:02X} CGADSUB={snes.ppuRegs[0x31]:02X}"
  echo &"INIDISP={snes.ppuRegs[0x00]:02X} hdmaen={snes.hdmaen:02X}"
  echo ""

  # Find direct TM/TS channel (bbad typically 0x2C for TM+TS pair via tmode=1)
  var directCh = -1
  var directA1: uint32 = 0
  echo "Active HDMA channels:"
  for ch in 0..7:
    if (snes.hdmaen and (1'u8 shl ch)) != 0:
      let base = ch * 0x10
      let dmap = snes.dmaRegs[base]
      let bbad = snes.dmaRegs[base + 1]
      let a1lo = snes.dmaRegs[base + 2]
      let a1hi = snes.dmaRegs[base + 3]
      let a1bank = snes.dmaRegs[base + 4]
      let a1 = (a1bank.uint32 shl 16) or (a1hi.uint32 shl 8) or a1lo.uint32
      let taddr = snes.hdmaTableAddr[ch]
      let indirect = (dmap and 0x40) != 0
      echo &"  ch{ch}: DMAP={dmap:02X} BBAD=${bbad:02X} ($21{bbad:02X}) A1=${a1bank:02X}:{a1hi:02X}{a1lo:02X} (=0x{a1:06X}) hdmaTableAddr=0x{taddr:06X} indirect={indirect}"
      if (bbad == 0x2C or bbad == 0x2D) and directCh < 0:
        directCh = ch
        directA1 = a1
  echo ""
  if directCh >= 0:
    echo &"Direct TM/TS channel: ch{directCh} A1 source addr=0x{directA1:06X}"
  else:
    echo "WARNING: no TM/TS direct channel (bbad 0x2C/2D) found among active HDMA"
  echo ""

  # 2. Dump the battle HDMA table bytes from the direct channel's A1 source (WRAM)
  if directA1 != 0:
    echo "=== Battle HDMA table bytes (~80 from direct channel A1 source) ==="
    echo "Structure: [line-count][TM][TS] repeated, ends with 00. (direct tmode=1 to $2C/$2D)"
    var line = ""
    for k in 0..<80:
      let b = snes.bus.read8(directA1 + k.uint32)
      line.add &"{b:02X} "
      if (k + 1) mod 16 == 0:
        echo &"  +{(k-15):02X}: {line.strip}"
        line = ""
    if line.len > 0:
      echo &"  +...: {line.strip}"
    echo ""

    # Parse bands for quick view of bottom values
    echo "Parsed bands from table (count TM TS):"
    var pos = 0'u32
    var bandIdx = 0
    while pos < 80 and bandIdx < 20:
      let count = snes.bus.read8(directA1 + pos)
      if count == 0:
        echo &"  {pos:02X}: 00 (terminator)"
        break
      let tmv = if pos + 1 < 80: snes.bus.read8(directA1 + pos + 1) else: 0'u8
      let tsv = if pos + 2 < 80: snes.bus.read8(directA1 + pos + 2) else: 0'u8
      let lines = count and 0x7F
      let rep = (count and 0x80) != 0
      echo &"  band{bandIdx} @+{pos:02X}: count={count} (N={lines} repeat={rep}) TM={tmv:02X} TS={tsv:02X}"
      pos += 3
      inc bandIdx
    echo ""

  # 4. Per-scanline band logging (fresh init + runHdma to see exactly what we apply)
  echo "=== Per-scanline TM/TS changes from runHdma (bottom third focus ~150-223) ==="
  snes.initHdma()
  snes.hdmaWrites.setLen(0)
  var prevTM = 0xFF'u8
  var prevTS = 0xFF'u8
  var bottomTmValues: seq[uint8] = @[]
  for line in 0..<224:
    let writeIdxBefore = snes.hdmaWrites.len
    snes.runHdma()
    let tm = snes.ppuRegs[0x2C]
    let ts = snes.ppuRegs[0x2D]
    if line == 0 or tm != prevTM or ts != prevTS:
      echo &"line {line:3}: TM={tm:02X} TS={ts:02X}"
      prevTM = tm
      prevTS = ts
      # Show any TM/TS writes that just happened (reveals if/where 00s come from)
      for wi in writeIdxBefore ..< snes.hdmaWrites.len:
        let (off, v) = snes.hdmaWrites[wi]
        if off == 0x212C or off == 0x212D:
          echo &"    ^-- HDMA wrote ${off:04X}={v:02X} (ch2 tableAddr=0x{snes.hdmaTableAddr[2]:06X})"
    if line >= 150:
      bottomTmValues.add(tm)
  echo ""

  # Summarize bottom
  if bottomTmValues.len > 0:
    let firstBottom = bottomTmValues[0]
    let lastBottom = bottomTmValues[^1]
    var allSame = true
    for v in bottomTmValues:
      if v != firstBottom: allSame = false
    echo &"Bottom third (150-223): first TM={firstBottom:02X} last={lastBottom:02X} allSame={allSame}"
    echo ""

  # 3. Render fresh frame from the loaded state (re-init to start clean)
  if outPng.len > 0:
    let image = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let backdrop = ppu.bgr555ToColor(snes.cgram[0])
    image.fill(backdrop)
    snes.initHdma()
    for line in 0..<224:
      snes.runHdma()
      if (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, image, line)
    ppu.renderSprites(snes, image)
    ppu.overlayForegroundBg(snes, image)
    image.writeFile(outPng)
    echo &"Rendered PNG written to {outPng}"
    echo ""

  # Final state echoes (post any render)
  echo &"Final after render pass: BGMODE={(snes.ppuRegs[0x05] and 7)} TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X} INIDISP={snes.ppuRegs[0x00]:02X}"
  echo &"CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X}"

  # PNG analysis for black-band confirmation (bottom ~1/3)
  if outPng.len > 0 and fileExists(outPng):
    let img = readImage(outPng)
    var blackBottom = 0
    var totalBottom = 0
    let bottomStart = 150
    for y in bottomStart ..< ppu.ScreenHeight:
      for x in 0..<ppu.ScreenWidth:
        let c = img[x, y]
        totalBottom += 1
        if c.r < 10 and c.g < 10 and c.b < 10:
          inc blackBottom
    let pct = if totalBottom > 0: (blackBottom * 100) div totalBottom else: 0
    echo &"PNG bottom analysis (lines {bottomStart}-223): {blackBottom}/{totalBottom} pixels near-black (~{pct}%)"
    var blackTop = 0
    for y in 0..<70:
      for x in 0..<ppu.ScreenWidth:
        let c = img[x, y]
        if c.r < 10 and c.g < 10 and c.b < 10: inc blackTop
    echo &"PNG top (0-69) near-black pixels: {blackTop} (for contrast)"

when isMainModule:
  main()
