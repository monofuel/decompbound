## Drive Ness into an overworld enemy via joy1 and trace $0065 / $C0404F on
## a FRESH $98A5 0→3 battle entry. The lookup reads absolute $0065 (joy1 held),
## not DP $65 at $1E07. Holding a D-pad nibble is the promotion condition.
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/touch_grass

const
  Rom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/buzz_meteor.state"
  PadRight = 0x0100'u16
  PadLeft = 0x0200'u16
  PadDown = 0x0400'u16
  PadUp = 0x0800'u16
  LookupEntry = 0x404F
  LookupReturn = 0x4AC8
  WriterPad = 0x8453
  WriterHeld = 0x84BD
  RemapperSta = 0x2D24
  TickEntry = 0x4AAD
  Phase2Store = 0x66A4
  MaxWalkFrames = 2400
  TraceFramesAfterEntry = 24
  CandidateStates = [
    "bin/states/llm/buzz_meteor.state",
    "bin/states/llm/leave_onett_walkable.state",
    "bin/states/llm/onett_start.state",
    "bin/states/llm/midgame_wander.state",
    "bin/states/llm/post_battle_midgame.state",
    "bin/states/llm/frank_downtown.state",
    "bin/states/llm/giant_approach.state",
  ]
  GroupBase = 0x2C9A
  TypeBase = 0x2B6E

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

proc nibbleOk(v: int): bool =
  ## True if $C0404F accepts this D-pad nibble.
  (v and 0x0F00) in [0x0800, 0x0900, 0x0100, 0x0500, 0x0400, 0x0600, 0x0200, 0x0A00]

proc playerPos(snes: SnesBus): (int, int) =
  ## Slot-24 world X/Y.
  let i = PlayerSlot * SlotIndexStride
  (readU16(snes, WorldXBase + i), readU16(snes, WorldYBase + i))

proc listEntities(snes: SnesBus) =
  ## Print active slots with group/type/sprite.
  let (px, py) = playerPos(snes)
  echo fmt"player slot24 pos=(0x{px:04X},0x{py:04X})"
  for s in 0 ..< 30:
    let i = s * SlotIndexStride
    let x = readU16(snes, WorldXBase + i)
    let y = readU16(snes, WorldYBase + i)
    if (x == 0 and y == 0) or x == 0xFFFF:
      continue
    let
      grp = wram16(snes, GroupBase + i)
      typ = wram16(snes, TypeBase + i)
      spr = wram16(snes, 0x2CD6 + i)
      man = abs(x - px) + abs(y - py)
    echo fmt"  slot={s:2} pos=(0x{x:04X},0x{y:04X}) man={man} " &
      fmt"$2C9A={grp:04X} $2B6E={typ:04X} $2CD6={spr:04X}"

proc pickEnemy(snes: SnesBus): int =
  ## Nearest non-player slot with a nonzero $2C9A group, else nearest body.
  let (px, py) = playerPos(snes)
  var
    bestGroup = -1
    bestGroupMan = high(int)
    bestAny = -1
    bestAnyMan = high(int)
  for s in 0 ..< 30:
    if s == PlayerSlot:
      continue
    let i = s * SlotIndexStride
    let x = readU16(snes, WorldXBase + i)
    let y = readU16(snes, WorldYBase + i)
    if (x == 0 and y == 0) or x == 0xFFFF:
      continue
    let man = abs(x - px) + abs(y - py)
    let grp = wram16(snes, GroupBase + i)
    if man < bestAnyMan:
      bestAny = s
      bestAnyMan = man
    if grp != 0 and grp != 0xFFFF and man < bestGroupMan:
      bestGroup = s
      bestGroupMan = man
  if bestGroup >= 0:
    return bestGroup
  bestAny

