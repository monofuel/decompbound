## Product multileg soft day-1 → Twoson corridor (checkpoints.md spine).
## Night: giant_approach → AgentCaptain → cs60.
## Day leave: leave_day1_map → AgentPaula hold cs100/pr70.
## Party corridor: leave_onett_walkable → AgentMidgame hold pr90/li70/fo40.
## Intent/scene policies only; no trail-only outdoor body.

import
  std/[os],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"
  LeaveWalk = "bin/states/llm/leave_onett_walkable.state"

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

type Peak = object
  maxCs, maxPr, maxPa, maxLi, maxFo, span: int

proc runPol(snes: SnesBus; cpu: var Cpu; pol: string; frames: int;
    holdKnock: bool): Peak =
  ## Run shipped Agent policy; return metric peaks + mobility span.
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
  result.maxCs = captainStrongPercent(snes)
  result.maxPr = peacefulRestPercent(snes)
  result.maxPa = paulaRescuePercent(snes)
  result.maxLi = lilliputStepsPercent(snes)
  result.maxFo = foursidePercent(snes)
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    if holdKnock:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    else:
      applyLaterStoryLeaveSoft(snes)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    let cs = captainStrongPercent(snes)
    let pr = peacefulRestPercent(snes)
    let pa = paulaRescuePercent(snes)
    let li = lilliputStepsPercent(snes)
    let fo = foursidePercent(snes)
    if cs > result.maxCs: result.maxCs = cs
    if pr > result.maxPr: result.maxPr = pr
    if pa > result.maxPa: result.maxPa = pa
    if li > result.maxLi: result.maxLi = li
    if fo > result.maxFo: result.maxFo = fo
    if holdKnock and result.maxCs >= 60 and f >= 1500:
      break
  result.span = (maxX - minX) + (maxY - minY)

proc main() =
  ## Multileg soft spine: captain leave → Twoson soft referees.
  doAssert fileExists(Rom)
  doAssert fileExists(Giant) and fileExists(LeaveMap) and fileExists(LeaveWalk)

  echo "POLICY=AgentCaptainStrong + AgentPaula + AgentMidgame"
  echo "SPINE_REF=docs/checkpoints.md Captain → Peaceful Rest → Paula → Lilliput soft"

  # Leg 1 night captain
  var snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Giant)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let s1 = captainStrongPercent(snes)
  echo "L1_START cs=", s1, " gs=", giantStepPercent(snes)
  let p1 = runPol(snes, cpu, AgentCaptainStrongPolicy, 10000, holdKnock = true)
  echo "L1_FINAL max_cs=", p1.maxCs, " span=", p1.span
  doAssert p1.maxCs >= 60, "leg1 captain leave soft 60"

  # Leg 2 solo day leave (campaign seat — night wall unreproducible)
  snes = newSnesBus(policy.readRomFile(Rom))
  cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, cpu)
  applyLaterStoryLeaveSoft(snes)
  echo "L2_START cs=", captainStrongPercent(snes), " pr=", peacefulRestPercent(snes)
  let p2 = runPol(snes, cpu, AgentPaulaApproachPolicy, 5000, holdKnock = false)
  echo "L2_FINAL max_cs=", p2.maxCs, " max_pr=", p2.maxPr, " span=", p2.span
  doAssert p2.maxCs >= 100 and p2.maxPr >= 70 and p2.span > 16

  # Leg 3 party Twoson corridor
  snes = newSnesBus(policy.readRomFile(Rom))
  cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveWalk)), snes, cpu)
  applyLaterStoryLeaveSoft(snes)
  echo "L3_START pr=", peacefulRestPercent(snes), " li=", lilliputStepsPercent(snes),
    " fo=", foursidePercent(snes)
  let p3 = runPol(snes, cpu, AgentMidgameExplorePolicy, 5000, holdKnock = false)
  echo "L3_FINAL max_pr=", p3.maxPr, " max_li=", p3.maxLi, " max_fo=", p3.maxFo,
    " span=", p3.span
  doAssert p3.maxPr >= 90 and p3.maxLi >= 70 and p3.maxFo >= 40 and p3.span > 20

  echo "PEAKS night_cs=", p1.maxCs, " leave_pr=", p2.maxPr,
    " twoson_pr=", p3.maxPr, " twoson_li=", p3.maxLi, " twoson_fo=", p3.maxFo
  echo "OK test_agent_day1_twoson_spine"

when isMainModule:
  main()
