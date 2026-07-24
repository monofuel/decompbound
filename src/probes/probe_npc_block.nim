## Headless repro + verify: outdoor followTrail stall when an NPC sits on the trail.
##
## Loads onett_start (player at house door), pins a solid outdoor entity mid-leg
## south of the door on the crater corridor, drives a short followTrail, and logs
## stuck frames / recovery thrash.
##
## Runs TWICE: once with _npc_sidestep_enabled=false (baseline thrash) and once
## with the default enabled (fix). Entity X/Y rewritten every frame so AI cannot
## walk the pin away.
##
## Usage:
##   nim r -d:release --hints:off src/probes/probe_npc_block.nim

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ./touch_grass

const
  RomPath = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/onett_start.state"
  SettleFrames = 30
  MaxFrames = 700
  BlockSlot = 2
  ## Mid-leg on the first outdoor corridor segment (south of door).
  ## Player natural start (0x0A60,0x0158); direct drive SW hits this body.
  NpcPinX = 0x0A58
  NpcPinY = 0x0168
  ## Short trail from door through pin region then further south (route samples).
  TrailPts = [
    (0x0A60, 0x0158),
    (0x0A4A, 0x0192),
    (0x0A09, 0x01BA),
  ]
  StallLogEvery = 40

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and run a Lua chunk; raise on error.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, "load " & label & ": " & $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, "pcall " & label & ": " & $L.toString(-1))

proc playerPos(snes: SnesBus): (int, int) =
  ## Slot-24 world position.
  let i = PlayerSlot * SlotIndexStride
  (readU16(snes, WorldXBase + i), readU16(snes, WorldYBase + i))

proc setEntityPos(snes: SnesBus, slot, x, y: int) =
  ## Write entity world X/Y at $0B8E/$0BCA + slot*2.
  let i = slot * SlotIndexStride
  let xa = 0x7E0000 + WorldXBase + i
  let ya = 0x7E0000 + WorldYBase + i
  snes.bus.mem[xa] = uint8(x and 0xFF)
  snes.bus.mem[xa + 1] = uint8(x shr 8)
  snes.bus.mem[ya] = uint8(y and 0xFF)
  snes.bus.mem[ya + 1] = uint8(y shr 8)

proc entityPos(snes: SnesBus, slot: int): (int, int) =
  ## Read entity world X/Y.
  let i = slot * SlotIndexStride
  (readU16(snes, WorldXBase + i), readU16(snes, WorldYBase + i))

proc skillsSrc(): string =
  ## Inline skills from touch_grass (same set outdoor drive uses).
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua & "\n" &
    FollowTrailSkillLua & "\n" & NamedRoutesLua

proc trailLuaTable(): string =
  ## Lua table literal for TrailPts.
  result = "{"
  for i, p in TrailPts:
    if i > 0: result.add ","
    result.add &"{{x=0x{p[0]:04X},y=0x{p[1]:04X}}}"
  result.add "}"

type
  RunStats = object
    label: string
    arrivedF: int
    maxFrozen: int
    totalFrozen: int
    maxStall: int
    totalStall: int
    maxY: int
    finalX, finalY: int
    toEnd: int
    firstFreeze: int

