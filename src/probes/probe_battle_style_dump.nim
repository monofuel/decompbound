## Dump $0065 (absolute joy1-held) vs the misread $1E07 DP local, then A/B
## hold-direction vs joy1=0 on doomed phase-3 fixtures. $C0404F reads
## `LDA $0065` (opcode AD 65 00, absolute) and decodes the D-pad nibble.
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy]

const
  Rom = "bin/Earthbound (U) [!].smc"
  PadUp = 0x0800'u16
  PadRight = 0x0100'u16
  States = [
    "bin/states/live_battle_catch.state",
    "bin/states/battle_fixture.state",
    "bin/states/slot1_battle.state",
    "bin/states/battle_menu_healthy.state",
    "bin/states/llm/buzz_meteor.state",
    "bin/states/llm/replay_pre_ring.state",
    "bin/states/llm/onett_start.state",
    "bin/states/llm/leave_onett_walkable.state",
    "bin/states/llm/midgame_wander.state",
    "bin/states/llm/post_battle_midgame.state",
  ]

proc wram(snes: SnesBus, off: int): int =
  ## WRAM byte at 7E:off.
  snes.bus.mem[0x7E0000 + (off and 0xFFFF)].int

proc wram16(snes: SnesBus, off: int): int =
  ## WRAM word at 7E:off.
  wram(snes, off) or (wram(snes, off + 1) shl 8)

proc nibbleName(v: int): string =
  ## Name the $0F00 D-pad nibble, or "none".
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

proc nibbleOk(v: int): bool =
  ## True if $C0404F would accept this word's D-pad nibble.
  (v and 0x0F00) in [0x0800, 0x0900, 0x0100, 0x0500, 0x0400, 0x0600, 0x0200, 0x0A00]

proc snap(snes: SnesBus, c: Cpu, tag: string) =
  ## One-line WRAM snapshot.
  let
    v65 = wram16(snes, 0x0065)
    v1e07 = wram16(snes, 0x1E07)
    v6d = wram16(snes, 0x006D)
    v77 = wram16(snes, 0x0077)
  echo fmt"{tag} 98A5={wram(snes, 0x98A5)} 5D7C={wram16(snes, 0x5D7C):04X} " &
    fmt"4DBA={wram16(snes, 0x4DBA):04X} mode={(snes.ppuRegs[0x05] and 0x7).int} " &
    fmt"$0065={v65:04X}({nibbleName(v65)}) $1E07={v1e07:04X}({nibbleName(v1e07)}) " &
    fmt"$006D={v6d:04X} $0077={v77:04X} 9883={wram16(snes, 0x9883):04X} " &
    fmt"987F={wram16(snes, 0x987F):04X} 5D9A={wram16(snes, 0x5D9A):04X} " &
    fmt"5D9E={wram16(snes, 0x5D9E):04X} 5DA0={wram16(snes, 0x5DA0):04X} " &
    fmt"$81={wram16(snes, 0x0081):04X} joy1={snes.joy1:04X} " &
    fmt"ok65={nibbleOk(v65)} D={c.d:04X} DBR={c.dbr:02X} PC={c.pbr:02X}:{c.pc:04X}"

proc loadState(path: string): (SnesBus, Cpu) =
  ## Load ROM + save-state.
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  (snes, c)

proc runHold(path: string, joy: uint16, frames: int, label: string) =
  ## Step `frames` with a constant joy1; print changes and the end snap.
  if not fileExists(path):
    echo fmt"MISSING {path}"
    return
  let (snes, c0) = loadState(path)
  var c = c0
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  echo fmt"---- {label} joy1={joy:04X} ----"
  snap(snes, c, "f=-1")
  var
    prev65 = wram16(snes, 0x0065)
    prevPhase = wram(snes, 0x98A5)
    prevCnt = wram16(snes, 0x5D7C)
    promoted = false
    aborted = false
  for f in 0 ..< frames:
    snes.joy1 = joy
    policy.stepOneFrame(snes, c, img)
    let
      v65 = wram16(snes, 0x0065)
      phase = wram(snes, 0x98A5)
      cnt = wram16(snes, 0x5D7C)
      mode = (snes.ppuRegs[0x05] and 0x7).int
    if v65 != prev65 or phase != prevPhase or cnt != prevCnt or f < 16 or f mod 30 == 0:
      snap(snes, c, fmt"f={f}")
    if phase != 3 and phase != 0 and not promoted:
      promoted = true
      echo fmt"PROMOTED phase={phase} at f={f} $0065={v65:04X} mode={mode}"
    if prevPhase == 3 and phase == 0 and wram16(snes, 0x4DBA) == 0 and mode != 0:
      aborted = true
      echo fmt"ABORTED to overworld at f={f}"
    prev65 = v65
    prevPhase = phase
    prevCnt = cnt
    if c.stopped:
      echo fmt"CPU STOPPED f={f}"
      break
  echo fmt"end {label}: promoted={promoted} aborted={aborted} " &
    fmt"battleTxt.len={policy.getBattleText(snes).strip().len}"

proc main() =
  echo "=== fixture snaps ==="
  for path in States:
    if not fileExists(path):
      echo "MISSING ", path
      continue
    let (snes, c) = loadState(path)
    snap(snes, c, path.extractFilename)

  echo ""
  echo "=== A/B hold on doomed phase-3 fixtures ==="
  for path in ["bin/states/live_battle_catch.state",
               "bin/states/battle_fixture.state",
               "bin/states/slot1_battle.state"]:
    runHold(path, 0, 40, path.extractFilename & "/joy0")
    runHold(path, PadUp, 40, path.extractFilename & "/joyUP")
    runHold(path, PadRight, 40, path.extractFilename & "/joyR")

when isMainModule:
  main()
