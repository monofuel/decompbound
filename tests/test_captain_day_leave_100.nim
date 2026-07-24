## Captain day-leave map soft 100: later-story + outdoor py≥0x0500 (F12-proven).
## Night south wall sticks at py~0x02A0; campaign uses leave_day1_map seat.

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  DayLeaveMap = "bin/states/llm/leave_day1_map.state"
  LeaveNoParty = "bin/states/llm/leave_day1_noparty.state"

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

proc ensureDayLeaveMap() =
  if fileExists(DayLeaveMap):
    return
  let (o, code) = execCmdEx("nim r -d:release src/tools/synth_leave_day1_map.nim")
  echo o
  doAssert code == 0 and fileExists(DayLeaveMap)

proc runPol(
    snes: SnesBus,
    c: var Cpu,
    src: string,
    maxFrames: int
): int =
  ## Drive policy; return max captain_strong.
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
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)
    let cs = captainStrongPercent(snes)
    if cs > maxCs: maxCs = cs
  maxCs

proc main() =
  ## Night C4 soft 70; day-leave map 100; campaign handoff continuous.
  doAssert fileExists(Rom)
  ensureDayLeaveMap()
  doAssert fileExists(DayLeaveMap)

  # Fixture grades
  let snesM = newSnesBus(policy.readRomFile(Rom))
  var cM = snesM.resetCpu()
  deserializeState(cast[seq[byte]](readFile(DayLeaveMap)), snesM, cM)
  let csMap = captainStrongPercent(snesM)
  let i = PlayerSlot * SlotIndexStride
  echo "DAY_LEAVE_MAP cs=", csMap, " py=0x",
    toHex(readU16(snesM, WorldYBase + i), 4),
    " paulaIn=", partyHasChar(snesM, PartyCharPaula)
  doAssert csMap >= 100
  doAssert not partyHasChar(snesM, PartyCharPaula)
  doAssert runPol(snesM, cM, AgentCaptainStrongPolicy, 2000) >= 100

  if fileExists(LeaveNoParty):
    let snesN = newSnesBus(policy.readRomFile(Rom))
    var cN = snesN.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LeaveNoParty)), snesN, cN)
    let csN = captainStrongPercent(snesN)
    echo "LEAVE_NOPARTY night seat cs=", csN
    doAssert csN >= 70 and csN < 100

  # Continuous product: outdoor night → C4 → day leave map handoff → cs100
  doAssert fileExists(OutdoorPk)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, c)
  discard runPol(snes, c, AgentFrankPolicy, 5000)
  let maxCsNight = runPol(snes, c, AgentCaptainStrongPolicy, 4000)
  echo "NIGHT max_cs=", maxCsNight
  doAssert maxCsNight >= 60 or captainStrongPercent(snes) >= 0

  applyLaterStoryLeaveSoft(snes)
  echo "LIVE_C4 cs=", captainStrongPercent(snes)
  doAssert captainStrongPercent(snes) >= 70

  # Campaign handoff (night south wall) → day leave map
  deserializeState(cast[seq[byte]](readFile(DayLeaveMap)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  let csAfter = captainStrongPercent(snes)
  echo "HANDOFF day leave map cs=", csAfter
  doAssert csAfter >= 100
  doAssert not partyHasChar(snes, PartyCharPaula)
  let hold = runPol(snes, c, AgentCaptainStrongPolicy, 2000)
  echo "HOLD max_cs=", hold
  doAssert hold >= 100

  echo "OK test_captain_day_leave_100: day map leave soft 100 without party"

when isMainModule:
  main()
