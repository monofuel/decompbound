## d104: day freeplay from leave_day1 / giant day for frank 100 arcade or deeper.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Leave = "bin/states/llm/leave_day1_map.state"
  Giant = "bin/states/llm/giant_approach.state"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"

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

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    holdDay = false; holdKnock = false): tuple[maxFr, maxGs, maxCs, walk, tele, indoor: int] =
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
  result.maxFr = frankPercent(snes)
  result.maxGs = giantStepPercent(snes)
  result.maxCs = captainStrongPercent(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if holdKnock:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      if holdDay: applyDayStoryOpen(snes)
      else: snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    if holdDay and not holdKnock: applyDayStoryOpen(snes)
    clearSouthFreezeLocks(snes)
    let px = readU16(snes, WorldXBase + i).int
    let py = readU16(snes, WorldYBase + i).int
    let ddx = abs(px-lastPx); let ddy = abs(py-lastPy)
    if ddx > 32 or ddy > 32: inc result.tele else: result.walk += ddx+ddy
    lastPx = px; lastPy = py
    if px >= 0x1C00: inc result.indoor
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    let cs = captainStrongPercent(snes)
    if fr > result.maxFr: result.maxFr = fr
    if gs > result.maxGs: result.maxGs = gs
    if cs > result.maxCs: result.maxCs = cs

proc grade(label, path, pol: string; frames: int; holdDay, holdKnock: bool) =
  if not fileExists(path):
    echo "SKIP ", label; return
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  if holdKnock:
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    if holdDay: applyDayStoryOpen(snes)
    else: snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  elif holdDay:
    applyDayStoryOpen(snes)
  clearSouthFreezeLocks(snes)
  echo fmt"{label}_START fr={frankPercent(snes)} gs={giantStepPercent(snes)} day={dayStoryOpen(snes)} {checkpointSpineLine(snes)}"
  let t = runPol(snes, c, pol, frames, holdDay, holdKnock)
  echo fmt"{label}_PEAKS maxFr={t.maxFr} maxGs={t.maxGs} maxCs={t.maxCs} walk={t.walk} tele={t.tele} indoor={t.indoor}"

proc main() =
  echo "PROBE=d104 day frank / giant freeplay dig"
  echo "POLICY=AgentFrank + AgentGiant"
  grade("A_LEAVE_FRANK", Leave, AgentFrankPolicy, 6000, true, false)
  grade("B_LEAVE_GIANT", Leave, AgentGiantStepPolicy, 6000, true, false)
  grade("C_GIANT_DAY", Giant, AgentGiantStepPolicy, 5000, true, true)
  grade("D_OUT_DAY_FRANK", Outdoor, AgentFrankPolicy, 6000, true, true)
  echo "OK probe_d104_day_frank"

when isMainModule: main()
