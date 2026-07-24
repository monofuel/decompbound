## d98 mid/late freeplay dig only (continue after leave wall).
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Mid = "bin/states/llm/midgame_approach.state"
  MidDeep = "bin/states/llm/midgame_deep.state"
  Fo60 = "bin/states/llm/fourside60_freewalk.state"
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
  maxCs, maxPr, maxPa, maxLi, maxWi, maxBe, maxFo, maxMo, maxSu, maxMa, maxDd: int
  maxBp, walk, tele, stuck: int

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int): Track =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skills(), "skills"); loadChunk(L, pol, "pol")
  let i = PlayerSlot * SlotIndexStride
  var lastPx = readU16(snes, WorldXBase + i).int
  var lastPy = readU16(snes, WorldYBase + i).int
  var stagnant = 0
  result.maxCs = captainStrongPercent(snes)
  result.maxPr = peacefulRestPercent(snes)
  result.maxPa = paulaRescuePercent(snes)
  result.maxLi = lilliputStepsPercent(snes)
  result.maxWi = wintersPercent(snes)
  result.maxBe = belchPercent(snes)
  result.maxFo = foursidePercent(snes)
  result.maxMo = monotoliPercent(snes)
  result.maxSu = summersPercent(snes)
  result.maxMa = magicantPercent(snes)
  result.maxDd = deepDarknessPercent(snes)
  result.maxBp = eventFlagBitPop(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    let px = readU16(snes, WorldXBase + i).int
    let py = readU16(snes, WorldYBase + i).int
    let ddx = abs(px - lastPx); let ddy = abs(py - lastPy)
    if ddx > 32 or ddy > 32: inc result.tele
    elif ddx + ddy > 0: result.walk += ddx + ddy; stagnant = 0
    else:
      inc stagnant
      if stagnant == 120:
        inc result.stuck
        echo fmt"STUCK_RECOVERY f={f} pos=(0x{px:04X},0x{py:04X}) n={result.stuck}"
        stagnant = 0
    lastPx = px; lastPy = py
    template bump(field, fn) =
      let v = fn(snes)
      if v > result.field: result.field = v
    bump(maxCs, captainStrongPercent)
    bump(maxPr, peacefulRestPercent)
    bump(maxPa, paulaRescuePercent)
    bump(maxLi, lilliputStepsPercent)
    bump(maxWi, wintersPercent)
    bump(maxBe, belchPercent)
    bump(maxFo, foursidePercent)
    bump(maxMo, monotoliPercent)
    bump(maxSu, summersPercent)
    bump(maxMa, magicantPercent)
    bump(maxDd, deepDarknessPercent)
    let bp = eventFlagBitPop(snes)
    if bp > result.maxBp: result.maxBp = bp

proc grade(label, path, pol: string; frames: int) =
  if not fileExists(path):
    echo "SKIP ", label, " ", path
    return
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  clearSouthFreezeLocks(snes)
  echo fmt"{label}_START {checkpointSpineLine(snes)}"
  let t = runPol(snes, c, pol, frames)
  echo fmt"{label}_PEAKS wi={t.maxWi} be={t.maxBe} fo={t.maxFo} mo={t.maxMo} su={t.maxSu} ma={t.maxMa} dd={t.maxDd} li={t.maxLi} pr={t.maxPr} pa={t.maxPa} bp={t.maxBp} walk={t.walk} tele={t.tele} stuck={t.stuck}"
  echo fmt"{label}_END {checkpointSpineLine(snes)}"

proc main() =
  echo "PROBE=d98 mid/late continuous freeplay"
  echo "POLICY=AgentMidgame / AgentFourside / AgentLate"
  echo "SPINE_REF=docs/checkpoints.md"
  grade("E_MID", Mid, AgentMidgameExplorePolicy, 6000)
  grade("F_MIDDEEP", MidDeep, AgentMidgameExplorePolicy, 6000)
  grade("G_FO60FREE", Fo60, AgentFoursideApproachPolicy, 5000)
  grade("H_LATE", LateBest, AgentLateGamePolicy, 5000)
  grade("I_SOFT98", Soft98, AgentLateGamePolicy, 3000)
  echo "OK probe_d98_mid_late"

when isMainModule: main()