proc runOnce(label: string; sidestepOn: bool): RunStats =
  ## One pinned-NPC followTrail drive; return stall / arrive stats.
  result.label = label
  result.arrivedF = -1
  result.firstFreeze = -1

  let snes = newSnesBus(policy.readRomFile(RomPath))
  var c = snes.resetCpu()
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  for i in 0 .. SettleFrames:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)

  let typeOff = 0x7E0000 + 0x2B6E + BlockSlot * 2
  snes.bus.mem[typeOff] = 5
  snes.bus.mem[typeOff + 1] = 0
  setEntityPos(snes, BlockSlot, NpcPinX, NpcPinY)

  let (px0, py0) = playerPos(snes)
  let (ex0, ey0) = entityPos(snes, BlockSlot)
  echo &"\n=== {label} sidestep={sidestepOn} ==="
  echo &"  START player=(0x{px0:04X},0x{py0:04X}) npc_s{BlockSlot}=(0x{ex0:04X},0x{ey0:04X})"
  echo &"  pin=(0x{NpcPinX:04X},0x{NpcPinY:04X}) trail_end=(0x{TrailPts[^1][0]:04X},0x{TrailPts[^1][1]:04X})"

  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  if L == nil:
    raise newException(ValueError, "lua newstate nil")
  defer: L.close()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, skillsSrc(), "skills")
  let en = if sidestepOn: "true" else: "false"
  let policySrc = &"""
_npc_sidestep_enabled = {en}
_npc_trail = {trailLuaTable()}
_npc_probe = {{done = false}}
function update()
  if followTrail(_npc_trail) then
    return
  end
  _npc_probe.done = true
end
"""
  loadChunk(L, policySrc, "npc_block_policy")

  var
    bestToEnd = abs(px0 - TrailPts[^1][0]) + abs(py0 - TrailPts[^1][1])
    stallRun = 0
    prevX = px0
    prevY = py0
    frozenRun = 0
    lastLogStall = -1

  result.maxY = py0

  for f in 0 ..< MaxFrames:
    setEntityPos(snes, BlockSlot, NpcPinX, NpcPinY)
    snes.bus.mem[typeOff] = 5
    snes.bus.mem[typeOff + 1] = 0

    ctx.frameCount = f
    ctx.joy1 = 0
    let err = policy.runPolicyFrame(L, ctx)
    if err.len > 0 and f mod 200 == 0:
      echo &"  ERR f={f}: {err}"
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)

    let (px, py) = playerPos(snes)
    if py > result.maxY: result.maxY = py
    # Indoor teleport = test contaminated (door eat); treat as fail.
    if px >= 0x1C00:
      echo &"  DOOR_ENTER f={f} pos=(0x{px:04X},0x{py:04X}) — abort run"
      break

    let toEnd = abs(px - TrailPts[^1][0]) + abs(py - TrailPts[^1][1])
    let moved = abs(px - prevX) + abs(py - prevY)

    if moved == 0:
      inc frozenRun
      inc result.totalFrozen
      if frozenRun > result.maxFrozen:
        result.maxFrozen = frozenRun
      if result.firstFreeze < 0 and frozenRun >= 8:
        result.firstFreeze = f - frozenRun + 1
    else:
      frozenRun = 0

    if toEnd < bestToEnd:
      bestToEnd = toEnd
      stallRun = 0
    else:
      inc stallRun
      inc result.totalStall
      if stallRun > result.maxStall:
        result.maxStall = stallRun

    if stallRun >= 40 and stallRun != lastLogStall and stallRun mod StallLogEvery == 0:
      lastLogStall = stallRun
      echo &"  STALL f={f} pos=(0x{px:04X},0x{py:04X}) toEnd={toEnd} " &
        &"stallRun={stallRun} frozenRun={frozenRun} maxY=0x{result.maxY:04X}"

    if f mod 100 == 0 or (f < 50 and f mod 25 == 0):
      echo &"  f={f:4} p=(0x{px:04X},0x{py:04X}) toEnd={toEnd} " &
        &"stall={stallRun} frozen={frozenRun} maxY=0x{result.maxY:04X}"

    L.getglobal("_npc_probe")
    L.getfield(-1, "done")
    let done = L.toboolean(-1) != 0
    L.pop(2)
    if done:
      result.arrivedF = f
      echo &"  ARRIVED f={f} pos=(0x{px:04X},0x{py:04X}) toEnd={toEnd} maxY=0x{result.maxY:04X}"
      break

    prevX = px
    prevY = py

  let (pxF, pyF) = playerPos(snes)
  result.finalX = pxF
  result.finalY = pyF
  result.toEnd = abs(pxF - TrailPts[^1][0]) + abs(pyF - TrailPts[^1][1])
  echo &"  SUMMARY arrived={result.arrivedF} max_frozen={result.maxFrozen} " &
    &"total_frozen={result.totalFrozen} max_stall={result.maxStall} " &
    &"maxY=0x{result.maxY:04X} final=(0x{pxF:04X},0x{pyF:04X}) toEnd={result.toEnd}"
  if result.arrivedF >= 0 and result.maxFrozen < 30:
    echo &"  RESULT: CLEAN_ARRIVE frames={result.arrivedF}"
  elif result.arrivedF >= 0:
    echo &"  RESULT: ARRIVED_WITH_STALL max_frozen={result.maxFrozen}"
  else:
    echo "  RESULT: STALLED"

proc main() =
  ## Baseline (no sidestep) then fixed (sidestep on); print comparison.
  if not fileExists(RomPath):
    echo "SKIP: no ROM at ", RomPath
    quit(0)
  if not fileExists(Outdoor):
    echo "SKIP: no state at ", Outdoor
    quit(0)

  let base = runOnce("BASELINE", sidestepOn = false)
  let fixed = runOnce("FIXED", sidestepOn = true)

  echo "\n======== COMPARISON ========"
  echo &"  BASELINE: arrived={base.arrivedF} max_frozen={base.maxFrozen} " &
    &"total_frozen={base.totalFrozen} max_stall={base.maxStall} maxY=0x{base.maxY:04X}"
  echo &"  FIXED:    arrived={fixed.arrivedF} max_frozen={fixed.maxFrozen} " &
    &"total_frozen={fixed.totalFrozen} max_stall={fixed.maxStall} maxY=0x{fixed.maxY:04X}"
  if fixed.arrivedF >= 0 and (base.arrivedF < 0 or fixed.maxFrozen < base.maxFrozen div 2):
    echo "  VERDICT: sidestep reduces/eliminates NPC path stall"
  elif fixed.arrivedF >= 0 and base.arrivedF >= 0 and fixed.arrivedF <= base.arrivedF:
    echo "  VERDICT: both arrive; fixed is not slower"
  else:
    echo "  VERDICT: needs more work"

when isMainModule:
  main()
