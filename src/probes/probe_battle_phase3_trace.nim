## Breakpoint trace for the battle phase-3 tick ($C04AAD..$C04B52): single-step
## from a pre-entry state, and when PC reaches the $C0404F lookup entry capture
## the caller's D so the `LDA $0065` direct-page operand resolves to its true
## WRAM address. Answers WHY the lookup returns $FFFF headless (context nibble
## vs the $C3E12C bitmask) without needing a human capture.
import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, policy]

const
  Rom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/live_battle_catch.state"
  LookupEntry = 0x404F
  TickEntry = 0x4AAD
  MaxSteps = 40_000_000

proc wram(snes: SnesBus, off: int): int =
  ## WRAM byte at 7E:off.
  snes.bus.mem[0x7E0000 + (off and 0xFFFF)].int

proc wram16(snes: SnesBus, off: int): int =
  ## WRAM word at 7E:off.
  wram(snes, off) or (wram(snes, off + 1) shl 8)

proc main() =
  let statePath = if paramCount() >= 1: paramStr(1) else: DefaultState
  let rom = policy.readRomFile(Rom)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, c)
  var tickHits = 0
  var lookupHits = 0
  var line = 0
  var prevCtx = wram16(snes, 0x1E07)
  echo fmt"ctx $1E07 initial={prevCtx:04X}"
  for step in 0 ..< MaxSteps:
    let ctxNow = wram16(snes, 0x1E07)
    if ctxNow != prevCtx:
      echo fmt"ctx $1E07 {prevCtx:04X}->{ctxNow:04X} at PC={c.pbr:02X}:{c.pc:04X} step={step}"
      prevCtx = ctxNow
    if c.pbr == 0xC0 and c.pc == TickEntry:
      inc tickHits
      echo fmt"tick#{tickHits}: D={c.d:04X} 5D7C={wram16(snes, 0x5D7C):04X} 9883={wram16(snes, 0x9883):04X}"
    if c.pbr == 0xC0 and c.pc == LookupEntry:
      inc lookupHits
      # Inside the lookup D shifts by -0x12; `LDA $0065` reads (D-0x12+0x65)&0xFFFF.
      let opAddr = (c.d.int - 0x12 + 0x65) and 0xFFFF
      let opVal = wram16(snes, opAddr)
      let arg = c.a.int and 0xFFFF
      let maskOff = 0x3E12C + 2 * arg
      echo fmt"lookup#{lookupHits}: A(arg 9883)={arg:04X} callerD={c.d:04X} " &
        fmt"ctxAddr=${opAddr:04X} ctxVal={opVal:04X} nibble={(opVal and 0x0F00):04X} " &
        fmt"mask(C3E12C[{arg}])={rom[maskOff].int or (rom[maskOff+1].int shl 8):04X}"
      if lookupHits >= 12:
        break
    cpu.step(c, snes.bus)
    if c.stopped:
      echo fmt"CPU STOPPED at step {step}"
      break
    # Approximate frame boundary bookkeeping so NMI still fires while tracing.
    inc line
    if line >= policy.InstrPerLine * 262:
      line = 0
      snes.initHdma()
      if (snes.nmitimen and 0x80) != 0:
        c.nmiPending = true
  echo fmt"done: tickHits={tickHits} lookupHits={lookupHits}"

when isMainModule:
  main()
