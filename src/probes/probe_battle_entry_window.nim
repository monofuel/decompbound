## Single-step the deterministic TAS contact entry (f=1857 / abort f=1868).
## Logs every $C0404F ARG/RET, the $0A62 queue, $2AF6 style words, and
## $9883/$5D9A/$0065 per frame. Play-faithful stepper. No WRAM pokes.
## Usage: nim r src/probes/probe_battle_entry_window.nim [tas] [from] [to]
import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, replay, save_state, snesbus, policy]

const
  Rom = "bin/Earthbound (U) [!].smc"
  DefaultTas = "bin/replays/20260709-234547.tas"
  InstrPerLine = 150
  SamplesPerFrame = 533
  LookupEntry = 0x404F
  LookupReturn = 0x4AC8
  TickEntry = 0x4AAD
  InitLoop = 0x4AD6
  SlotIter = 0x4ADD
  StyleWrite = 0x4B30
  InitJsl = 0x4B35
  AbortJsl = 0x4B4D
  Phase2Store = 0x66A4
  RemapperSta = 0x2D24
  WriterHeld = 0x84BD
  PadCopy = 0x8453

proc wram(snes: SnesBus, off: int): int =
  ## WRAM byte at 7E:off.
  snes.bus.mem[0x7E0000 + (off and 0xFFFF)].int

proc wram16(snes: SnesBus, off: int): int =
  ## WRAM word at 7E:off.
  wram(snes, off) or (wram(snes, off + 1) shl 8)

proc nibbleName(v: int): string =
  ## Name the $0F00 D-pad nibble.
  case v and 0x0F00
  of 0x0800: "U"
  of 0x0900: "U+R"
  of 0x0100: "R"
  of 0x0500: "R+D"
  of 0x0400: "D"
  of 0x0600: "D+L"
  of 0x0200: "L"
  of 0x0A00: "L+U"
  of 0x0000: "none"
  else: fmt"other({v and 0x0F00:04X})"

proc dumpQueue(snes: SnesBus): string =
  ## Compact $0A62[0..29] hex dump (loop walks 24..29).
  var parts: seq[string]
  for i in 0 .. 29:
    parts.add(fmt"{wram16(snes, 0x0A62 + i * 2):04X}")
  parts.join(" ")

proc dumpStyles(snes: SnesBus): string =
  ## $2AF6[24..29] (per-slot style written by the init loop).
  var parts: seq[string]
  for i in 24 .. 29:
    parts.add(fmt"{i}={wram16(snes, 0x2AF6 + i * 2):04X}")
  parts.join(" ")

proc dumpTypes(snes: SnesBus): string =
  ## $0E9A[24..29] (entity-type index used as $99CE stride).
  var parts: seq[string]
  for i in 24 .. 29:
    parts.add(fmt"{i}={wram16(snes, 0x0E9A + i * 2):04X}")
  parts.join(" ")

proc snap(snes: SnesBus, c: Cpu, tag: string) =
  ## One-line live snapshot of the phase-3 gates.
  let v65 = wram16(snes, 0x0065)
  echo fmt"{tag} 98A5={wram(snes, 0x98A5)} 5D7C={wram16(snes, 0x5D7C):04X} " &
    fmt"4DBA={wram16(snes, 0x4DBA):04X} mode={(snes.ppuRegs[0x05] and 0x7).int} " &
    fmt"$0065={v65:04X}({nibbleName(v65)}) $0077={wram16(snes, 0x0077):04X} " &
    fmt"9883={wram16(snes, 0x9883):04X} 987F={wram16(snes, 0x987F):04X} " &
    fmt"5D9A={wram16(snes, 0x5D9A):04X} 5D9E={wram16(snes, 0x5D9E):04X} " &
    fmt"joy1={snes.joy1:04X} PC={c.pbr:02X}:{c.pc:04X}"
  echo fmt"  0A62[0..29]={dumpQueue(snes)}"
  echo fmt"  2AF6[24..29]={dumpStyles(snes)}"
  echo fmt"  0E9A[24..29]={dumpTypes(snes)}"

proc stepFrameFast(snes: SnesBus, c: var Cpu) =
  ## Play-faithful frame with no breakpoints.
  var samples = 0
  var l = 0
  while l < 262:
    snes.tickScanline(l)
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

