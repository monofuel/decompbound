## Campaign spine: live C4 leave soft → Paula-join fixture (cs80/paula90) → fo60.
## Exercises the product handoff order shipped in llm_ai --campaign-fixtures.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  LeavePaula = "bin/states/llm/leave_onett_walkable.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring)
  1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc skillsSrc(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua &
    "\n" & NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua &
    "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

proc runPol(
    snes: SnesBus,
    c: var Cpu,
    src: string,
    maxFrames: int,
    holdC4 = false
): tuple[maxCs, maxPa, maxFo, maxWi, maxFr: int] =
  ## Drive one policy; optional later-story hold.
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
  loadChunk(L, skillsSrc(), "sk")
  loadChunk(L, src, "pol")
  var maxCs = captainStrongPercent(snes)
  var maxPa = paulaRescuePercent(snes)
  var maxFo = foursidePercent(snes)
  var maxWi = wintersPercent(snes)
  var maxFr = frankPercent(snes)
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if holdC4:
      applyLaterStoryLeaveSoft(snes)
    let cs = captainStrongPercent(snes)
    let pa = paulaRescuePercent(snes)
    let fo = foursidePercent(snes)
    let wi = wintersPercent(snes)
    let fr = frankPercent(snes)
    if cs > maxCs: maxCs = cs
    if pa > maxPa: maxPa = pa
    if fo > maxFo: maxFo = fo
    if wi > maxWi: maxWi = wi
    if fr > maxFr: maxFr = fr
  (maxCs, maxPa, maxFo, maxWi, maxFr)

proc main() =
  ## Night → live C4 → Paula join fixture → mid → fo60 product handoff order.
  doAssert fileExists(Rom) and fileExists(OutdoorPk)
  doAssert fileExists(LeavePaula) and fileExists(Fo60)

  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, c)

  let fr = runPol(snes, c, AgentFrankPolicy, 6000)
  # Long captain rejoin after west gs peel (d66).
  let cap = runPol(snes, c, AgentCaptainStrongPolicy, 8000)
  let maxCsNight = max(fr.maxCs, cap.maxCs)
  echo "NIGHT max_cs=", maxCsNight, " max_fr=", max(fr.maxFr, cap.maxFr)
  doAssert maxCsNight >= 50, "night captain soft open (got " & $maxCsNight & ")"

  applyLaterStoryLeaveSoft(snes)
  doAssert captainStrongPercent(snes) >= 70
  doAssert paulaRescuePercent(snes) >= 50
  doAssert not partyHasChar(snes, PartyCharPaula)
  echo "LIVE_C4 cs=", captainStrongPercent(snes), " pa=", paulaRescuePercent(snes)

  let pauHold = runPol(snes, c, AgentPaulaApproachPolicy, 2000, holdC4 = true)
  echo "PAULA soft hold cs=", pauHold.maxCs, " pa=", pauHold.maxPa
  doAssert pauHold.maxCs >= 70
  doAssert pauHold.maxPa >= 50

  # Campaign segment: Paula join (leave_onett_walkable)
  deserializeState(cast[seq[byte]](readFile(LeavePaula)), snes, c)
  doAssert partyHasChar(snes, PartyCharPaula)
  let csJoin = captainStrongPercent(snes)
  let paJoin = paulaRescuePercent(snes)
  let wiJoin = wintersPercent(snes)
  echo "PAULA_JOIN fixture cs=", csJoin, " pa=", paJoin, " wi=", wiJoin
  doAssert csJoin >= 80
  doAssert paJoin >= 90

  let mid = runPol(snes, c, AgentMidgameExplorePolicy, 3000)
  echo "MID after join max_cs=", mid.maxCs, " max_pa=", mid.maxPa,
    " max_wi=", mid.maxWi, " max_fo=", mid.maxFo
  doAssert mid.maxCs >= 80
  doAssert mid.maxPa >= 90

  deserializeState(cast[seq[byte]](readFile(Fo60)), snes, c)
  let fo = runPol(snes, c, AgentFoursideApproachPolicy, 3000)
  echo "FO60 hold max_fo=", fo.maxFo
  doAssert fo.maxFo >= 60

  echo "OK test_campaign_c4_paula_join: C4→Paula90→fo60 campaign spine"

when isMainModule:
  main()
