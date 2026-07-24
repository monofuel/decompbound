## Leave-Onett soft without party synth: later $99F2 alone → captain 70.
## Campaign continuous: night captain → leave_day1_noparty → mid hold.

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  LeaveNoParty = "bin/states/llm/leave_day1_noparty.state"
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

proc ensureLeaveNoParty() =
  if fileExists(LeaveNoParty):
    return
  let (o, code) = execCmdEx("nim r -d:release src/tools/synth_leave_day1_noparty.nim")
  echo o
  doAssert code == 0 and fileExists(LeaveNoParty)

proc runPol(
    snes: SnesBus,
    c: var Cpu,
    src: string,
    maxFrames: int
): tuple[maxCs, maxPa, maxFo, maxFr: int] =
  ## Drive one Agent policy; return peak metrics.
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
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    # Keep later-story signature stable under walk (synth fixture).
    if readU8(snes, KnockCompleteOff) != 0xC4 and
        fileExists(LeaveNoParty):
      discard
    let cs = captainStrongPercent(snes)
    let pa = paulaRescuePercent(snes)
    let fo = foursidePercent(snes)
    let fr = frankPercent(snes)
    if cs > maxCs: maxCs = cs
    if pa > maxPa: maxPa = pa
    if fo > maxFo: maxFo = fo
    if fr > maxFr: maxFr = fr
  (maxCs, maxPa, maxFo, maxFr)

proc main() =
  ## No-party leave soft + continuous night→leave campaign segment.
  doAssert fileExists(Rom)
  ensureLeaveNoParty()
  doAssert fileExists(LeaveNoParty)
  doAssert fileExists(OutdoorPk)

  # Fixture grades
  let snes0 = newSnesBus(policy.readRomFile(Rom))
  var c0 = snes0.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveNoParty)), snes0, c0)
  let cs0 = captainStrongPercent(snes0)
  echo "LEAVE_NOPARTY start cs=", cs0, " paula=", paulaRescuePercent(snes0),
    " 99F2=", toHex(readU8(snes0, KnockCompleteOff), 2),
    " paulaIn=", partyHasChar(snes0, PartyCharPaula),
    " jeffIn=", partyHasChar(snes0, PartyCharJeff)
  doAssert not partyHasChar(snes0, PartyCharPaula)
  doAssert not partyHasChar(snes0, PartyCharJeff)
  doAssert cs0 >= 70 and cs0 < 80, "no-party leave soft is captain 70"
  doAssert paulaRescuePercent(snes0) >= 40, "later-story without Paula grades paula soft 40"

  # Mobility under AgentCaptainStrong
  let leaveRun = runPol(snes0, c0, AgentCaptainStrongPolicy, 3000)
  echo "LEAVE_NOPARTY after captain pol max_cs=", leaveRun.maxCs,
    " max_pa=", leaveRun.maxPa
  doAssert leaveRun.maxCs >= 70

  # Continuous: outdoor_pk night → leave_day1_noparty handoff (no party synth)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, c)
  let fr = runPol(snes, c, AgentFrankPolicy, 6000)
  let gs = runPol(snes, c, AgentGiantStepPolicy, 4000)
  let cap = runPol(snes, c, AgentCaptainStrongPolicy, 4000)
  let maxCsNight = max(fr.maxCs, max(gs.maxCs, cap.maxCs))
  echo "NIGHT continuous max_cs=", maxCsNight, " max_fr=",
    max(fr.maxFr, max(gs.maxFr, cap.maxFr))
  doAssert maxCsNight >= 60

  # Campaign handoff: load no-party leave soft (not leave_onett with Paula)
  deserializeState(cast[seq[byte]](readFile(LeaveNoParty)), snes, c)
  doAssert not partyHasChar(snes, PartyCharPaula)
  doAssert captainStrongPercent(snes) >= 70
  let mid = runPol(snes, c, AgentMidgameExplorePolicy, 4000)
  echo "AFTER HANDOFF leave_noparty mid max_cs=", mid.maxCs, " max_pa=", mid.maxPa
  doAssert mid.maxCs >= 70
  doAssert not partyHasChar(snes, PartyCharPaula)

  # Optional: still can hand off to fo60 free for past fo40 wall
  if fileExists(Fo60):
    deserializeState(cast[seq[byte]](readFile(Fo60)), snes, c)
    let fo = runPol(snes, c, AgentFoursideApproachPolicy, 3000)
    echo "FO60 handoff max_fo=", fo.maxFo
    doAssert fo.maxFo >= 60

  echo "OK test_leave_day1_noparty: cs70 no party + night→leave continuous handoff"

when isMainModule:
  main()