proc stepFrameTraced(snes: SnesBus, c: var Cpu, f: int) =
  ## One play-faithful frame, logging lookup / init / phase-2 / pad writes.
  var
    samples = 0
    l = 0
    prev65 = wram16(snes, 0x0065)
  while l < 262:
    snes.tickScanline(l)
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for i in 0 ..< InstrPerLine:
      if c.pbr == 0xC0 and c.pc == TickEntry:
        echo fmt"  tick D={c.d:04X} 5D7C={wram16(snes, 0x5D7C):04X} " &
          fmt"9883={wram16(snes, 0x9883):04X} $0065={wram16(snes, 0x0065):04X} " &
          fmt"5D9A={wram16(snes, 0x5D9A):04X}"
      if c.pbr == 0xC0 and c.pc == LookupEntry:
        echo fmt"  lookup ARG A={c.a.int and 0xFFFF:04X} D={c.d:04X} " &
          fmt"$0065={wram16(snes, 0x0065):04X}({nibbleName(wram16(snes, 0x0065))}) " &
          fmt"5D9A={wram16(snes, 0x5D9A):04X} 9883={wram16(snes, 0x9883):04X} " &
          fmt"line={l}"
      if c.pbr == 0xC0 and c.pc == LookupReturn:
        echo fmt"  lookup RET A={c.a.int and 0xFFFF:04X} $04-will-store " &
          fmt"$0065={wram16(snes, 0x0065):04X}"
      if c.pbr == 0xC0 and c.pc == InitLoop:
        echo fmt"  INIT-LOOP enter A={c.a.int and 0xFFFF:04X} " &
          fmt"2AF6={dumpStyles(snes)} 0E9A={dumpTypes(snes)}"
      if c.pbr == 0xC0 and c.pc == SlotIter:
        let slot = wram16(snes, (c.d.int + 0x02) and 0xFFFF)
        let q = wram16(snes, 0x0A62 + slot * 2)
        let sty = wram16(snes, 0x2AF6 + slot * 2)
        echo fmt"  slot-iter slot={slot} 0A62={q:04X} 2AF6={sty:04X}"
      if c.pbr == 0xC0 and c.pc == StyleWrite:
        echo fmt"  STYLE-WRITE A={c.a.int and 0xFFFF:04X} Y={c.y.int and 0xFFFF:04X}"
      if c.pbr == 0xC0 and c.pc == InitJsl:
        echo fmt"  JSL $C0A780 A={c.a.int and 0xFFFF:04X}"
      if c.pbr == 0xC0 and c.pc == AbortJsl:
        echo fmt"  ABORT JSL $C04A7B 5D7C={wram16(snes, 0x5D7C):04X} " &
          fmt"5D7A={wram16(snes, 0x5D7A):04X}"
      if c.pbr == 0xC4 and c.pc == Phase2Store:
        echo fmt"  PHASE2 STA $98A5 A={c.a.int and 0xFFFF:04X}"
      if c.pbr == 0xC0 and c.pc == RemapperSta:
        echo fmt"  remapper STA $0065 A={c.a.int and 0xFFFF:04X} " &
          fmt"5D9E={wram16(snes, 0x5D9E):04X}"
      if c.pbr == 0xC0 and c.pc == WriterHeld:
        echo fmt"  STA $65,X X={c.x.int and 0xFFFF:04X} A={c.a.int and 0xFFFF:04X} D={c.d:04X}"
      if c.pbr == 0xC0 and c.pc == PadCopy:
        echo fmt"  STA $77 from $4218 A={c.a.int and 0xFFFF:04X} line={l}"
      let now65 = wram16(snes, 0x0065)
      if now65 != prev65:
        echo fmt"  $0065 {prev65:04X}->{now65:04X}({nibbleName(now65)}) " &
          fmt"PC={c.pbr:02X}:{c.pc:04X} line={l}"
        prev65 = now65
      c.step(snes.bus)
      if c.stopped:
        echo fmt"  CPU STOPPED f={f} PC={c.pbr:02X}:{c.pc:04X}"
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

proc main() =
  let
    tasPath = if paramCount() >= 1: paramStr(1) else: DefaultTas
    fromFrame = if paramCount() >= 2: parseInt(paramStr(2)) else: 1840
    toFrame = if paramCount() >= 3: parseInt(paramStr(3)) else: 1875
  let startState = tasPath.replace(".tas", "_start.state")
  if not fileExists(startState):
    echo "MISSING start state: ", startState
    quit(2)
  let (header, deltas) = parseReplay(tasPath)
  echo fmt"tas={tasPath} start={startState} rom_hash={header.romHash:08X}"
  echo "TAS joy around window:"
  for d in deltas:
    if d.frame >= 1770 and d.frame <= 1900:
      echo fmt"  f={d.frame} joy1={d.joy1:04X}({nibbleName(d.joy1.int)})"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(startState)), snes, c)
  echo fmt"fast-forward 0..{fromFrame - 1}"
  for f in 0 ..< fromFrame:
    snes.joy1 = joyAtFrame(deltas, f)
    stepFrameFast(snes, c)
    if c.stopped:
      echo fmt"CPU STOPPED during ff at f={f}"
      quit(2)
  snap(snes, c, fmt"f={fromFrame - 1} (pre-trace)")
  echo "---- single-step window ----"
  for f in fromFrame .. toFrame:
    snes.joy1 = joyAtFrame(deltas, f)
    echo fmt"==== f={f} joy1={snes.joy1:04X}({nibbleName(snes.joy1.int)}) ===="
    stepFrameTraced(snes, c, f)
    snap(snes, c, fmt"f={f} end")
    if c.stopped:
      break
  echo fmt"done. 98A5={wram(snes, 0x98A5)} 4DBA={wram16(snes, 0x4DBA):04X} " &
    fmt"mode={(snes.ppuRegs[0x05] and 0x7).int} 987F={wram16(snes, 0x987F):04X}"

when isMainModule:
  main()
