## §7D follow-up: pin C4:73D0 palette→$0400 overlap vs derail jobs + timing.
## Usage: nim r -d:release src/probes/probe_queue_poison2.nim [derail|timing|live|all]

import
  std/[options, os, strformat, strutils, tables],
  pixie,
  ../decompbound/[cpu, png_state, ppu, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  PngHealthy = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-212924.png"
  IdleFrames = 900

proc loadRom(): seq[uint8] =
  ## ROM without copier header.
  var d = cast[seq[uint8]](readFile(RomPath))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc wram8(snes: SnesBus, off: int): uint8 =
  ## WRAM $7E byte.
  snes.bus.mem[0x7E0000 + off]

proc wram16(snes: SnesBus, off: int): uint16 =
  ## LE WRAM word.
  wram8(snes, off).uint16 or (wram8(snes, off + 1).uint16 shl 8)

proc loadPng(path: string): tuple[snes: SnesBus, cpu: Cpu] =
  ## F12 → bus.
  let st = extractState(cast[seq[uint8]](readFile(path)))
  doAssert st.isSome
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(st.get, snes, c)
  (snes, c)

proc dumpSpan(snes: SnesBus, q0, q1: uint8, label: string) =
  ## Dump active queue span jobs (8-bit ring).
  echo &"=== {label} q0={q0:02X} q1={q1:02X} ==="
  if q0 == q1:
    echo "  (empty)"
    return
  var x = q1.int
  var n = 0
  while x != q0.int and n < 40:
    let base = 0x400 + x
    let typ = wram8(snes, base)
    let size = wram8(snes, base + 1).uint16 or (wram8(snes, base + 2).uint16 shl 8)
    let aLo = wram8(snes, base + 3).uint16 or (wram8(snes, base + 4).uint16 shl 8)
    let bank = wram8(snes, base + 5)
    let vram = wram8(snes, base + 6).uint16 or (wram8(snes, base + 7).uint16 shl 8)
    ## Peek DMAP table $C08FB0,Y (type is byte).
    let dmap = snes.bus.read8(0xC08FB0'u32 + typ.uint32)
    let toA = (dmap and 0x80) != 0
    echo &"  X={x:02X} type={typ:02X} DMAP={dmap:02X} toA={toA} size={size:04X} " &
      &"A={bank:02X}:{aLo:04X} VRAM={vram:04X}"
    x = (x + 8) and 0xFF
    inc n

proc stepFrame(snes: SnesBus, cpu: var Cpu, image: Image, ipl: int) =
  ## One frame, NMI at line 224, configurable budget.
  if (snes.ppuRegs[0x00] and 0x80) == 0:
    image.fill(ppu.bgr555ToColor(snes.cgram[0]))
  var l = 0
  while l < 262:
    if l == 224:
      ppu.renderSprites(snes, image)
      ppu.overlayForegroundBg(snes, image)
      if (snes.nmitimen and 0x80) != 0:
        cpu.nmiPending = true
    for i in 0 ..< ipl:
      cpu.step(snes.bus)
      if cpu.stopped: break
    if l < 224:
      snes.runHdma()
      if (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, image, l)
    for k in 0 ..< 2:
      discard snes.tickApu()
    inc l
    if l >= 262:
      snes.initHdma()
      break

proc phaseDerail() =
  ## Idle 212924; on first dmaWramToA or BRK, dump queue + $0240 window.
  echo "======== DERAIL PIN ipl=150 ========"
  let (snes, c0) = loadPng(PngHealthy)
  var c = c0
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var paletteSmashFrames: seq[int]
  var lastSmashDetail = ""
  let prev = snes.bus.writeHook
  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let bank = address shr 16
    let off = address and 0xFFFF
    var woff = -1
    if bank == 0x7E or bank == 0x7F: woff = off.int
    elif (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and off < 0x2000:
      woff = off.int
    if woff >= 0x400 and woff <= 0x43F:
      ## C4:745A is STA ($18); PC often already at 745C INC.
      if c.pbr == 0xC4 and c.pc >= 0x7450 and c.pc <= 0x7468:
        if lastSmashDetail.len == 0 or not lastSmashDetail.startsWith(&"f="):
          discard
        lastSmashDetail = &"PC={c.pbr:02X}:{c.pc:04X} ${woff:04X}={value:02X} " &
          &"A={c.a:04X} X={c.x:04X} Y={c.y:04X} D={c.d:04X} " &
          &"q={wram8(snes,0):02X}/{wram8(snes,1):02X} $30={wram8(snes,0x30):02X}"
    if prev != nil: return prev(address, value)
    false

  var prevSmash = ""
  for f in 0 ..< IdleFrames:
    snes.joy1 = 0
    stepFrame(snes, c, img, 150)
    if lastSmashDetail.len > 0 and lastSmashDetail != prevSmash:
      if paletteSmashFrames.len == 0 or paletteSmashFrames[^1] != f:
        paletteSmashFrames.add f
        echo &"[smash] f={f} {lastSmashDetail}"
      prevSmash = lastSmashDetail
    if snes.dmaWramToA or (c.pbr == 0 and c.pc == 0x5FFF) or wram16(snes, 0x20) == 0:
      echo &"** EVENT f={f} dmaWramToA={snes.dmaWramToA} PC={c.pbr:02X}:{c.pc:04X} " &
        &"$20={wram16(snes,0x20):04X} nmitimen={snes.nmitimen:02X} " &
        &"q={wram8(snes,0):02X}/{wram8(snes,1):02X} " &
        &"DMAP={snes.dmaWramToADmap:02X} A={snes.dmaWramToABank:02X}:" &
        &"{snes.dmaWramToAAddr:04X} size={snes.dmaWramToASize}"
      dumpSpan(snes, wram8(snes, 0), wram8(snes, 1), "at-event")
      ## Also dump low 8 slots regardless of span.
      echo "--- slots 0..7 raw ---"
      for i in 0 .. 7:
        let b = 0x400 + i * 8
        var line = &"  [{i}] "
        for j in 0 .. 7: line.add &"{wram8(snes, b+j):02X} "
        echo line
      echo &"palette smash frames: {paletteSmashFrames}"
      echo &"$0030={wram8(snes,0x30):02X} (palette DMA request index)"
      ## $0240 CGRAM staging head
      var cg = "  $0240: "
      for i in 0 .. 15: cg.add &"{wram8(snes, 0x240+i):02X} "
      echo cg
      return
    if f mod 100 == 0:
      echo &"f={f} PC={c.pbr:02X}:{c.pc:04X} q={wram8(snes,0):02X}/{wram8(snes,1):02X} " &
        &"$20={wram16(snes,0x20):04X} smashes={paletteSmashFrames.len}"
  echo "no derail in window"

proc phaseLive() =
  ## Detect when palette smash hits a NON-EMPTY queue span (live overwrite).
  echo "======== LIVE OVERWRITE HUNT ========"
  let (snes, c0) = loadPng(PngHealthy)
  var c = c0
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var liveHits = 0
  let prev = snes.bus.writeHook
  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let bank = address shr 16
    let off = (address and 0xFFFF).int
    var woff = -1
    if bank == 0x7E or bank == 0x7F: woff = off
    elif (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and off < 0x2000:
      woff = off
    if woff >= 0x400 and woff <= 0x04FF and c.pbr == 0xC4 and c.pc >= 0x7450 and c.pc <= 0x7468:
      let q0 = wram8(snes, 0)
      let q1 = wram8(snes, 1)
      if q0 != q1:
        ## Slot index byte = woff - 0x400; in ring span?
        let slot = (woff - 0x400) and 0xFF
        var x = q1.int
        var inSpan = false
        var guard = 0
        while x != q0.int and guard < 40:
          if slot >= x and slot < x + 8:
            inSpan = true
            break
          x = (x + 8) and 0xFF
          inc guard
        if inSpan:
          inc liveHits
          if liveHits <= 30:
            echo &"LIVE_SMASH PC={c.pbr:02X}:{c.pc:04X} ${woff:04X}={value:02X} " &
              &"q={q0:02X}/{q1:02X} slotOff={slot:02X} A={c.a:04X} Y={c.y:04X}"
    if prev != nil: return prev(address, value)
    false

  for f in 0 ..< IdleFrames:
    snes.joy1 = 0
    stepFrame(snes, c, img, 150)
    if snes.dmaWramToA or (c.pbr == 0 and c.pc == 0x5FFF):
      echo &"derail f={f} liveHits={liveHits} q={wram8(snes,0):02X}/{wram8(snes,1):02X}"
      dumpSpan(snes, wram8(snes, 0), wram8(snes, 1), "derail")
      break
    if f mod 100 == 0:
      echo &"f={f} liveHits={liveHits} q={wram8(snes,0):02X}/{wram8(snes,1):02X}"
  echo &"total LIVE_SMASH write events: {liveHits}"

proc phaseTiming() =
  ## InstrPerLine sensitivity.
  echo "======== TIMING ========"
  for ipl in [100, 150, 200, 250]:
    let (snes, c0) = loadPng(PngHealthy)
    var c = c0
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    var derail = -1
    var sig = ""
    var smashN = 0
    let prev = snes.bus.writeHook
    snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
      let off = address and 0xFFFF
      let bank = address shr 16
      if (bank == 0x7E or off < 0x2000) and off >= 0x400 and off <= 0x43F:
        if c.pbr == 0xC4 and c.pc >= 0x7450 and c.pc <= 0x7468:
          inc smashN
      if prev != nil: return prev(address, value)
      false
    for f in 0 ..< IdleFrames:
      snes.joy1 = 0
      stepFrame(snes, c, img, ipl)
      if snes.dmaWramToA:
        derail = f
        sig = "DMA_WRAM_TOA"
        break
      if c.pbr == 0 and c.pc == 0x5FFF:
        derail = f
        sig = "BRK"
        break
      if wram16(snes, 0x20) == 0:
        derail = f
        sig = "VEC0"
        break
    echo &"ipl={ipl} derail={derail} sig={sig} paletteWrites={smashN} " &
      &"endPC={c.pbr:02X}:{c.pc:04X} q={wram8(snes,0):02X}/{wram8(snes,1):02X}"

proc main() =
  ## Dispatch.
  doAssert fileExists(RomPath)
  let phase = if paramCount() >= 1: paramStr(1) else: "all"
  case phase
  of "derail": phaseDerail()
  of "live": phaseLive()
  of "timing": phaseTiming()
  of "all":
    phaseDerail()
    phaseLive()
    phaseTiming()
  else:
    quit(1)

main()
