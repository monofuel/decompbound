## Continuous product past Twoson wall: fo60 freeplay holds monotoli soft 50.
## fo80 campaign seat holds mo70/su90 under AgentLate (checkpoints.md Monotoli/Summers).

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
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

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int):
    tuple[maxFo, maxMo, maxSu, walkSpan, teleports, maxY: int] =
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
  var lastPx = readU16(snes, WorldXBase + i).int
  var lastPy = readU16(snes, WorldYBase + i).int
  result.maxY = lastPy
  result.maxFo = foursidePercent(snes)
  result.maxMo = monotoliPercent(snes)
  result.maxSu = summersPercent(snes)
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
    if ddx > 32 or ddy > 32: inc result.teleports
    else: result.walkSpan += ddx + ddy
    lastPx = px
    lastPy = py
    if py > result.maxY: result.maxY = py
    let fo = foursidePercent(snes)
    let mo = monotoliPercent(snes)
    let su = summersPercent(snes)
    if fo > result.maxFo: result.maxFo = fo
    if mo > result.maxMo: result.maxMo = mo
    if su > result.maxSu: result.maxSu = su

proc settle(snes: SnesBus; c: var Cpu) =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. 30:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)

proc main() =
  ## Twoson wall seal → fo60 monotoli freeplay → fo80 summers hold.
  doAssert fileExists(Rom)
  for p in [LeaveWalk, Fo60, Fo80]:
    doAssert fileExists(p), "missing " & p

  echo "PRODUCT=leave_walk wall → fo60 monotoli freeplay → fo80 summers"
  echo "SPINE_REF=docs/checkpoints.md Monotoli / Summers"

  # L1: leave wall seal (fo40)
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveWalk)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  let w = runPol(snes, c, AgentMidgameExplorePolicy, 3000)
  echo fmt"L1_WALL maxFo={w.maxFo} maxMo={w.maxMo} maxY=0x{w.maxY:04X} tele={w.teleports}"
  doAssert w.maxFo >= 40 and w.maxFo < 60
  doAssert w.maxMo < 50
  doAssert w.maxY <= 0x16C0

  # L2: fo60 continuous freeplay monotoli 50
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo60)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  doAssert foursidePercent(snes) >= 60
  doAssert monotoliPercent(snes) >= 50
  let f6 = runPol(snes, c, AgentFoursideApproachPolicy, 5000)
  echo fmt"L2_FO60 maxFo={f6.maxFo} maxMo={f6.maxMo} maxSu={f6.maxSu} walk={f6.walkSpan} tele={f6.teleports}"
  doAssert f6.maxFo >= 60
  doAssert f6.maxMo >= 50
  doAssert f6.maxMo < 70, "fo60 freeplay cannot invent Poo/mo70"
  doAssert f6.teleports <= 2
  doAssert f6.walkSpan > 20

  # L3: fo80 campaign Poo seat summers soft
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo80)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  doAssert monotoliPercent(snes) >= 70
  let f8 = runPol(snes, c, AgentLateGamePolicy, 4000)
  echo fmt"L3_FO80 maxFo={f8.maxFo} maxMo={f8.maxMo} maxSu={f8.maxSu} walk={f8.walkSpan}"
  doAssert f8.maxMo >= 70
  doAssert f8.maxSu >= 70

  echo "PEAKS wall_fo=40 fo60_mo=50 fo80_mo70_su70+"
  echo "OK test_agent_product_fo60_monotoli"

when isMainModule:
  main()
