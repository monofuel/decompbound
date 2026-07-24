## d114: day outdoor freeplay to cs60, then later-story soft + freeplay for leave pr.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  Leave = "bin/states/llm/leave_day1_map.state"

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
    dayHold, laterHold: bool; stopCs, stopPr: int):
    tuple[maxCs, maxPr, maxGs, walk, tele: int] =
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
  result.maxCs = captainStrongPercent(snes)
  result.maxPr = peacefulRestPercent(snes)
  result.maxGs = giantStepPercent(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if dayHold:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      applyDayStoryOpen(snes)
    if laterHold:
      applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    let px = readU16(snes, WorldXBase + i).int
    let py = readU16(snes, WorldYBase + i).int
    let ddx = abs(px-lastPx); let ddy = abs(py-lastPy)
    if ddx > 32 or ddy > 32: inc result.tele else: result.walk += ddx+ddy
    lastPx = px; lastPy = py
    let cs = captainStrongPercent(snes)
    let pr = peacefulRestPercent(snes)
    let gs = giantStepPercent(snes)
    if cs > result.maxCs: result.maxCs = cs
    if pr > result.maxPr: result.maxPr = pr
    if gs > result.maxGs: result.maxGs = gs
    if stopCs > 0 and result.maxCs >= stopCs and f >= 1200: break
    if stopPr > 0 and result.maxPr >= stopPr and f >= 1200: break

proc main() =
  echo "PROBE=d114 day freeplay cs60 then later-story leave freeplay"
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  applyDayStoryOpen(snes)
  clearSouthFreezeLocks(snes)
  # continuous day fr→gs→cs
  discard runPol(snes, c, AgentFrankPolicy, 6000, true, false, 0, 0)
  discard runPol(snes, c, AgentGiantStepPolicy, 7000, true, false, 0, 0)
  let cap = runPol(snes, c, AgentCaptainStrongPolicy, 8000, true, false, 60, 0)
  echo fmt"A_DAY maxCs={cap.maxCs} maxGs={cap.maxGs} walk={cap.walk} tele={cap.tele}"
  # try later story freeplay without leave load
  applyLaterStoryLeaveSoft(snes)
  let b = runPol(snes, c, AgentPaulaApproachPolicy, 8000, false, true, 0, 70)
  echo fmt"B_LATER_FREE maxCs={b.maxCs} maxPr={b.maxPr} walk={b.walk} tele={b.tele}"
  echo "B_END ", checkpointSpineLine(snes)
  # honest leave freeplay from leave fixture
  if fileExists(Leave):
    snes = newSnesBus(policy.readRomFile(Rom))
    c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Leave)), snes, c)
    applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    let d = runPol(snes, c, AgentPaulaApproachPolicy, 6000, false, true, 0, 0)
    echo fmt"C_LEAVE maxPr={d.maxPr} maxCs={d.maxCs} walk={d.walk} tele={d.tele}"
  echo "OK probe_d114_day_cs_to_leave"

when isMainModule: main()
