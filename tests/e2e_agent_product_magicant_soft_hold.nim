## d106 product: soft98 freeplay hold from poo_magicant_approach / latebest.
## checkpoints.md Magicant soft ceiling; dream 100 open. Intent/scene AgentLate.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  MagApp = "bin/states/llm/poo_magicant_approach.state"
  Soft98 = "bin/states/llm/poo_soft98_walkable.state"
  LateBest = "bin/states/llm/campaign_late_best.state"

proc loadChunk(L: lua53.PState; src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene().
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind landmarkTarget.
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc skillsSrc(): string =
  ## Skill stack.
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

type Track = object
  maxMa, maxGi, maxDd, maxBp, minBp: int
  walkSpan, teleports: int
  hitSoft, hitDream: bool

proc settle(snes: SnesBus; c: var Cpu; n = 20) =
  ## Settle sentinels.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. n:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)

proc runPol(snes: SnesBus; c: var Cpu; frames: int): Track =
  ## AgentLate freeplay hold.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skillsSrc(), "skills")
  loadChunk(L, AgentLateGamePolicy, "pol")
  let i = PlayerSlot * SlotIndexStride
  var lastPx = readU16(snes, WorldXBase + i).int
  var lastPy = readU16(snes, WorldYBase + i).int
  result.maxMa = magicantPercent(snes)
  result.maxGi = giygasPercent(snes)
  result.maxDd = deepDarknessPercent(snes)
  result.maxBp = eventFlagBitPop(snes)
  result.minBp = result.maxBp
  result.hitSoft = hasAllSanctuarySoft(snes)
  result.hitDream = hasMagicantDreamFlag(snes)
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
    if ddx > 32 or ddy > 32: inc result.teleports
    else: result.walkSpan += ddx + ddy
    lastPx = px; lastPy = py
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    let dd = deepDarknessPercent(snes)
    let bp = eventFlagBitPop(snes)
    if ma > result.maxMa: result.maxMa = ma
    if gi > result.maxGi: result.maxGi = gi
    if dd > result.maxDd: result.maxDd = dd
    if bp > result.maxBp: result.maxBp = bp
    if bp < result.minBp: result.minBp = bp
    if hasAllSanctuarySoft(snes): result.hitSoft = true
    if hasMagicantDreamFlag(snes): result.hitDream = true

proc main() =
  ## Soft98 freeplay hold; dream remains open.
  doAssert fileExists(Rom)
  echo "PRODUCT=soft98 freeplay hold (magicant approach / softwalk)"
  echo "SPINE_REF=docs/checkpoints.md Magicant soft ceiling"
  echo "POLICY=AgentLateGamePolicy"

  let path =
    if fileExists(MagApp): MagApp
    elif fileExists(Soft98): Soft98
    else: LateBest
  doAssert fileExists(path)
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  echo "L1_START seat=", path.extractFilename, " ", checkpointSpineLine(snes)
  let t = runPol(snes, c, 5000)
  echo fmt"L1_HOLD maxMa={t.maxMa} maxGi={t.maxGi} maxDd={t.maxDd} bp={t.minBp}..{t.maxBp} soft={t.hitSoft} dream={t.hitDream} walk={t.walkSpan} tele={t.teleports}"
  doAssert t.maxMa >= 98 or t.hitSoft
  doAssert t.teleports <= 2
  doAssert t.walkSpan >= 40
  doAssert not t.hitDream, "dream flag still RE-open (expect false until Magicant F12)"
  echo "PEAKS soft98 hold dream=false (ma100 needs dream F12)"
  echo "OK test_agent_product_magicant_soft_hold"

when isMainModule: main()
