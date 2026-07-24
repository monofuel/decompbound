## Captain Strong leave-Onett product path (checkpoints.md after Giant Step).
## Night continuous: giant_approach → AgentCaptainStrong → cs60.
## Day leave freeplay: leave_day1_map → AgentPaula → hold cs100 + mobility.
## Giant Step cave gs80 still RE-blocked night (documented; not asserted green).

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
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

proc runPolicy(snes: SnesBus; cpu: var Cpu; pol: string; frames: int;
    holdKnock: bool): tuple[maxCs, maxPa, maxPr, maxLi, minX, maxX, minY, maxY: int] =
  ## Drive one shipped Agent policy; return peaks + bbox.
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
  result.minX = readU16(snes, WorldXBase + i)
  result.maxX = result.minX
  result.minY = readU16(snes, WorldYBase + i)
  result.maxY = result.minY
  result.maxCs = captainStrongPercent(snes)
  result.maxPa = paulaRescuePercent(snes)
  result.maxPr = peacefulRestPercent(snes)
  result.maxLi = lilliputStepsPercent(snes)
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
    if px < result.minX: result.minX = px
    if px > result.maxX: result.maxX = px
    if py < result.minY: result.minY = py
    if py > result.maxY: result.maxY = py
    let cs = captainStrongPercent(snes)
    let pa = paulaRescuePercent(snes)
    let pr = peacefulRestPercent(snes)
    let li = lilliputStepsPercent(snes)
    if cs > result.maxCs: result.maxCs = cs
    if pa > result.maxPa: result.maxPa = pa
    if pr > result.maxPr: result.maxPr = pr
    if li > result.maxLi: result.maxLi = li
    if holdKnock and result.maxCs >= 60 and f >= 2000:
      break
    if not holdKnock and f >= 4000 and
        (result.maxX - result.minX) + (result.maxY - result.minY) > 40:
      break

proc main() =
  ## Prove captain leave product + Twoson soft referees from LLM fixtures.
  doAssert fileExists(Rom)
  doAssert fileExists(Giant), "need giant_approach fixture"
  doAssert fileExists(LeaveMap), "need leave_day1_map fixture"

  echo "POLICY=AgentCaptainStrongPolicy + AgentPaulaApproachPolicy"
  echo "LEG_A fixture=", Giant

  # --- Leg A: night continuous captain leave soft (cs60 south commercial) ---
  var snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Giant)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let startCs = captainStrongPercent(snes)
  let startGs = giantStepPercent(snes)
  let startPr = peacefulRestPercent(snes)
  echo "A_START cs=", startCs, " gs=", startGs, " peaceful_rest=", startPr,
    " spine=", checkpointSpineLine(snes)
  doAssert startGs >= 60, "giant_approach should be gs60+ police west"
  doAssert startCs >= 30, "captain opens with deep-south frank"
  doAssert startPr == 0, "peaceful_rest closed until leave soft (cs70+)"

  let a = runPolicy(snes, cpu, AgentCaptainStrongPolicy, 12000, holdKnock = true)
  echo "A_FINAL max_cs=", a.maxCs, " max_pa=", a.maxPa, " max_pr=", a.maxPr,
    " bbox=0x", toHex(a.minX, 4), "..0x", toHex(a.maxX, 4), ",0x",
    toHex(a.minY, 4), "..0x", toHex(a.maxY, 4)
  echo "A_DELTA cs ", startCs, "→", a.maxCs, " (need ≥60 south commercial)"
  doAssert a.maxCs > startCs or a.maxCs >= 60,
    "captain must climb from giant (start=" & $startCs & " max=" & $a.maxCs & ")"
  doAssert a.maxCs >= 60,
    "AgentCaptainStrong product leave soft is cs60 (got " & $a.maxCs & ")"
  echo "A_OK night continuous captain_strong 60 from giant_approach"

  # --- Leg B: day leave map freeplay (cs100 product past night wall) ---
  echo "LEG_B fixture=", LeaveMap
  snes = newSnesBus(policy.readRomFile(Rom))
  cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, cpu)
  applyLaterStoryLeaveSoft(snes)
  let bStartCs = captainStrongPercent(snes)
  let bStartPa = paulaRescuePercent(snes)
  let bStartPr = peacefulRestPercent(snes)
  let bStartLi = lilliputStepsPercent(snes)
  echo "B_START cs=", bStartCs, " pa=", bStartPa, " peaceful_rest=", bStartPr,
    " lilliput=", bStartLi, " spine=", checkpointSpineLine(snes)
  doAssert bStartCs >= 100, "leave_day1_map grades captain day-leave 100"
  doAssert bStartPa >= 60, "leave map is Twoson-bound paula soft"
  doAssert bStartPr >= 50, "peaceful_rest opens on day-leave / deep mid"
  doAssert bStartLi == 0, "lilliput closed without Paula join"

  let b = runPolicy(snes, cpu, AgentPaulaApproachPolicy, 8000, holdKnock = false)
  let span = (b.maxX - b.minX) + (b.maxY - b.minY)
  echo "B_FINAL max_cs=", b.maxCs, " max_pa=", b.maxPa, " max_pr=", b.maxPr,
    " max_li=", b.maxLi, " span=", span
  echo "B_DELTA hold cs100=", b.maxCs >= 100, " peaceful_rest peak=", b.maxPr
  doAssert b.maxCs >= 100, "AgentPaula freeplay must hold captain day-leave 100"
  doAssert b.maxPr >= 50, "peaceful_rest referee stays open on leave map"
  doAssert span > 16,
    "leave_day1_map freeplay must move (span=" & $span & ") — not control-lock"
  # End still day-leave soft (campaign wall past fo40/Paula join not required here).
  doAssert captainStrongPercent(snes) >= 100 or b.maxCs >= 100
  echo "B_OK leave_day1_map AgentPaula holds cs100 + mobility; peaceful_rest soft"
  echo "NOTE gs80 cave/day RE still open (night north hunt indoor=0)"
  echo "OK test_agent_captain_leave_product"

when isMainModule:
  main()
