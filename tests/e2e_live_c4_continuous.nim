## Product continuous leave soft: outdoor_pk → frank/captain → live C4 poke
## (no fixture reload, no party synth) → captain 70 + Paula soft hold.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"

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
    holdLater = false
): tuple[maxCs, maxPa, maxFr, maxGs: int] =
  ## Drive one Agent policy; optionally re-apply later-story leave soft each frame.
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
  var maxFr = frankPercent(snes)
  var maxGs = giantStepPercent(snes)
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if holdLater:
      applyLaterStoryLeaveSoft(snes)
    let cs = captainStrongPercent(snes)
    let pa = paulaRescuePercent(snes)
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    if cs > maxCs: maxCs = cs
    if pa > maxPa: maxPa = pa
    if fr > maxFr: maxFr = fr
    if gs > maxGs: maxGs = gs
  (maxCs, maxPa, maxFr, maxGs)

proc main() =
  ## Continuous outdoor→cs60 then live C4 → cs70 without fixture reload/party.
  doAssert fileExists(Rom)
  doAssert fileExists(OutdoorPk)

  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, c)
  doAssert knockComplete(snes)
  doAssert not laterStoryLeaveSoft(snes)

  let fr = runPol(snes, c, AgentFrankPolicy, 7000)
  let gs = runPol(snes, c, AgentGiantStepPolicy, 5000)
  # Captain needs long rejoin from giant_west (px~0x08F0) to south road (d66).
  let cap = runPol(snes, c, AgentCaptainStrongPolicy, 8000)
  let maxCsNight = max(fr.maxCs, max(gs.maxCs, cap.maxCs))
  echo "NIGHT continuous max_cs=", maxCsNight, " max_fr=",
    max(fr.maxFr, max(gs.maxFr, cap.maxFr)), " max_gs=",
    max(fr.maxGs, max(gs.maxGs, cap.maxGs))
  doAssert maxCsNight >= 50, "night product path must open captain soft (got " &
    $maxCsNight & ")"
  # Prefer cs60 south commercial; if west peel only hit 50, still proceed to C4.
  if maxCsNight < 60:
    echo "NOTE night max_cs=", maxCsNight, " (<60) — continue with live C4"
  doAssert knockComplete(snes) or laterStoryLeaveSoft(snes)

  # Product campaign live C4 (same helper as llm_ai --campaign-fixtures).
  let csBefore = captainStrongPercent(snes)
  applyLaterStoryLeaveSoft(snes)
  doAssert laterStoryLeaveSoft(snes)
  doAssert not partyHasChar(snes, PartyCharPaula)
  doAssert not partyHasChar(snes, PartyCharJeff)
  let csAfter = captainStrongPercent(snes)
  echo "LIVE_C4 before_cs=", csBefore, " after_cs=", csAfter,
    " 99F2=", toHex(readU8(snes, KnockCompleteOff), 2)
  doAssert csAfter >= 70, "live C4 must grade leave soft captain>=70"
  doAssert csAfter < 80, "without Paula, captain stays <80"

  # Continue product path with Paula policy while holding later-story byte.
  doAssert paulaRescuePercent(snes) >= 50, "C4 leave soft grades paula >=50"
  let pau = runPol(snes, c, AgentPaulaApproachPolicy, 4000, holdLater = true)
  echo "AFTER Paula hold max_cs=", pau.maxCs, " max_pa=", pau.maxPa
  doAssert pau.maxCs >= 70
  doAssert pau.maxPa >= 50, "paula leave soft hold >=50 after C4"
  doAssert not partyHasChar(snes, PartyCharPaula)
  doAssert laterStoryLeaveSoft(snes)

  echo "OK test_live_c4_continuous: outdoor→cs soft→live C4→cs70/pa50 no fixture/party"

when isMainModule:
  main()
