## After lookup+init succeed on the TAS contact, watch the phase-2 promote
## path: $C16D62 (script opcode), $C46698 (STA $98A5=2), $C0B99A/$C0B7D8
## (battle setup that fills $4DC8), $C06532 ($5D9A job submit). From the
## pre-entry ring state + TAS inputs f>=1800. No WRAM pokes.
## Usage: nim r src/probes/probe_battle_entry_promote.nim
import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, replay, save_state, snesbus, policy]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Tas = "bin/replays/20260709-234547.tas"
  RingState = "bin/states/llm/replay_pre_ring.state"
  RingFrame = 1800
  FromFrame = 1850
  ToFrame = 1875
  InstrPerLine = 150
  SamplesPerFrame = 533
  Phase2Script = 0x6D62
  Phase2Store = 0x66A4
  SetupHead = 0xB99A
  SetupFill = 0xB7D8
  PtrFill = 0x3317
  BusySet = 0x6532
  Seed = 0x4A88
  Gate5D98 = 0x4FFE

proc wram(snes: SnesBus, off: int): int =
  ## WRAM byte at 7E:off.
  snes.bus.mem[0x7E0000 + (off and 0xFFFF)].int

proc wram16(snes: SnesBus, off: int): int =
  ## WRAM word at 7E:off.
  wram(snes, off) or (wram(snes, off + 1) shl 8)

proc dumpPtrs(snes: SnesBus): string =
  ## $4DC8[0..5] battler pointers.
  var parts: seq[string]
  for i in 0 .. 5:
    parts.add(fmt"{wram16(snes, 0x4DC8 + i * 2):04X}")
  parts.join(" ")

proc snap(snes: SnesBus, c: Cpu, tag: string) =
  ## Phase-2-gate snapshot.
  echo fmt"{tag} 98A5={wram(snes, 0x98A5)} 5D7C={wram16(snes, 0x5D7C):04X} " &
    fmt"4DBA={wram16(snes, 0x4DBA):04X} 4DB6={wram16(snes, 0x4DB6):04X} " &
    fmt"4DB8={wram16(snes, 0x4DB8):04X} 5D98={wram16(snes, 0x5D98):04X} " &
    fmt"5D9A={wram16(snes, 0x5D9A):04X} 97CA={wram16(snes, 0x97CA):04X} " &
    fmt"436C={wram16(snes, 0x436C):04X} 5E04={wram16(snes, 0x5E04):04X} " &
    fmt"9E33={wram16(snes, 0x9E33):04X} mode={(snes.ppuRegs[0x05] and 0x7).int} " &
    fmt"PC={c.pbr:02X}:{c.pc:04X}"
  echo fmt"  4DC8[0..5]={dumpPtrs(snes)} A970={wram16(snes, 0xA970):04X}"

proc stepFrame(snes: SnesBus, c: var Cpu, trace: bool, f: int) =
  ## Play-faithful frame; optional promote-path breakpoints.
  var samples = 0
  var l = 0
  while l < 262:
    snes.tickScanline(l)
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for i in 0 ..< InstrPerLine:
      if trace:
        if c.pbr == 0xC1 and c.pc == Phase2Script:
          echo fmt"  HIT $C16D62 A={c.a.int and 0xFFFF:04X} X={c.x.int and 0xFFFF:04X} " &
            fmt"97CA={wram16(snes, 0x97CA):04X} line={l}"
        if c.pbr == 0xC4 and c.pc == Phase2Store:
          echo fmt"  HIT $C466A4 STA $98A5 A={c.a.int and 0xFFFF:04X}"
        if c.pbr == 0xC0 and c.pc == SetupHead:
          echo fmt"  HIT $C0B99A setup-head line={l}"
        if c.pbr == 0xC0 and c.pc == SetupFill:
          echo fmt"  HIT $C0B7D8 setup-fill line={l}"
        if c.pbr == 0xC4 and c.pc == PtrFill:
          echo fmt"  HIT $C43317 fill $4DC8"
        if c.pbr == 0xC0 and c.pc == BusySet:
          echo fmt"  HIT $C06532 STA $5D9A=1"
        if c.pbr == 0xC0 and c.pc == Seed:
          echo fmt"  HIT $C04A88 seed"
        if c.pbr == 0xC0 and c.pc == Gate5D98:
          echo fmt"  HIT $C04FFE gate 98A5={wram(snes, 0x98A5)} " &
            fmt"5D98={wram16(snes, 0x5D98):04X}"
      c.step(snes.bus)
      if c.stopped:
        echo fmt"  CPU STOPPED f={f}"
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
  if not fileExists(RingState):
    echo "MISSING ", RingState, " — run probe_replay_battle_scan first"
    quit(2)
  let (_, deltas) = parseReplay(Tas)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(RingState)), snes, c)
  echo fmt"ring {RingState} treated as f={RingFrame}"
  snap(snes, c, "ring")
  for f in RingFrame ..< FromFrame:
    snes.joy1 = joyAtFrame(deltas, f)
    stepFrame(snes, c, false, f)
  snap(snes, c, fmt"f={FromFrame - 1}")
  echo "---- promote-path window ----"
  for f in FromFrame .. ToFrame:
    snes.joy1 = joyAtFrame(deltas, f)
    echo fmt"==== f={f} joy1={snes.joy1:04X} ===="
    stepFrame(snes, c, true, f)
    snap(snes, c, fmt"f={f} end")
    if c.stopped:
      break
  echo "done."

when isMainModule:
  main()
