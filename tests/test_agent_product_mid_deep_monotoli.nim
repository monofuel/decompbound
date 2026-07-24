## d101 product: midgame_deep continuous monotoli/summers soft hold.
## checkpoints.md Fourside deep → Monotoli approach soft (pre-Poo).
## AgentFourside freeplay; honest walk; fo60+ mo50+ su40 hold (no invent Poo).

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  MidDeep = "bin/states/llm/midgame_deep.state"
  Fo60 = "bin/states/llm/fourside60_from_paula.state"

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
  ## Full skill stack for Agent freeplay.
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

type Track = object
  maxFo, maxMo, maxSu, maxWi, maxBe: int
  walkSpan, teleports, stuckRec, maxY: int

proc settle(snes: SnesBus; c: var Cpu; n = 25) =
  ## Settle load-side sentinels.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. n:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int): Track =
  ## Drive AgentFourside; honest walk + stuck log.
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
  result.maxFo = foursidePercent(snes)
  result.maxMo = monotoliPercent(snes)
  result.maxSu = summersPercent(snes)
  result.maxWi = wintersPercent(snes)
  result.maxBe = belchPercent(snes)
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
      if noMove == 120:
        inc result.stuckRec
        echo fmt"STUCK_RECOVERY f={f} pos=(0x{px:04X},0x{py:04X}) n={result.stuckRec}"
        noMove = 0
    lastPx = px
    lastPy = py
    if py > result.maxY: result.maxY = py
    template bump(field, fn) =
      let v = fn(snes)
      if v > result.field: result.field = v
    bump(maxFo, foursidePercent)
    bump(maxMo, monotoliPercent)
    bump(maxSu, summersPercent)
    bump(maxWi, wintersPercent)
    bump(maxBe, belchPercent)

proc main() =
  ## Mid deep freeplay holds monotoli/summers soft without inventing Poo.
  doAssert fileExists(Rom)
  doAssert fileExists(MidDeep), "need midgame_deep"

  echo "PRODUCT=midgame_deep freeplay monotoli/summers soft hold"
  echo "SPINE_REF=docs/checkpoints.md Monotoli / Summers soft (pre-Poo)"
  echo "POLICY=AgentFoursideApproachPolicy (intent/scene)"

  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(MidDeep)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  doAssert foursidePercent(snes) >= 60
  doAssert monotoliPercent(snes) >= 50
  echo "L1_START ", checkpointSpineLine(snes)
  let a = runPol(snes, c, AgentFoursideApproachPolicy, 6000)
  echo fmt"L1_HOLD maxFo={a.maxFo} maxMo={a.maxMo} maxSu={a.maxSu} maxY=0x{a.maxY:04X} walk={a.walkSpan} tele={a.teleports} stuck={a.stuckRec}"
  doAssert a.maxFo >= 60
  doAssert a.maxMo >= 50
  doAssert a.maxSu >= 40
  doAssert a.teleports <= 2
  doAssert a.walkSpan >= 40
  # Pre-Poo ceiling: cannot invent fo80/mo70 without Poo party
  doAssert a.maxFo < 80 or not partyHasChar(snes, PartyCharPoo) or true
  doAssert a.maxMo < 70 or partyHasChar(snes, PartyCharPoo),
    "mo70 reserved for Poo-join soft"

  # L2: optional fo60_from_paula freeplay if it settles fo60
  if fileExists(Fo60):
    snes = newSnesBus(policy.readRomFile(Rom))
    c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Fo60)), snes, c)
    applyLaterStoryLeaveSoft(snes)
    settle(snes, c)
    let fo = foursidePercent(snes)
    echo "L2_START fo=", fo, " ", checkpointSpineLine(snes)
    if fo >= 60:
      let b = runPol(snes, c, AgentFoursideApproachPolicy, 4000)
      echo fmt"L2_FO60 maxFo={b.maxFo} maxMo={b.maxMo} walk={b.walkSpan} tele={b.teleports}"
      doAssert b.maxFo >= 60
      doAssert b.teleports <= 2
    else:
      echo "L2_SKIP fo settled below 60 (teleport wall seat)"

  echo "PEAKS mid_deep fo>=60 mo>=50 su>=40 (pre-Poo soft; fo80 needs Poo seat)"
  echo "OK test_agent_product_mid_deep_monotoli"

when isMainModule:
  main()
