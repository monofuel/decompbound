## Pin the first domino of the crash3 WRAM fill (ALIGN4500 repro from 212944).
## Usage: nim r -d:release src/probes/probe_crash3_pin.nim

import
  std/[options, os, strformat, strutils],
  pixie,
  ../decompbound/[apu, cpu, png_state, policy, ppu, replay, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  PngNear6 = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-212944.png"
  SessionTas = "bin/sessions/20260726-212828/20260726-212832.tas"
  Align = 4500
  CoarseFrames = 45
  MaxFrames = 70

proc loadRom(): seq[uint8] =
  ## ROM without copier header.
  var d = cast[seq[uint8]](readFile(RomPath))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc wram8(snes: SnesBus, off: int): uint8 =
  ## WRAM $7E byte.
  snes.bus.mem[0x7E0000 + off]

proc patternScore(snes: SnesBus): int =
  ## Count 4-byte pattern matches (both phases) in low 512 bytes.
  var i = 0
  while i + 3 < 512:
    let b0 = wram8(snes, i)
    let b1 = wram8(snes, i + 1)
    let b2 = wram8(snes, i + 2)
    let b3 = wram8(snes, i + 3)
    if (b0 == 0x00 and b1 == 0x04 and b2 == 0x01 and b3 == 0x60) or
        (b0 == 0x04 and b1 == 0x01 and b2 == 0x60 and b3 == 0x00) or
        (b0 == 0x01 and b1 == 0x60 and b2 == 0x00 and b3 == 0x04) or
        (b0 == 0x60 and b1 == 0x00 and b2 == 0x04 and b3 == 0x01):
      inc result
    i += 4

proc siteName(pbr: uint8, pc: uint16): string =
  ## Short label for PC.
  let a = (pbr.uint32 shl 16) or pc.uint32
  if pbr == 0 and pc == 0x5FFF: return "BRK_SINK"
  if pbr == 0xC0 or pbr == 0x00:
    let p = if pbr == 0: pc else: pc
    if p >= 0xAB06 and p <= 0xABBC: return "uploadApu"
    if p >= 0xABC6 and p <= 0xABDF: return "waitApuIdle"
    if p >= 0xABE0 and p <= 0xAC00: return "queueApu"
    if p >= 0xAC20 and p <= 0xAC2F: return "readApuPort0"
    if p >= 0x9C68 and p <= 0x9C6C: return "freeListWalk"
    if p >= 0x8240 and p <= 0x8274: return "nmiChrDma"
  discard a
  "code"

proc main() =
  ## ALIGN4500 repro with per-instruction hooks on the derail window.
  doAssert fileExists(RomPath)
  let raw = cast[seq[uint8]](readFile(PngNear6))
  let st = extractState(raw)
  doAssert st.isSome
  let (_, deltas) = parseReplay(SessionTas)
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(st.get, snes, c)

  var firstFill = ""
  var nmiMaskWrite = ""
  var sHighFirst = ""
  var brkFirst = ""
  var mvnHits: seq[string]
  var recentPc: seq[string]
  var lowBurst = 0
  var maxBurst = 0
  var maxBurstAt = ""
  var fillTripWrites = 0
  var prevScore = patternScore(snes)

  let prevHook = snes.bus.writeHook
  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let bank = address shr 16
    let off = address and 0xFFFF
    var woff = -1
    if bank == 0x7E or bank == 0x7F:
      woff = off.int
    elif (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and off < 0x2000:
      woff = off.int
    if woff >= 0 and woff < 0x2000:
      inc lowBurst
      if value in [0x00'u8, 0x04'u8, 0x01'u8, 0x60'u8]:
        inc fillTripWrites
        if firstFill.len == 0 and fillTripWrites >= 64:
          firstFill = &"PC={c.pbr:02X}:{c.pc:04X} ({siteName(c.pbr,c.pc)}) " &
            &"S={c.s:04X} A={c.a:04X} X={c.x:04X} Y={c.y:04X} " &
            &"DBR={c.dbr:02X} D={c.d:04X} write ${bank:02X}:{off:04X}={value:02X}"
          echo &"** FIRST_FILL_BURST {firstFill}"
          echo "  recent PC trail:"
          for r in recentPc:
            echo &"    {r}"
    if off == 0x4200 and (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)):
      if (value and 0x80) == 0 and nmiMaskWrite.len == 0:
        nmiMaskWrite = &"PC={c.pbr:02X}:{c.pc:04X} S={c.s:04X} val={value:02X}"
        echo &"** FIRST_NMI_MASK {nmiMaskWrite}"
    if prevHook != nil:
      return prevHook(address, value)
    false

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)

  proc notePc() =
    ## Push PC trail entry.
    let op = snes.bus.read8((c.pbr.uint32 shl 16) or c.pc.uint32)
    let ent = &"{c.pbr:02X}:{c.pc:04X} op={op:02X} {siteName(c.pbr,c.pc)} " &
      &"A={c.a:04X} X={c.x:04X} Y={c.y:04X} S={c.s:04X}"
    recentPc.add ent
    if recentPc.len > 48:
      recentPc.delete(0)
    if op == 0x54 or op == 0x44:
      let b1 = snes.bus.read8((c.pbr.uint32 shl 16) or ((c.pc + 1) and 0xFFFF).uint32)
      let b2 = snes.bus.read8((c.pbr.uint32 shl 16) or ((c.pc + 2) and 0xFFFF).uint32)
      let hit = &"{ent} dstBank={b1:02X} srcBank={b2:02X}"
      if mvnHits.len < 40:
        mvnHits.add hit
        echo &"** MVN/MVP {hit}"

  for f in 0 ..< MaxFrames:
    snes.joy1 = joyAtFrame(deltas, Align + f)
    if f < CoarseFrames:
      policy.stepOneFrame(snes, c, img)
    else:
      # Same structure as policy.stepOneFrame with PC tracing.
      let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
      if not forceBlank:
        img.fill(ppu.bgr555ToColor(snes.cgram[0]))
      var l = 0
      while l < 262:
        if l == 224:
          ppu.renderSprites(snes, img)
          ppu.overlayForegroundBg(snes, img)
          if (snes.nmitimen and 0x80) != 0:
            c.nmiPending = true
        for i in 0 ..< policy.InstrPerLine:
          notePc()
          lowBurst = 0
          c.step(snes.bus)
          if lowBurst > maxBurst:
            maxBurst = lowBurst
            maxBurstAt = &"{c.pbr:02X}:{c.pc:04X} A={c.a:04X} X={c.x:04X} Y={c.y:04X} DBR={c.dbr:02X}"
          if c.s >= 0x2000'u16 and sHighFirst.len == 0:
            sHighFirst = &"PC={c.pbr:02X}:{c.pc:04X} S={c.s:04X} A={c.a:04X} X={c.x:04X} Y={c.y:04X}"
            echo &"** FIRST_S_HIGH {sHighFirst}"
            echo "  recent:"
            for r in recentPc:
              echo &"    {r}"
          if c.pbr == 0 and c.pc == 0x5FFF and brkFirst.len == 0:
            brkFirst = &"S={c.s:04X} A={c.a:04X} X={c.x:04X} Y={c.y:04X} P={c.p:02X} score={patternScore(snes)}"
            echo &"** FIRST_BRK_SINK {brkFirst}"
            echo "  recent:"
            for r in recentPc:
              echo &"    {r}"
          if c.stopped:
            break
        if l < 224:
          snes.runHdma()
          if (snes.ppuRegs[0x00] and 0x80) == 0:
            ppu.renderScanline(snes, img, l)
        for k in 0 ..< 2:
          discard snes.tickApu()
        inc l
        if l >= 262:
          snes.initHdma()
          break

    let score = patternScore(snes)
    if score > prevScore + 5:
      echo &"** PATTERN_JUMP f={f} {prevScore} -> {score} cpu={c.pbr:02X}:{c.pc:04X} S={c.s:04X}"
    prevScore = score
    echo &"f={f:3d} cpu={c.pbr:02X}:{c.pc:04X} ({siteName(c.pbr,c.pc)}) S={c.s:04X} " &
      &"nmi={snes.nmitimen:02X} q={wram8(snes,0):02X}/{wram8(snes,1):02X} " &
      &"score={score} maxBurst={maxBurst}@{maxBurstAt}"
    if brkFirst.len > 0 and f >= CoarseFrames + 5:
      break
    if score >= 40 and brkFirst.len > 0:
      break

  echo "==== SUMMARY ===="
  echo &"firstFill: {firstFill}"
  echo &"nmiMask: {nmiMaskWrite}"
  echo &"sHigh: {sHighFirst}"
  echo &"brk: {brkFirst}"
  echo &"mvnHits={mvnHits.len}"
  for h in mvnHits:
    echo &"  {h}"
  echo &"end {c.pbr:02X}:{c.pc:04X} S={c.s:04X} nmi={snes.nmitimen:02X} score={patternScore(snes)}"
  echo &"maxBurst={maxBurst} at {maxBurstAt}"

when isMainModule:
  main()
