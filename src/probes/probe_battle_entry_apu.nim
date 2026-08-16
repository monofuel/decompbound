## A/B test for the battle-entry headless abort ($98A5 stuck at phase 3 until
## the $5D7C 12-frame countdown fires): step the same pre-entry state with and
## without full-rate APU ticking (533 samples/frame, the play.nim/replay rate).
## If the APU-ticked run promotes past phase 3 while the bare run aborts, the
## abort is SPC starvation in the headless step path, not a missing RE flag.
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy]

const
  Rom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/live_battle_catch.state"
  SamplesPerFrame = 533

proc readU8(snes: SnesBus, off: int): int =
  ## WRAM byte at 7E:off.
  snes.bus.mem[0x7E0000 + off].int

proc readU16(snes: SnesBus, off: int): int =
  ## WRAM word at 7E:off.
  readU8(snes, off) or (readU8(snes, off + 1) shl 8)

proc runLeg(statePath: string, frames: int, tickApuFull: bool): string =
  ## Step `frames` from the state; return a one-line outcome summary.
  let rom = policy.readRomFile(Rom)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let label = if tickApuFull: "APU-533" else: "APU-none"
  var maxPhase = readU8(snes, 0x98A5)
  var promoted = false
  var battleLive = false
  for f in 0 ..< frames:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    if tickApuFull:
      for _ in 0 ..< SamplesPerFrame:
        discard snes.tickApu()
    let phase = readU8(snes, 0x98A5)
    let cnt = readU16(snes, 0x5D7C)
    let mode = (snes.ppuRegs[0x05] and 0x7).int
    let b4dba = readU16(snes, 0x4DBA)
    if phase > maxPhase: maxPhase = phase
    if f < 20 or f mod 60 == 0:
      let busy = readU16(snes, 0x5D9A)
      let g9883 = readU16(snes, 0x9883)
      let ring = readU16(snes, 0x5E04)
      echo &"[{label}] f={f} 98A5={phase} 5D7C={cnt:04X} mode={mode} 4DBA={b4dba:04X} " &
        &"5D9A={busy:04X} 9883={g9883:04X} 5E04={ring:04X} pc={c.pbr:02X}:{c.pc:04X}"
    if phase != 3 and phase != 0 and not promoted:
      promoted = true
      echo &"[{label}] PROMOTED: phase {phase} at f={f}"
    if b4dba != 0 and mode == 0:
      battleLive = true
    if c.stopped:
      echo &"[{label}] CPU STOPPED f={f}"
      break
  let txt = policy.getDialogueText(snes).strip()
  let battleTxt = policy.getBattleText(snes).strip()
  echo &"[{label}] end: 98A5={readU8(snes, 0x98A5)} 4DBA={readU16(snes, 0x4DBA):04X} " &
    &"mode={(snes.ppuRegs[0x05] and 0x7).int} battleLive={battleLive} " &
    &"battleTxt.len={battleTxt.len} txt.len={txt.len}"
  &"{label}: maxPhase={maxPhase} promoted={promoted} battleLive={battleLive}"

proc main() =
  let statePath = if paramCount() >= 1: paramStr(1) else: DefaultState
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 600
  if not fileExists(statePath):
    echo "MISSING state: ", statePath
    quit(2)
  echo "state: ", statePath, "  frames: ", frames
  let a = runLeg(statePath, frames, tickApuFull = false)
  let b = runLeg(statePath, frames, tickApuFull = true)
  echo "== VERDICT =="
  echo "  ", a
  echo "  ", b

when isMainModule:
  main()
