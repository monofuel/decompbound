## Capture $C0404F's real return (A at $C04AC8) on a doomed phase-3 fixture
## while $0065 is the live joy1-held word. Also watch $C466A4 (phase-2 store).
import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, policy]

const
  Rom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/live_battle_catch.state"
  LookupEntry = 0x404F
  LookupReturn = 0x4AC8
  TickEntry = 0x4AAD
  Phase2Store = 0x66A4
  MaxSteps = 8_000_000

proc wram(snes: SnesBus, off: int): int =
  ## WRAM byte at 7E:off.
  snes.bus.mem[0x7E0000 + (off and 0xFFFF)].int

proc wram16(snes: SnesBus, off: int): int =
  ## WRAM word at 7E:off.
  wram(snes, off) or (wram(snes, off + 1) shl 8)

proc main() =
  let
    statePath = if paramCount() >= 1: paramStr(1) else: DefaultState
    hold = if paramCount() >= 2: uint16(parseHexInt(paramStr(2))) else: 0x0800'u16
  let rom = policy.readRomFile(Rom)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, c)
  snes.joy1 = hold
  echo fmt"state={statePath} hold={hold:04X} $0065={wram16(snes, 0x0065):04X} " &
    fmt"$1E07={wram16(snes, 0x1E07):04X} 98A5={wram(snes, 0x98A5)} " &
    fmt"5D7C={wram16(snes, 0x5D7C):04X}"
  var
    ticks = 0
    lookups = 0
    rets = 0
    phase2 = 0
    line = 0
  for step in 0 ..< MaxSteps:
    if c.pbr == 0xC0 and c.pc == TickEntry:
      inc ticks
      echo fmt"tick#{ticks} D={c.d:04X} 5D7C={wram16(snes, 0x5D7C):04X} " &
        fmt"9883={wram16(snes, 0x9883):04X} $0065={wram16(snes, 0x0065):04X} " &
        fmt"98A5={wram(snes, 0x98A5)}"
    if c.pbr == 0xC0 and c.pc == LookupEntry:
      inc lookups
      echo fmt"lookup#{lookups} A={c.a.int and 0xFFFF:04X} D={c.d:04X} DBR={c.dbr:02X} " &
        fmt"$0065={wram16(snes, 0x0065):04X} $1E07={wram16(snes, 0x1E07):04X} " &
        fmt"5D9A={wram16(snes, 0x5D9A):04X}"
    if c.pbr == 0xC0 and c.pc == LookupReturn:
      inc rets
      echo fmt"ret#{rets} A={c.a.int and 0xFFFF:04X} $0065={wram16(snes, 0x0065):04X}"
      if rets >= 14:
        break
    if c.pbr == 0xC4 and c.pc == Phase2Store:
      inc phase2
      echo fmt"PHASE2#{phase2} A={c.a.int and 0xFFFF:04X}"
    cpu.step(c, snes.bus)
    inc line
    if line >= policy.InstrPerLine * 262:
      line = 0
      snes.initHdma()
      if (snes.nmitimen and 0x80) != 0:
        c.nmiPending = true
      snes.joy1 = hold
    if c.stopped:
      echo "CPU STOPPED"
      break
  echo fmt"done ticks={ticks} lookups={lookups} rets={rets} phase2={phase2} " &
    fmt"98A5={wram(snes, 0x98A5)} 5D7C={wram16(snes, 0x5D7C):04X}"

when isMainModule:
  main()
