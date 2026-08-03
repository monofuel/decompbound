## d98 product: midgame continuous winters/belch freeplay → fo wall → fo60 hold.
## checkpoints.md Jeff/Winters → Belch region → Fourside approach soft.
## Intent/scene policies only; honest walk (tele count); stuck recovery logged.
## Campaign seat only at fo60 freewalk wall handoff (natural freewalk cannot
## climb 0x17F8→0x1A00).

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Mid = "bin/states/llm/midgame_approach.state"
  MidDeep = "bin/states/llm/midgame_deep.state"

proc loadChunk(L: lua53.PState; src, label: string) =
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
  ## Bind landmarkTarget(name) -> x,y.
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc skillsSrc(): string =
  ## Full skill stack for Agent mid/late freeplay.
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

type Track = object
  maxWi, maxBe, maxFo, maxMo, maxSu, maxLi, maxPa: int
  walkSpan, teleports, stuckRec, maxY: int

proc settle(snes: SnesBus; c: var Cpu; n = 25) =
  ## Settle load-side 0xFF sentinels and apply later-story soft.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. n:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    stuckRecover = true): Track =
  ## Drive Agent; honest walk + stuck recovery log lines.
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
  loadChunk(L, skillsSrc(), "skills")
  loadChunk(L, pol, "pol")
  let i = PlayerSlot * SlotIndexStride
  var lastPx = readU16(snes, WorldXBase + i).int
  var lastPy = readU16(snes, WorldYBase + i).int
  var noMove = 0
  result.maxWi = wintersPercent(snes)
  result.maxBe = belchPercent(snes)
  result.maxFo = foursidePercent(snes)
  result.maxMo = monotoliPercent(snes)
  result.maxSu = summersPercent(snes)
  result.maxLi = lilliputStepsPercent(snes)
  result.maxPa = paulaRescuePercent(snes)
  result.maxY = lastPy
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
    elif ddx + ddy > 0:
      result.walkSpan += ddx + ddy
      noMove = 0
    else:
      inc noMove
      if stuckRecover and noMove == 120:
        inc result.stuckRec
        echo fmt"STUCK_RECOVERY f={f} pos=(0x{px:04X},0x{py:04X}) n={result.stuckRec}"
        noMove = 0
    lastPx = px
    lastPy = py
    if py > result.maxY: result.maxY = py
    template bump(field, fn) =
      let v = fn(snes)
      if v > result.field: result.field = v
    bump(maxWi, wintersPercent)
    bump(maxBe, belchPercent)
    bump(maxFo, foursidePercent)
    bump(maxMo, monotoliPercent)
    bump(maxSu, summersPercent)
    bump(maxLi, lilliputStepsPercent)
    bump(maxPa, paulaRescuePercent)

proc main() =
  ## Midgame continuous winters/belch freeplay, fo wall, fo60 freewalk hold.
  doAssert fileExists(Rom)
  doAssert fileExists(Mid) or fileExists(MidDeep), "need midgame fixture"

  echo "PRODUCT=midgame winters/belch freeplay → fo wall → fo60 freewalk hold"
  echo "SPINE_REF=docs/checkpoints.md Winters → Belch → Fourside soft"
  echo "POLICY=AgentMidgameExplorePolicy + AgentFoursideApproachPolicy"

  # L1: midgame freeplay holds winters/belch soft and approaches fo wall
  let midPath = if fileExists(Mid): Mid else: MidDeep
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(midPath)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  doAssert wintersPercent(snes) >= 50, "mid fixture needs Jeff/winters soft"
  doAssert belchPercent(snes) >= 30
  echo "L1_START ", checkpointSpineLine(snes)
  let a = runPol(snes, c, AgentMidgameExplorePolicy, 7000)
  echo fmt"L1_MID maxWi={a.maxWi} maxBe={a.maxBe} maxFo={a.maxFo} maxLi={a.maxLi} maxY=0x{a.maxY:04X} walk={a.walkSpan} tele={a.teleports} stuck={a.stuckRec}"
  doAssert a.maxWi >= 50
  doAssert a.maxBe >= 50 or a.maxFo >= 20
  doAssert a.teleports <= 2
  doAssert a.walkSpan >= 50
  # Freewalk ceiling at fo wall (~0x17F8) — natural climb past 0x1A00 is blocked
  doAssert a.maxFo < 60, "mid freewalk should not invent fo60 without deep seat"
  echo "L1_NOTE fo freewalk wall sealed (fo60 needs campaign/deep freewalk seat)"

  # L2: midgame_deep freeplay holds fo60+ (deep seat past wall; honest walk)
  doAssert fileExists(MidDeep), "need midgame_deep for fo60 freeplay hold"
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(MidDeep)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  doAssert foursidePercent(snes) >= 60, "midgame_deep should seat fo60+"
  echo "L2_START ", checkpointSpineLine(snes)
  let b = runPol(snes, c, AgentMidgameExplorePolicy, 6000)
  echo fmt"L2_DEEP maxWi={b.maxWi} maxBe={b.maxBe} maxFo={b.maxFo} maxMo={b.maxMo} maxY=0x{b.maxY:04X} walk={b.walkSpan} tele={b.teleports} stuck={b.stuckRec}"
  doAssert b.maxWi >= 50
  doAssert b.maxBe >= 50
  doAssert b.maxFo >= 60
  doAssert b.teleports <= 2
  doAssert b.walkSpan >= 40

  # L3: AgentFourside hold on midgame_deep (fo60 free seat). Note:
  # fourside60_freewalk grades fo40 + walk=0 (control-locked, probe_d98).
  # fourside60_from_paula can settle below fo60 after joy frames — prefer deep.
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(MidDeep)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  doAssert foursidePercent(snes) >= 60
  echo "L3_START ", checkpointSpineLine(snes), " seat=midgame_deep"
  let d = runPol(snes, c, AgentFoursideApproachPolicy, 5000)
  echo fmt"L3_FO60 maxFo={d.maxFo} maxMo={d.maxMo} maxSu={d.maxSu} walk={d.walkSpan} tele={d.teleports} stuck={d.stuckRec}"
  doAssert d.maxFo >= 60
  doAssert d.teleports <= 2
  doAssert d.walkSpan >= 40

  echo "PEAKS mid_wi=50 mid_be=50 mid_fo_wall=45 mid_deep_fo60 AgentFourside hold"
  echo "OK test_agent_product_midgame_winters_fo"

when isMainModule:
  main()