proc towardJoy(snes: SnesBus, slot: int): uint16 =
  ## D-pad toward entity `slot`.
  let (px, py) = playerPos(snes)
  let i = slot * SlotIndexStride
  let
    dx = readU16(snes, WorldXBase + i) - px
    dy = readU16(snes, WorldYBase + i) - py
  var joy = 0'u16
  if dx > 2:
    joy = joy or PadRight
  elif dx < -2:
    joy = joy or PadLeft
  if dy > 2:
    joy = joy or PadDown
  elif dy < -2:
    joy = joy or PadUp
  if joy == 0:
    joy = PadRight
  joy

proc snap(snes: SnesBus, c: Cpu, tag: string) =
  ## One-line live snapshot.
  let
    v65 = wram16(snes, 0x0065)
    (px, py) = playerPos(snes)
  echo fmt"{tag} 98A5={wram(snes, 0x98A5)} 5D7C={wram16(snes, 0x5D7C):04X} " &
    fmt"4DBA={wram16(snes, 0x4DBA):04X} mode={(snes.ppuRegs[0x05] and 0x7).int} " &
    fmt"$0065={v65:04X}({nibbleName(v65)} ok={nibbleOk(v65)}) " &
    fmt"$1E07={wram16(snes, 0x1E07):04X} $0077={wram16(snes, 0x0077):04X} " &
    fmt"9883={wram16(snes, 0x9883):04X} 987F={wram16(snes, 0x987F):04X} " &
    fmt"5D9E={wram16(snes, 0x5D9E):04X} 5DA0={wram16(snes, 0x5DA0):04X} " &
    fmt"pos=(0x{px:04X},0x{py:04X}) joy1={snes.joy1:04X} PC={c.pbr:02X}:{c.pc:04X}"

proc loadState(path: string): (SnesBus, Cpu) =
  ## Load ROM + save-state.
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  (snes, c)

proc pickState(): string =
  ## Prefer an explicit argv state; else first candidate with a $2C9A group.
  if paramCount() >= 1 and fileExists(paramStr(1)):
    return paramStr(1)
  for path in CandidateStates:
    if not fileExists(path):
      continue
    let (snes, _) = loadState(path)
    if pickEnemy(snes) >= 0 and wram16(snes, GroupBase + pickEnemy(snes) * 2) notin [0, 0xFFFF]:
      echo fmt"auto-picked {path} (has $2C9A group)"
      return path
  echo "no $2C9A group found; falling back to ", DefaultState
  DefaultState

proc traceEntry(snes: SnesBus, c: var Cpu, frames: int) =
  ## Instruction-trace a few frames after 0→3, watching lookup + writers.
  var
    line = 0
    samples = 0
    lookupHits = 0
    padHits = 0
    heldHits = 0
    remapHits = 0
    tickHits = 0
    prev65 = wram16(snes, 0x0065)
  echo "---- instruction trace after 0->3 ----"
  for step in 0 ..< frames * policy.InstrPerLine * 262:
    if c.pbr == 0xC0 and c.pc == TickEntry:
      inc tickHits
      echo fmt"  tick#{tickHits} D={c.d:04X} 5D7C={wram16(snes, 0x5D7C):04X} " &
        fmt"9883={wram16(snes, 0x9883):04X} $0065={wram16(snes, 0x0065):04X}"
    if c.pbr == 0xC0 and c.pc == LookupEntry:
      inc lookupHits
      let
        arg = c.a.int and 0xFFFF
        v65 = wram16(snes, 0x0065)
        v1e = wram16(snes, 0x1E07)
      echo fmt"  lookup#{lookupHits} A={arg:04X} callerD={c.d:04X} DBR={c.dbr:02X} " &
        fmt"$0065={v65:04X}({nibbleName(v65)} ok={nibbleOk(v65)}) $1E07={v1e:04X}"
    if c.pbr == 0xC0 and c.pc == LookupReturn:
      echo fmt"  lookup-ret A={c.a.int and 0xFFFF:04X} $0065={wram16(snes, 0x0065):04X}"
    if c.pbr == 0xC4 and c.pc == Phase2Store:
      echo fmt"  PHASE2 STA $98A5 A={c.a.int and 0xFFFF:04X}"
    if c.pbr == 0xC0 and c.pc == WriterPad:
      inc padHits
    if c.pbr == 0xC0 and c.pc == WriterHeld:
      inc heldHits
    if c.pbr == 0xC0 and c.pc == RemapperSta:
      inc remapHits
      echo fmt"  remapper STA $0065 A={c.a:04X} $5D9E={wram16(snes, 0x5D9E):04X}"
    let now65 = wram16(snes, 0x0065)
    if now65 != prev65:
      echo fmt"  $0065 {prev65:04X}->{now65:04X} at PC={c.pbr:02X}:{c.pc:04X} step={step}"
      prev65 = now65
    cpu.step(c, snes.bus)
    inc line
    if line >= policy.InstrPerLine:
      line = 0
      if samples < 224:
        snes.runHdma()
      for _ in 0 ..< 2:
        discard snes.tickApu()
      inc samples
      if samples == 224 and (snes.nmitimen and 0x80) != 0:
        c.nmiPending = true
      if samples >= 262:
        samples = 0
        snes.initHdma()
    if c.stopped:
      echo "  CPU STOPPED"
      break
  echo fmt"  hits: tick={tickHits} lookup={lookupHits} $4218copy={padHits} " &
    fmt"STA $65,X={heldHits} remapper={remapHits}"

