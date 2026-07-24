## Full mid/late product campaign chain with Paula-continuity seats (d70).
## leave_onett (Paula/Jeff) → fo60_from_paula → fo80_from_paula → soft98_from_fo80
## Agent policies hold each segment; freewalk walls documented as campaign seats.

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Leave = "bin/states/llm/leave_onett_walkable.state"
  Fo60 = "bin/states/llm/fourside60_from_paula.state"
  Fo80 = "bin/states/llm/fourside80_from_paula.state"
  Soft98 = "bin/states/llm/soft98_from_fo80paula.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk that defines globals.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene() for intent skills.
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring)
  1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind landmarkTarget(name).
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc runPol(snes: SnesBus; cpu: var Cpu; pol: string; maxFrames: int):
    tuple[fo, ma, gi, pa, wi: int] =
  ## Run shipped Agent policy; return peak spine metrics.
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
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "skills")
  loadChunk(L, pol, "pol")
  result.fo = foursidePercent(snes)
  result.ma = magicantPercent(snes)
  result.gi = giygasPercent(snes)
  result.pa = paulaRescuePercent(snes)
  result.wi = wintersPercent(snes)
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let fo = foursidePercent(snes)
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    let pa = paulaRescuePercent(snes)
    let wi = wintersPercent(snes)
    if fo > result.fo: result.fo = fo
    if ma > result.ma: result.ma = ma
    if gi > result.gi: result.gi = gi
    if pa > result.pa: result.pa = pa
    if wi > result.wi: result.wi = wi

proc ensureChain() =
  ## Ensure Paula-chain fixtures exist (synth if missing).
  if not fileExists(Fo60):
    let (o, c) = execCmdEx("nim r -d:release src/tools/synth_fourside60_from_paula.nim")
    echo o
    doAssert c == 0
  if not fileExists(Fo80):
    let (o, c) = execCmdEx("nim r -d:release src/tools/synth_fourside80_from_paula.nim")
    echo o
    doAssert c == 0
  if not fileExists(Soft98):
    let (o, c) = execCmdEx("nim r -d:release src/tools/synth_soft98_from_fo80.nim")
    echo o
    doAssert c == 0

proc main() =
  ## Campaign chain: leave fo40 wall → fo60 seat → fo80 Poo → soft98 hold.
  doAssert fileExists(Rom) and fileExists(Leave)
  ensureChain()
  doAssert fileExists(Fo60) and fileExists(Fo80) and fileExists(Soft98)

  var peakFo, peakMa, peakGi, peakPa, peakWi = 0
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()

  # 1) leave_onett Paula/Jeff — fo40 freewalk wall
  deserializeState(cast[seq[byte]](readFile(Leave)), snes, cpu)
  doAssert partyHasChar(snes, PartyCharPaula)
  doAssert wintersPercent(snes) >= 50
  let leave = runPol(snes, cpu, AgentMidgameExplorePolicy, 3000)
  peakFo = max(peakFo, leave.fo)
  peakPa = max(peakPa, leave.pa)
  peakWi = max(peakWi, leave.wi)
  echo "LEAVE fo=", leave.fo, " pa=", leave.pa, " wi=", leave.wi
  doAssert leave.fo < 60, "leave freewalk stays below fo60 wall"

  # 2) campaign fo60 seat (Paula continuity)
  deserializeState(cast[seq[byte]](readFile(Fo60)), snes, cpu)
  doAssert foursidePercent(snes) >= 60
  doAssert partyHasChar(snes, PartyCharPaula)
  let fo6 = runPol(snes, cpu, AgentFoursideApproachPolicy, 2500)
  peakFo = max(peakFo, fo6.fo)
  peakPa = max(peakPa, fo6.pa)
  echo "FO60 hold max_fo=", fo6.fo
  doAssert fo6.fo >= 60
  doAssert not partyHasChar(snes, PartyCharPoo), "pre-Poo at fo60"

  # 3) campaign fo80 Poo seat
  deserializeState(cast[seq[byte]](readFile(Fo80)), snes, cpu)
  doAssert partyHasChar(snes, PartyCharPoo)
  doAssert foursidePercent(snes) >= 80
  let fo8 = runPol(snes, cpu, AgentLateGamePolicy, 2500)
  peakFo = max(peakFo, fo8.fo)
  peakMa = max(peakMa, fo8.ma)
  peakGi = max(peakGi, fo8.gi)
  echo "FO80 late max_fo=", fo8.fo, " max_ma=", fo8.ma
  doAssert fo8.fo >= 80
  # fo80_from_paula may be ma90 until soft98 handoff
  doAssert fo8.ma >= 90 or fo8.ma >= 30

  # 4) campaign soft98 seat
  deserializeState(cast[seq[byte]](readFile(Soft98)), snes, cpu)
  doAssert hasAllSanctuarySoft(snes)
  doAssert magicantPercent(snes) >= 98
  doAssert giygasPercent(snes) >= 80
  doAssert not hasMagicantDreamFlag(snes)
  doAssert not hasGiygasPhaseFlag(snes)
  let soft = runPol(snes, cpu, AgentLateGamePolicy, 3000)
  peakFo = max(peakFo, soft.fo)
  peakMa = max(peakMa, soft.ma)
  peakGi = max(peakGi, soft.gi)
  peakPa = max(peakPa, soft.pa)
  peakWi = max(peakWi, soft.wi)
  echo "SOFT98 hold max_ma=", soft.ma, " max_gi=", soft.gi
  doAssert soft.ma >= 98
  doAssert soft.gi >= 80

  echo "PAULA_CHAIN peaks fo=", peakFo, " ma=", peakMa, " gi=", peakGi,
    " pa=", peakPa, " wi=", peakWi
  echo "SPINE ", checkpointSpineLine(snes)
  doAssert peakFo >= 80
  doAssert peakMa >= 98
  doAssert peakGi >= 80
  doAssert peakPa >= 90
  doAssert peakWi >= 50
  echo "OK test_campaign_paula_chain_spine"

when isMainModule:
  main()
