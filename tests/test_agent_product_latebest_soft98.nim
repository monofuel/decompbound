## d97 product: continuous freeplay soft98 climb from campaign_late_best.
## fo80 free+Poo cannot freewalk bitpop (teleports to fo wall; bp drops).
## latebest (ma95/dd60/bp543) freewalks to soft98 (ma98/dd80) with AgentLate —
## honest walk tele=0. Softwalk holds soft ceiling. Dream 100 still RE-open.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fo80 = "bin/states/llm/fourside80_from_paula.state"
  LateBest = "bin/states/llm/campaign_late_best.state"
  SoftWalk = "bin/states/llm/poo_soft98_walkable.state"

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
  maxMa, maxGi, maxDd, maxBp, minBp: int
  walkSpan, teleports: int
  hitSoft: bool

proc settle(snes: SnesBus; c: var Cpu; n = 25) =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. n:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    stopSoft = false): Track =
  ## Drive AgentLate; track ma/dd/bp and honest walk.
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
  result.maxMa = magicantPercent(snes)
  result.maxGi = giygasPercent(snes)
  result.maxDd = deepDarknessPercent(snes)
  result.maxBp = eventFlagBitPop(snes)
  result.minBp = result.maxBp
  result.hitSoft = hasAllSanctuarySoft(snes)
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
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    let dd = deepDarknessPercent(snes)
    let bp = eventFlagBitPop(snes)
    if ma > result.maxMa: result.maxMa = ma
    if gi > result.maxGi: result.maxGi = gi
    if dd > result.maxDd: result.maxDd = dd
    if bp > result.maxBp: result.maxBp = bp
    if bp < result.minBp: result.minBp = bp
    if hasAllSanctuarySoft(snes):
      result.hitSoft = true
    if stopSoft and result.hitSoft and result.maxMa >= 98 and f >= 1200:
      break

proc main() =
  ## Continuous freeplay soft98 from latebest; fo80 wall documented; softwalk hold.
  doAssert fileExists(Rom)
  doAssert fileExists(LateBest), "need campaign_late_best"
  doAssert fileExists(SoftWalk) or fileExists(Fo80)

  echo "PRODUCT=fo80 wall doc → latebest freeplay soft98 climb → softwalk hold"
  echo "SPINE_REF=docs/checkpoints.md Deep Darkness / Magicant soft"
  echo "POLICY=AgentLateGamePolicy (intent/scene)"

  # L1: fo80 cannot freewalk to soft98 (teleport wall; bp drops)
  if fileExists(Fo80):
    var snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Fo80)), snes, c)
    applyLaterStoryLeaveSoft(snes)
    settle(snes, c)
    doAssert magicantPercent(snes) >= 90
    doAssert not hasAllSanctuarySoft(snes)
    let a = runPol(snes, c, AgentLateGamePolicy, 4000)
    echo fmt"L1_FO80 maxMa={a.maxMa} maxDd={a.maxDd} bp={a.minBp}..{a.maxBp} " &
      fmt"soft={a.hitSoft} walk={a.walkSpan} tele={a.teleports}"
    doAssert a.maxMa >= 90
    doAssert not a.hitSoft or a.maxMa < 98,
      "fo80 freewalk must not invent soft98 without latebest/soft seat"
    # May teleport to fo wall — note for product path
    if a.teleports > 0:
      echo "L1_NOTE fo80 deep seat teleports (campaign soft seat required for freeplay climb)"

  # L2: continuous freeplay soft98 climb from latebest (d97 RE)
  block:
    var snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LateBest)), snes, c)
    applyLaterStoryLeaveSoft(snes)
    settle(snes, c)
    let ma0 = magicantPercent(snes)
    let dd0 = deepDarknessPercent(snes)
    let bp0 = eventFlagBitPop(snes)
    let soft0 = hasAllSanctuarySoft(snes)
    echo fmt"L2_START ma={ma0} dd={dd0} bp={bp0} soft={soft0}"
    doAssert ma0 >= 90 and ma0 < 98, "latebest starts pre-soft98 soft ladder"
    doAssert dd0 >= 60 and dd0 < 80
    doAssert not soft0
    doAssert bp0 < EventFlagBitPopLateDeep or not soft0
    let b = runPol(snes, c, AgentLateGamePolicy, 8000, stopSoft = true)
    echo fmt"L2_CLIMB maxMa={b.maxMa} maxDd={b.maxDd} maxGi={b.maxGi} " &
      fmt"bp={b.minBp}..{b.maxBp} soft={b.hitSoft} walk={b.walkSpan} tele={b.teleports}"
    doAssert b.hitSoft, "AgentLate freeplay must hit hasAllSanctuarySoft"
    doAssert b.maxMa >= 98, "freeplay soft climb reaches magicant 98"
    doAssert b.maxDd >= 80, "freeplay soft climb reaches deep_darkness 80"
    doAssert b.maxGi >= 80, "giygas soft tracks ma98"
    doAssert b.teleports == 0, "latebest freeplay must be honest walk"
    doAssert b.walkSpan > 200, "must walk during soft climb"
    doAssert not hasMagicantDreamFlag(snes), "dream 100 still RE-open"

  # L3: softwalk hold soft ceiling
  if fileExists(SoftWalk):
    var snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(SoftWalk)), snes, c)
    applyLaterStoryLeaveSoft(snes)
    settle(snes, c)
    doAssert hasAllSanctuarySoft(snes)
    doAssert magicantPercent(snes) >= 98
    let cR = runPol(snes, c, AgentLateGamePolicy, 5000)
    echo fmt"L3_HOLD maxMa={cR.maxMa} maxDd={cR.maxDd} walk={cR.walkSpan} tele={cR.teleports}"
    doAssert cR.maxMa >= 98 and cR.maxDd >= 80
    doAssert cR.teleports == 0
    doAssert cR.walkSpan > 100

  echo "PEAKS latebest freeplay ma98/dd80/gi80 soft=true (fo80 wall; dream open)"
  echo "OK test_agent_product_latebest_soft98"

when isMainModule:
  main()