proc main() =
  let path = pickState()
  if not fileExists(path):
    echo "MISSING ", path
    quit(2)
  echo "state: ", path
  let (snes, c0) = loadState(path)
  var c = c0
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  listEntities(snes)
  let target = pickEnemy(snes)
  if target < 0:
    echo "no walkable entity"
    quit(2)
  echo fmt"target slot={target} $2C9A={wram16(snes, GroupBase + target * 2):04X}"
  snap(snes, c, "f=0")
  var
    prevPhase = wram(snes, 0x98A5)
    prev65 = wram16(snes, 0x0065)
    entryAt = -1
    lastJoy = 0'u16
  for f in 0 ..< MaxWalkFrames:
    if target >= 0:
      lastJoy = towardJoy(snes, target)
    snes.joy1 = lastJoy
    policy.stepOneFrame(snes, c, img)
    let
      phase = wram(snes, 0x98A5)
      v65 = wram16(snes, 0x0065)
      mode = (snes.ppuRegs[0x05] and 0x7).int
    if v65 != prev65 or phase != prevPhase or f mod 60 == 0:
      snap(snes, c, fmt"f={f}")
    if prevPhase != 3 and phase == 3 and entryAt < 0:
      entryAt = f
      echo fmt"ENTRY {prevPhase}->{phase} at f={f} $0065={v65:04X}({nibbleName(v65)} ok={nibbleOk(v65)}) " &
        fmt"joy1={lastJoy:04X}"
      prev65 = v65
      prevPhase = phase
      traceEntry(snes, c, TraceFramesAfterEntry)
      snap(snes, c, "after-trace")
      echo fmt"done. entryAt={entryAt} final 98A5={wram(snes, 0x98A5)} " &
        fmt"mode={mode} 4DBA={wram16(snes, 0x4DBA):04X} " &
        fmt"battleTxt.len={policy.getBattleText(snes).strip().len}"
      return
    if phase != 3 and phase != 0:
      echo fmt"PROMOTED phase={phase} at f={f} without seeing 3"
      snap(snes, c, fmt"f={f}")
      return
    prev65 = v65
    prevPhase = phase
    if c.stopped:
      echo fmt"CPU STOPPED f={f}"
      break
  echo fmt"NO ENTRY in {MaxWalkFrames} frames. last 98A5={wram(snes, 0x98A5)}"
  snap(snes, c, "end")

when isMainModule:
  main()
