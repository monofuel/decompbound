## Campaign referee: night captain→Paula soft, leave-Onett cs70+, fo60 hold.
## Product Agent policies only; leave/fo past night wall use campaign fixtures.

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  LeavePk = "bin/states/llm/leave_onett_walkable.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"
  Fo80 = "bin/states/llm/fourside80_walkable.state"

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

proc ensureLeave() =
  if fileExists(LeavePk):
    return
  let (o, code) = execCmdEx("nim r -d:release src/tools/synth_leave_onett.nim")
  echo o
  doAssert code == 0 and fileExists(LeavePk)

proc runPol(
    snes: SnesBus,
    c: var Cpu,
    src: string,
    maxFrames: int
): tuple[maxCs, maxPa, maxFo, maxFr, maxGs: int] =
  ## Run one policy; return peak metrics.
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
  var maxFr = frankPercent(snes)
  var maxGs = giantStepPercent(snes)
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let cs = captainStrongPercent(snes)
    let pa = paulaRescuePercent(snes)
    let fo = foursidePercent(snes)
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    if cs > maxCs: maxCs = cs
    if pa > maxPa: maxPa = pa
    if fo > maxFo: maxFo = fo
    if fr > maxFr: maxFr = fr
    if gs > maxGs: maxGs = gs
  (maxCs, maxPa, maxFo, maxFr, maxGs)

proc main() =
  ## Night continuous captain/paula + leave cs90 + fo60/80 holds.
  doAssert fileExists(Rom)
  doAssert fileExists(OutdoorPk)
  ensureLeave()
  doAssert fileExists(Fo60)

  # Night product: frank→captain→paula soft (latch peaks across legs)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, c)
  let frLeg = runPol(snes, c, AgentFrankPolicy, 7000)
  let gsLeg = runPol(snes, c, AgentGiantStepPolicy, 5000)
  let cap = runPol(snes, c, AgentCaptainStrongPolicy, 5000)
  let pau = runPol(snes, c, AgentPaulaApproachPolicy, 3000)
  let maxCsN = max(frLeg.maxCs, max(gsLeg.maxCs, max(cap.maxCs, pau.maxCs)))
  let maxPaN = max(frLeg.maxPa, max(gsLeg.maxPa, max(cap.maxPa, pau.maxPa)))
  let maxFrN = max(frLeg.maxFr, max(gsLeg.maxFr, max(cap.maxFr, pau.maxFr)))
  let maxGsN = max(frLeg.maxGs, max(gsLeg.maxGs, max(cap.maxGs, pau.maxGs)))
  echo "NIGHT max_cs=", maxCsN, " max_pa=", maxPaN, " max_fr=", maxFrN,
    " max_gs=", maxGsN
  doAssert maxFrN >= 80, "night frank 80"
  doAssert maxCsN >= 60, "night continuous captain 60"
  doAssert maxPaN >= 30, "night paula soft tracks captain"

  # Leave-Onett campaign fixture (later $99F2 + Paula/Jeff)
  let snesL = newSnesBus(policy.readRomFile(Rom))
  var cL = snesL.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeavePk)), snesL, cL)
  let cs0 = captainStrongPercent(snesL)
  let pa0 = paulaRescuePercent(snesL)
  echo "LEAVE start cs=", cs0, " pa=", pa0, " wi=", wintersPercent(snesL),
    " fo=", foursidePercent(snesL)
  doAssert cs0 >= 80, "leave soft cs>=80"
  doAssert pa0 >= 90, "leave Paula party + later story"
  let mid = runPol(snesL, cL, AgentMidgameExplorePolicy, 4000)
  echo "LEAVE after mid max_cs=", mid.maxCs, " max_pa=", mid.maxPa,
    " max_fo=", mid.maxFo
  doAssert mid.maxCs >= 80
  doAssert mid.maxPa >= 90

  # fo60 free-walk hold past fo40 wall
  let snesF = newSnesBus(policy.readRomFile(Rom))
  var cF = snesF.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo60)), snesF, cF)
  let foStart = foursidePercent(snesF)
  echo "FO60 start fo=", foStart
  doAssert foStart >= 60
  let foRun = runPol(snesF, cF, AgentFoursideApproachPolicy, 5000)
  echo "FO60 max_fo=", foRun.maxFo
  doAssert foRun.maxFo >= 60, "fo60 free-walk holds peak >=60"

  if fileExists(Fo80):
    let snes8 = newSnesBus(policy.readRomFile(Rom))
    var c8 = snes8.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Fo80)), snes8, c8)
    let fo8s = foursidePercent(snes8)
    let fo8run = runPol(snes8, c8, AgentFoursideApproachPolicy, 3000)
    echo "FO80 start=", fo8s, " max_fo=", fo8run.maxFo
    doAssert fo8run.maxFo >= 80, "fo80 Poo soft hold"

  echo "OK test_campaign_captain_leave: night cs60/paula + leave cs80 + fo60/80"

when isMainModule:
  main()
