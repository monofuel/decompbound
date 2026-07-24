## d98: next unfinished spine past soft ceilings — captain freeplay story,
## leave freewalk peaks, midgame continuous, giant day cave re-probe.
## Intent/scene policies only (no trail outdoor body).

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
  Leave = "bin/states/llm/leave_day1_map.state"
  Mid = "bin/states/llm/midgame_approach.state"
  MidDeep = "bin/states/llm/midgame_deep.state"
  LateBest = "bin/states/llm/campaign_late_best.state"
  Soft98 = "bin/states/llm/poo_soft98_walkable.state"

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

proc skills(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

type Track = object
  maxCs, maxGs, maxPr, maxPa, maxLi, maxWi, maxBe, maxFo, maxMa, maxDd: int
  maxBp, walk, tele, stuck: int
  stories: seq[int]
  indoorHits: int

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    holdKnock = false; forceLater = false; holdDay = false): Track =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skills(), "skills")
  loadChunk(L, pol, "pol")
  let i = PlayerSlot * SlotIndexStride
  var lastPx = readU16(snes, WorldXBase + i).int
  var lastPy = readU16(snes, WorldYBase + i).int
  var lastStory = readU8(snes, KnockCompleteOff).int
  var stagnant = 0
  result.stories = @[lastStory]
  result.maxCs = captainStrongPercent(snes)
  result.maxGs = giantStepPercent(snes)
  result.maxPr = peacefulRestPercent(snes)
  result.maxPa = paulaRescuePercent(snes)
  result.maxLi = lilliputStepsPercent(snes)
  result.maxWi = wintersPercent(snes)
  result.maxBe = belchPercent(snes)
  result.maxFo = foursidePercent(snes)
  result.maxMa = magicantPercent(snes)
  result.maxDd = deepDarknessPercent(snes)
  result.maxBp = eventFlagBitPop(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if holdKnock:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      if holdDay:
        applyDayStoryOpen(snes)
      else:
        snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    if forceLater:
      applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    let st = readU8(snes, KnockCompleteOff).int
    if st != lastStory:
      result.stories.add st
      lastStory = st
      echo fmt"STORY_CHANGE f={f} $99F2=0x{st:02X} cs={captainStrongPercent(snes)}"
    let px = readU16(snes, WorldXBase + i).int
    let py = readU16(snes, WorldYBase + i).int
    let ddx = abs(px - lastPx)
    let ddy = abs(py - lastPy)
    if ddx > 32 or ddy > 32:
      inc result.tele
    elif ddx + ddy > 0:
      result.walk += ddx + ddy
      stagnant = 0
    else:
      inc stagnant
      if stagnant == 90:
        inc result.stuck
        echo fmt"STUCK_RECOVERY f={f} pos=(0x{px:04X},0x{py:04X}) n={result.stuck}"
        stagnant = 0
    lastPx = px
    lastPy = py
    # Indoor heuristic (house/cave x-band): px >= 0x1C00 on known seats.
    if px >= 0x1C00: inc result.indoorHits
    template bump(field, fn) =
      let v = fn(snes)
      if v > result.field: result.field = v
    bump(maxCs, captainStrongPercent)
    bump(maxGs, giantStepPercent)
    bump(maxPr, peacefulRestPercent)
    bump(maxPa, paulaRescuePercent)
    bump(maxLi, lilliputStepsPercent)
    bump(maxWi, wintersPercent)
    bump(maxBe, belchPercent)
    bump(maxFo, foursidePercent)
    bump(maxMa, magicantPercent)
    bump(maxDd, deepDarknessPercent)
    let bp = eventFlagBitPop(snes)
    if bp > result.maxBp: result.maxBp = bp

proc grade(label, path: string; pol: string; frames: int;
    holdKnock = false; forceLater = false; holdDay = false) =
  if not fileExists(path):
    echo "SKIP ", label, " missing ", path
    return
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  if holdKnock:
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    if holdDay: applyDayStoryOpen(snes)
    else: snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  if forceLater: applyLaterStoryLeaveSoft(snes)
  clearSouthFreezeLocks(snes)
  echo fmt"{label}_START $99F2=0x{readU8(snes,KnockCompleteOff):02X} $9887=0x{readU8(snes,DayStoryByteOff):02X} {checkpointSpineLine(snes)}"
  let t = runPol(snes, c, pol, frames, holdKnock, forceLater, holdDay)
  echo fmt"{label}_PEAKS cs={t.maxCs} gs={t.maxGs} pr={t.maxPr} pa={t.maxPa} li={t.maxLi} wi={t.maxWi} be={t.maxBe} fo={t.maxFo} ma={t.maxMa} dd={t.maxDd} bp={t.maxBp} walk={t.walk} tele={t.tele} stuck={t.stuck} indoor={t.indoorHits} stories={t.stories}"
  echo fmt"{label}_END {checkpointSpineLine(snes)}"

proc main() =
  doAssert fileExists(Rom)
  echo "PROBE=d98 next spine freeplay dig (captain/leave/mid/late)"
  echo "POLICY=AgentCaptain / AgentPaula / AgentMidgame / AgentLate / AgentGiant"
  echo "SPINE_REF=docs/checkpoints.md"

  grade("A_GIANT_CAP", Giant, AgentCaptainStrongPolicy, 9000, holdKnock=true)
  grade("B_GIANT_DAY_CAVE", Giant, AgentGiantStepPolicy, 6000, holdKnock=true, holdDay=true)
  grade("C_LEAVE_PAULA", Leave, AgentPaulaApproachPolicy, 8000, forceLater=true)
  grade("D_LEAVE_MID", Leave, AgentMidgameExplorePolicy, 8000, forceLater=true)
  grade("E_MID_FREE", Mid, AgentMidgameExplorePolicy, 8000, forceLater=true)
  grade("F_MIDDEEP", MidDeep, AgentMidgameExplorePolicy, 8000, forceLater=true)
  grade("G_LATE_SOFT", LateBest, AgentLateGamePolicy, 6000, forceLater=true)
  grade("H_SOFT98_HOLD", Soft98, AgentLateGamePolicy, 4000, forceLater=true)

  echo "OK probe_d98_next_spine"

when isMainModule:
  main()
