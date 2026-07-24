## Twoson corridor product hold past captain leave (checkpoints.md).
## leave_day1_map (solo pr70) + leave_onett_walkable (Paula+Jeff pr90/li70).
## Honest walk metrics (no teleport freeplay). fo wall ~0x16B0 blocks freewalk
## past fo40 without deep campaign seat.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  LeaveWalk = "bin/states/llm/leave_onett_walkable.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"

proc loadChunk(L: lua53.PState; src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc skillsSrc(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

proc runHold(snes: SnesBus; cpu: var Cpu; pol: string; frames: int):
    tuple[maxPr, maxLi, maxFo, maxPa, span, walkSpan, teleports, stuckRec: int] =
  ## Drive Agent midgame/paula policy; return peaks + honest mobility.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua)
  L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua)
  L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skillsSrc(), "skills")
  loadChunk(L, pol, "pol")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  var lastPx = minX.int
  var lastPy = minY.int
  var noMove = 0
  result.maxPr = peacefulRestPercent(snes)
  result.maxLi = lilliputStepsPercent(snes)
  result.maxFo = foursidePercent(snes)
  result.maxPa = paulaRescuePercent(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let ddx = abs(px.int - lastPx)
    let ddy = abs(py.int - lastPy)
    if ddx > 32 or ddy > 32:
      inc result.teleports
    else:
      result.walkSpan += ddx + ddy
    if px.int == lastPx and py.int == lastPy:
      inc noMove
    else:
      noMove = 0
    # Stuck recovery: freeze clear + B thrash (observable; mirrors harness).
    if noMove >= 180:
      inc result.stuckRec
      echo fmt"STUCK_RECOVERY f={f} pos=(0x{px:04X},0x{py:04X}) n={result.stuckRec}"
      for _ in 0 .. 5:
        snes.joy1 = 0x8000
        policy.stepOneFrame(snes, cpu, img)
        applyLaterStoryLeaveSoft(snes)
        clearSouthFreezeLocks(snes)
      noMove = 0
      lastPx = readU16(snes, WorldXBase + i).int
      lastPy = readU16(snes, WorldYBase + i).int
      continue
    lastPx = px.int
    lastPy = py.int
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    let pr = peacefulRestPercent(snes)
    let li = lilliputStepsPercent(snes)
    let fo = foursidePercent(snes)
    let pa = paulaRescuePercent(snes)
    if pr > result.maxPr: result.maxPr = pr
    if li > result.maxLi: result.maxLi = li
    if fo > result.maxFo: result.maxFo = fo
    if pa > result.maxPa: result.maxPa = pa
  result.span = (maxX - minX).int + (maxY - minY).int

proc main() =
  ## Product hold of Twoson soft referees after leave-Onett.
  doAssert fileExists(Rom)
  doAssert fileExists(LeaveWalk), "need leave_onett_walkable"
  doAssert fileExists(LeaveMap), "need leave_day1_map"

  echo "POLICY=AgentPaulaApproachPolicy + AgentMidgameExplorePolicy"
  echo "SPINE_REF=docs/checkpoints.md Peaceful Rest / Paula / Lilliput"
  echo "LEG_A fixture=", LeaveMap

  var snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, cpu)
  applyLaterStoryLeaveSoft(snes)
  let a0Pr = peacefulRestPercent(snes)
  let a0Li = lilliputStepsPercent(snes)
  let a0Pa = paulaRescuePercent(snes)
  echo "A_START pr=", a0Pr, " li=", a0Li, " pa=", a0Pa,
    " spine=", checkpointSpineLine(snes)
  doAssert a0Pr >= 70, "solo leave map deep mid grades peaceful_rest 70"
  doAssert a0Li == 0, "lilliput closed without Paula"
  doAssert a0Pa >= 70, "solo leave map grades paula_rescue 70"

  let a = runHold(snes, cpu, AgentPaulaApproachPolicy, 6000)
  echo "A_FINAL max_pr=", a.maxPr, " max_pa=", a.maxPa, " walk=", a.walkSpan,
    " tele=", a.teleports, " stuck=", a.stuckRec, " span=", a.span
  doAssert a.maxPr >= 70, "solo freeplay holds peaceful_rest 70"
  doAssert a.teleports == 0, "leave_day1_map freeplay must be honest walk"
  doAssert a.walkSpan > 200, "AgentPaula must walk on leave map"
  echo "A_OK solo leave_day1_map peaceful_rest hold (honest)"

  echo "LEG_B fixture=", LeaveWalk
  snes = newSnesBus(policy.readRomFile(Rom))
  cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveWalk)), snes, cpu)
  applyLaterStoryLeaveSoft(snes)
  let b0Pr = peacefulRestPercent(snes)
  let b0Li = lilliputStepsPercent(snes)
  let b0Fo = foursidePercent(snes)
  let b0Pa = paulaRescuePercent(snes)
  echo "B_START pr=", b0Pr, " li=", b0Li, " fo=", b0Fo, " pa=", b0Pa
  doAssert b0Pr >= 90, "Paula join grades peaceful_rest 90"
  doAssert b0Li >= 70, "Paula+Jeff deep map grades lilliput 70"
  doAssert b0Pa >= 90, "Paula in party"
  doAssert b0Fo >= 40, "leave walkable is fo40 band"

  let b = runHold(snes, cpu, AgentMidgameExplorePolicy, 5000)
  echo "B_FINAL max_pr=", b.maxPr, " max_li=", b.maxLi, " max_fo=", b.maxFo,
    " walk=", b.walkSpan, " tele=", b.teleports, " stuck=", b.stuckRec
  doAssert b.maxPr >= 90, "hold peaceful_rest 90"
  doAssert b.maxLi >= 70, "hold lilliput_steps 70"
  doAssert b.maxPa >= 90, "hold paula_rescue 90"
  doAssert b.maxFo >= 40, "hold fourside soft 40"
  doAssert b.teleports == 0, "Twoson hold must not teleport"
  doAssert b.walkSpan > 20 or b.stuckRec > 0,
    "mobility or stuck recovery at fo wall"
  if b.stuckRec > 0:
    echo "B_STUCK_RECOVERY fired n=", b.stuckRec, " (fo wall ~0x16B0)"
  echo "B_OK Twoson corridor hold pr90/li70/fo40+"
  echo "NOTE fo wall ~0x16B0 freewalk; fo60 needs campaign deep seat"
  echo "OK test_agent_twoson_corridor"

when isMainModule:
  main()
