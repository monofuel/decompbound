## Product day-1 → Twoson with campaign seats only at known freeplay walls.
## 1) Continuous outdoor Frank/Giant peaks (fr80+, gs60+).
## 2) Campaign giant_approach if gs70 not free (south freeze RE).
## 3) Captain cs60 → leave_day1_map hold → leave_onett Twoson soft hold.
## Intent/scene Agent policies; metrics as referees (checkpoints.md).

import
  std/[os],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
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

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    holdKnock: bool; stopCs, stopGs, stopFr: int):
    tuple[maxFr, maxGs, maxCs, maxPr, maxLi, span: int] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skillsSrc(), "skills")
  loadChunk(L, pol, "pol")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  result.maxFr = frankPercent(snes)
  result.maxGs = giantStepPercent(snes)
  result.maxCs = captainStrongPercent(snes)
  result.maxPr = peacefulRestPercent(snes)
  result.maxLi = lilliputStepsPercent(snes)
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if holdKnock:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
      clearSouthFreezeLocks(snes)
    else:
      applyLaterStoryLeaveSoft(snes)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    let cs = captainStrongPercent(snes)
    let pr = peacefulRestPercent(snes)
    let li = lilliputStepsPercent(snes)
    if fr > result.maxFr: result.maxFr = fr
    if gs > result.maxGs: result.maxGs = gs
    if cs > result.maxCs: result.maxCs = cs
    if pr > result.maxPr: result.maxPr = pr
    if li > result.maxLi: result.maxLi = li
    if stopFr > 0 and result.maxFr >= stopFr and f >= 1800: break
    if stopGs > 0 and result.maxGs >= stopGs and f >= 1800: break
    if stopCs > 0 and result.maxCs >= stopCs and f >= 1800: break
  result.span = (maxX - minX) + (maxY - minY)

proc main() =
  ## Full soft product path day-1 Onett through Twoson referees.
  doAssert fileExists(Rom)
  for p in [Outdoor, Giant, LeaveMap, LeaveWalk]:
    doAssert fileExists(p), "missing " & p

  echo "PRODUCT_SPINE=outdoor→(campaign giant)→captain→leave→twoson"
  echo "SPINE_REF=docs/checkpoints.md"

  # Leg 1 continuous outdoor
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let o1 = runPol(snes, c, AgentFrankPolicy, 9000, true, 0, 0, 80)
  echo "L1_FRANK maxFr=", o1.maxFr, " maxGs=", o1.maxGs, " maxCs=", o1.maxCs
  doAssert o1.maxFr >= 80
  clearSouthFreezeLocks(snes)
  let o2 = runPol(snes, c, AgentGiantStepPolicy, 8000, true, 0, 70, 0)
  echo "L1_GIANT maxGs=", o2.maxGs, " maxCs=", o2.maxCs
  # d85: freeze clear ($10E5/$10E7) enables continuous gs70 without campaign seat.
  doAssert o2.maxGs >= 70, "continuous outdoor gs70 after freeze-clear"
  var peakGs = max(o1.maxGs, o2.maxGs)
  var peakCs = max(o1.maxCs, o2.maxCs)

  # Legacy campaign handoff only if freeze-clear path regressed.
  if peakGs < 70:
    echo "CAMPAIGN_HANDOFF giant_approach (unexpected — freeze-clear should unlock)"
    snes = newSnesBus(policy.readRomFile(Rom))
    c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Giant)), snes, c)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    doAssert giantStepPercent(snes) >= 60
    peakGs = max(peakGs, giantStepPercent(snes))

  let cap = runPol(snes, c, AgentCaptainStrongPolicy, 10000, true, 60, 0, 0)
  echo "L2_CAPTAIN maxCs=", cap.maxCs, " maxGs=", cap.maxGs
  doAssert cap.maxCs >= 60
  peakCs = max(peakCs, cap.maxCs)

  # Leg 3 day leave campaign seat (night wall)
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  let lv = runPol(snes, c, AgentPaulaApproachPolicy, 5000, false, 0, 0, 0)
  echo "L3_LEAVE maxCs=", lv.maxCs, " maxPr=", lv.maxPr, " span=", lv.span
  doAssert lv.maxCs >= 100 and lv.maxPr >= 70 and lv.span > 16

  # Leg 4 Twoson party corridor
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveWalk)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  let tw = runPol(snes, c, AgentMidgameExplorePolicy, 5000, false, 0, 0, 0)
  echo "L4_TWOSON maxPr=", tw.maxPr, " maxLi=", tw.maxLi, " span=", tw.span
  doAssert tw.maxPr >= 90 and tw.maxLi >= 70 and tw.span > 20

  echo "PEAKS outdoor_fr>=80 outdoor_gs=", peakGs, " cs=", peakCs,
    " leave_pr=", lv.maxPr, " twoson_pr=", tw.maxPr, " twoson_li=", tw.maxLi
  echo "OK test_agent_product_day1_to_twoson"

when isMainModule:
  main()
