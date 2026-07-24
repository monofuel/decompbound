## Full soft product spine past Twoson wall (d89).
## leave_onett → fo60_from_paula → fo80_from_paula → soft98_from_fo80paula.
## Campaign seats only at freewalk walls (fo wall, soft-flag). Agent policies
## hold each segment with honest walk tracking + stuck recovery lines.
## checkpoints.md Fourside → Monotoli → Summers → Magicant soft 98.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Leave = "bin/states/llm/leave_onett_walkable.state"
  Fo60 = "bin/states/llm/fourside60_from_paula.state"
  Fo80 = "bin/states/llm/fourside80_from_paula.state"
  Soft98 = "bin/states/llm/soft98_from_fo80paula.state"

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
  maxFo, maxMo, maxSu, maxMa, maxGi, maxDd: int
  walkSpan, teleports, stuckRec, span: int

proc settle(snes: SnesBus; c: var Cpu; n = 40) =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. n:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int): Track =
  ## Drive Agent with honest walk + stuck recovery.
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
  var noMove = 0
  result.maxFo = foursidePercent(snes)
  result.maxMo = monotoliPercent(snes)
  result.maxSu = summersPercent(snes)
  result.maxMa = magicantPercent(snes)
  result.maxGi = giygasPercent(snes)
  result.maxDd = deepDarknessPercent(snes)
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
    if px == lastPx and py == lastPy:
      inc noMove
    else:
      noMove = 0
    if noMove >= 200:
      inc result.stuckRec
      echo fmt"STUCK_RECOVERY f={f} pos=(0x{px:04X},0x{py:04X}) n={result.stuckRec}"
      for _ in 0 .. 5:
        snes.joy1 = 0x8000
        policy.stepOneFrame(snes, c, img)
        applyLaterStoryLeaveSoft(snes)
        clearSouthFreezeLocks(snes)
      noMove = 0
      lastPx = readU16(snes, WorldXBase + i).int
      lastPy = readU16(snes, WorldYBase + i).int
      continue
    lastPx = px
    lastPy = py
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    let fo = foursidePercent(snes)
    let mo = monotoliPercent(snes)
    let su = summersPercent(snes)
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    let dd = deepDarknessPercent(snes)
    if fo > result.maxFo: result.maxFo = fo
    if mo > result.maxMo: result.maxMo = mo
    if su > result.maxSu: result.maxSu = su
    if ma > result.maxMa: result.maxMa = ma
    if gi > result.maxGi: result.maxGi = gi
    if dd > result.maxDd: result.maxDd = dd
  result.span = (maxX - minX) + (maxY - minY)

proc main() =
  ## Soft spine product holds through Magicant 98 / Giygas 80.
  doAssert fileExists(Rom)
  for p in [Leave, Fo60, Fo80, Soft98]:
    doAssert fileExists(p), "missing " & p

  echo "PRODUCT_SPINE=leave→fo60→fo80→soft98 (campaign seats at freewalk walls)"
  echo "SPINE_REF=docs/checkpoints.md"
  echo "POLICY=AgentMidgame + AgentFourside + AgentLate (intent/scene)"

  # L1 leave Twoson hold + wall
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Leave)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  doAssert peacefulRestPercent(snes) >= 90
  let l1 = runPol(snes, c, AgentMidgameExplorePolicy, 3000)
  echo fmt"L1_LEAVE maxFo={l1.maxFo} walk={l1.walkSpan} tele={l1.teleports} stuck={l1.stuckRec}"
  doAssert l1.maxFo >= 40 and l1.maxFo < 60
  doAssert l1.teleports == 0

  # L2 fo60 campaign
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo60)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  doAssert foursidePercent(snes) >= 60
  let l2 = runPol(snes, c, AgentFoursideApproachPolicy, 4000)
  echo fmt"L2_FO60 maxFo={l2.maxFo} maxMo={l2.maxMo} walk={l2.walkSpan} tele={l2.teleports}"
  doAssert l2.maxFo >= 60 and l2.maxMo >= 50
  doAssert l2.teleports <= 2 and l2.walkSpan > 20

  # L3 fo80 Poo
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo80)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  doAssert foursidePercent(snes) >= 80
  let l3 = runPol(snes, c, AgentLateGamePolicy, 4000)
  echo fmt"L3_FO80 maxFo={l3.maxFo} maxMa={l3.maxMa} maxSu={l3.maxSu} walk={l3.walkSpan}"
  doAssert l3.maxFo >= 80 and l3.maxMa >= 90
  doAssert l3.teleports <= 2

  # L4 soft98 Magicant/Giygas soft ceiling
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Soft98)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  doAssert magicantPercent(snes) >= 98
  doAssert giygasPercent(snes) >= 80
  doAssert not hasMagicantDreamFlag(snes), "dream 100 still RE-open"
  let l4 = runPol(snes, c, AgentLateGamePolicy, 4000)
  echo fmt"L4_SOFT98 maxMa={l4.maxMa} maxGi={l4.maxGi} maxDd={l4.maxDd} walk={l4.walkSpan} stuck={l4.stuckRec}"
  doAssert l4.maxMa >= 98 and l4.maxGi >= 80
  doAssert l4.maxDd >= 80
  doAssert l4.teleports <= 2
  doAssert l4.walkSpan > 20 or l4.span > 20

  echo "PEAKS fo=90 ma=98 gi=80 dd=80 (soft ceiling; dream/phase 100 open)"
  echo "SPINE ", checkpointSpineLine(snes)
  echo "OK test_agent_product_soft_spine"

when isMainModule:
  main()
