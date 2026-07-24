## Scratch: extract the pokey breadcrumb ground truth from a recorded .tas.
## Replays play-faithfully and logs: position trail, dialogue-window events
## ($8650), entity slots around dialogue moments + at the end, and a WRAM
## event-flag diff between pre-talk and post-talk (candidate sticky flags).
## Output to stdout + bin/breadcrumb_<seg>.txt. Untracked dig tool.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, replay, policy]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  InstrPerLine = 150
  SamplesPerFrame = 533
  TrailEvery = 30
  ## Event-flag region to diff (memory-map: $988B.. block; scan wide).
  FlagLo = 0x9800
  FlagHi = 0x9C00

proc readRom(path: string): seq[uint8] =
  ## ROM bytes, stripping an optional copier header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc stepFrame(snes: SnesBus, c: var Cpu) =
  ## play.nim-faithful frame, no rendering.
  var samples = 0
  var l = 0
  while l < 262:
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for i in 0 ..< InstrPerLine:
      c.step(snes.bus)
      if c.stopped:
        break
    if l < 224:
      snes.runHdma()
    for k in 0 ..< 2:
      discard snes.tickApu()
      inc samples
    inc l
    if l >= 262:
      snes.initHdma()
      break
  while samples < SamplesPerFrame:
    discard snes.tickApu()
    inc samples

proc wramByte(snes: SnesBus, off: int): int =
  ## WRAM byte at 7E:off.
  snes.bus.mem[0x7E0000 + off].int

proc wramU16(snes: SnesBus, off: int): int =
  ## WRAM u16 LE at off.
  wramByte(snes, off) or (wramByte(snes, off + 1) shl 8)

proc entLine(snes: SnesBus): string =
  ## Compact entity slot dump (skip empty/FFFF).
  result = ""
  for s in 0 ..< 30:
    let x = wramU16(snes, 0x0B8E + s * 2)
    let y = wramU16(snes, 0x0BCA + s * 2)
    if (x == 0 and y == 0) or x == 0xFFFF:
      continue
    result.add &" s{s}=({x:04X},{y:04X})"

proc main() =
  ## Replay and report.
  let tasPath = if paramCount() >= 1 and paramStr(1) != "--": paramStr(1)
    else: paramStr(2)
  let (header, deltas) = parseReplay(tasPath)
  let lastFrame = (if deltas.len > 0: deltas[^1].frame else: 0) + 300
  let rom = readRom(RomPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(header.startStateRef)), snes, c)

  var lines: seq[string] = @[]
  var lastWin = 0xFFFF
  var preTalk: seq[uint8] = @[]
  var minY = 0xFFFF
  var lastPx, lastPy = 0
  for f in 0 .. lastFrame:
    snes.joy1 = joyAtFrame(deltas, f)
    stepFrame(snes, c)
    let px = wramU16(snes, 0x0BBE)
    let py = wramU16(snes, 0x0BFA)
    lastPx = px
    lastPy = py
    if py < minY and px != 0:
      minY = py
    if f mod TrailEvery == 0:
      lines.add &"f={f:5} pos=(0x{px:04X},0x{py:04X})"
    # Watch BOTH window slot headers ($8650 menu slot, $8654 dialogue slot —
    # meteor-site dialogue allocates slot 1; found 2026-07-09 flag diff).
    let win = (wramByte(snes, 0x8650) shl 8) or wramByte(snes, 0x8654)
    if win != lastWin:
      lines.add &"f={f:5} WIN $8650/{{$8654}} {lastWin:04X}->{win:04X} pos=(0x{px:04X},0x{py:04X})" & entLine(snes)
      if lastWin == 0xFF and win != 0xFF and preTalk.len == 0:
        # First window open = pre-talk snapshot of the flag region.
        preTalk = newSeq[uint8](FlagHi - FlagLo)
        for i in 0 ..< preTalk.len:
          preTalk[i] = snes.bus.mem[0x7E0000 + FlagLo + i]
        lines.add &"f={f:5} PRE-TALK flag snapshot taken"
      lastWin = win

  lines.add &"END frame={lastFrame} pos=(0x{lastPx:04X},0x{lastPy:04X}) minY=0x{minY:04X}"
  lines.add "END entities:" & entLine(snes)
  if preTalk.len > 0:
    lines.add "FLAG DIFF (pre-first-window vs end):"
    var nDiff = 0
    for i in 0 ..< preTalk.len:
      let cur = snes.bus.mem[0x7E0000 + FlagLo + i]
      if cur != preTalk[i]:
        lines.add &"  $({FlagLo + i:04X}): {preTalk[i]:02X} -> {cur:02X}"
        inc nDiff
        if nDiff > 40:
          lines.add "  ... (truncated)"
          break
    if nDiff == 0:
      lines.add "  (no changes in region)"

  let outP = "bin/breadcrumb_" & tasPath.extractFilename.changeFileExt("") & ".txt"
  writeFile(outP, lines.join("\n") & "\n")
  echo lines.join("\n")
  echo "wrote ", outP

when isMainModule:
  main()
