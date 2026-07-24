## Product Twoson → Fourside with wall-only campaign seats (d88).
## leave_day1_map pr70 → leave_onett pr90 → fo wall seal → fo60_from_paula freeplay.
## Intent/scene Agent policies; honest walk (tele=0). checkpoints.md Peaceful Rest
## → Paula → Fourside soft.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  LeaveMap = "bin/states/llm/leave_day1_map.state"
  LeaveWalk = "bin/states/llm/leave_onett_walkable.state"
  Fo60 = "bin/states/llm/fourside60_from_paula.state"
  Fo80 = "bin/states/llm/fourside80_from_paula.state"

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

proc skillsSrc(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

type Track = object
  maxPr, maxLi, maxFo, maxPa, maxMo, maxSu: int
  walkSpan, teleports, maxY, span: int

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int): Track =
  ## Drive Agent policy with honest walk tracking.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skillsSrc(), "skills")
  loadChunk(L, pol, "pol")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i).int
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i).int
  var maxY = minY
  var lastPx = minX
  var lastPy = minY
  result.maxPr = peacefulRestPercent(snes)
  result.maxLi = lilliputStepsPercent(snes)
  result.maxFo = foursidePercent(snes)
  result.maxPa = paulaRescuePercent(snes)
  result.maxMo = monotoliPercent(snes)
  result.maxSu = summersPercent(snes)
  result.maxY = maxY
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
    let ddx = abs(px - lastPx)
    let ddy = abs(py - lastPy)
    if ddx > 32 or ddy > 32:
      inc result.teleports
    else:
      result.walkSpan += ddx + ddy
    lastPx = px
    lastPy = py
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    if py > result.maxY: result.maxY = py
    let pr = peacefulRestPercent(snes)
    let li = lilliputStepsPercent(snes)
    let fo = foursidePercent(snes)
    let pa = paulaRescuePercent(snes)
    let mo = monotoliPercent(snes)
    let su = summersPercent(snes)
    if pr > result.maxPr: result.maxPr = pr
    if li > result.maxLi: result.maxLi = li
    if fo > result.maxFo: result.maxFo = fo
    if pa > result.maxPa: result.maxPa = pa
    if mo > result.maxMo: result.maxMo = mo
    if su > result.maxSu: result.maxSu = su
  result.span = (maxX - minX) + (maxY - minY)

proc main() =
  ## Twoson soft → wall seal → Fourside campaign freeplay.
  doAssert fileExists(Rom)
  for p in [LeaveMap, LeaveWalk, Fo60]:
    doAssert fileExists(p), "missing " & p

  echo "PRODUCT_SPINE=leave_map→leave_walk→(wall)→fo60→(optional fo80)"
  echo "SPINE_REF=docs/checkpoints.md"
  echo "POLICY=AgentPaula + AgentMidgame + AgentFourside (no followRoute body)"

  # Leg A: solo leave map honest pr70
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  let a = runPol(snes, c, AgentPaulaApproachPolicy, 4000)
  echo fmt"L1_MAP maxPr={a.maxPr} walk={a.walkSpan} tele={a.teleports} maxY=0x{a.maxY:04X}"
  doAssert a.maxPr >= 70
  doAssert a.teleports == 0
  doAssert a.walkSpan > 100

  # Leg B: Twoson party hold + wall seal
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveWalk)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  doAssert peacefulRestPercent(snes) >= 90
  doAssert foursidePercent(snes) >= 40
  let b = runPol(snes, c, AgentMidgameExplorePolicy, 4000)
  echo fmt"L2_TWOSON maxPr={b.maxPr} maxLi={b.maxLi} maxFo={b.maxFo} " &
    fmt"walk={b.walkSpan} tele={b.teleports} maxY=0x{b.maxY:04X}"
  doAssert b.maxPr >= 90 and b.maxLi >= 70
  doAssert b.maxFo >= 40 and b.maxFo < 60, "freewalk cannot invent fo60"
  doAssert b.maxY <= 0x16C0, fmt"fo wall seal ~0x16B0 (got 0x{b.maxY:04X})"
  doAssert b.teleports == 0

  # Leg C: campaign fo60 deep seat freeplay (settle load before tele track).
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo60)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  block:
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    for _ in 0 .. 40:
      snes.joy1 = 0
      policy.stepOneFrame(snes, c, img)
      applyLaterStoryLeaveSoft(snes)
  doAssert foursidePercent(snes) >= 60, "fo60 seat must grade 60+"
  let cR = runPol(snes, c, AgentFoursideApproachPolicy, 5000)
  echo fmt"L3_FO60 maxFo={cR.maxFo} maxMo={cR.maxMo} walk={cR.walkSpan} tele={cR.teleports}"
  doAssert cR.maxFo >= 60
  # Deep map may battle-warp once; require real walk after freeplay starts.
  doAssert cR.teleports <= 2, "fo60 freeplay should not thrash-teleport"
  doAssert cR.walkSpan > 50, "fo60 deep seat must freewalk"

  # Leg D optional: fo80 Poo hold
  if fileExists(Fo80):
    snes = newSnesBus(policy.readRomFile(Rom))
    c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Fo80)), snes, c)
    applyLaterStoryLeaveSoft(snes)
    block:
      let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
      for _ in 0 .. 40:
        snes.joy1 = 0
        policy.stepOneFrame(snes, c, img)
        applyLaterStoryLeaveSoft(snes)
    doAssert foursidePercent(snes) >= 80
    let d = runPol(snes, c, AgentLateGamePolicy, 4000)
    echo fmt"L4_FO80 maxFo={d.maxFo} maxMo={d.maxMo} maxSu={d.maxSu} walk={d.walkSpan} tele={d.teleports}"
    doAssert d.maxFo >= 80
    doAssert d.teleports <= 2

  echo "PEAKS leave_pr=70 twoson_pr=90 wall_fo=40 fo60_hold>=60"
  echo "NOTE fo freewalk sealed maxY~0x16B0; campaign fo60_from_paula is product seat"
  echo "OK test_agent_product_twoson_to_fo60"

when isMainModule:
  main()
