## Master product soft spine (d91): outdoor continuous day-1 → soft98.
## Campaign seats only at freewalk walls (night leave, fo wall, soft-flag).
## Agent intent/scene policies; honest walk on freeplay legs; stuck recovery.
## checkpoints.md Onett day-1 → Twoson → Fourside → Magicant soft 98.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"
  LeaveWalk = "bin/states/llm/leave_onett_walkable.state"
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
  maxFr, maxGs, maxCs, maxPr, maxFo, maxMa, maxGi: int
  walkSpan, teleports, stuckRec: int

proc settle(snes: SnesBus; c: var Cpu; n = 30) =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. n:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    holdKnock: bool; stopFr, stopGs, stopCs: int;
    stuckRecover = false): Track =
  ## Drive Agent; honest walk. Stuck recovery only on post-leave legs
  ## (B thrash on outdoor giant seat re-locks captain freeplay).
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
  var noMove = 0
  result.maxFr = frankPercent(snes)
  result.maxGs = giantStepPercent(snes)
  result.maxCs = captainStrongPercent(snes)
  result.maxPr = peacefulRestPercent(snes)
  result.maxFo = foursidePercent(snes)
  result.maxMa = magicantPercent(snes)
  result.maxGi = giygasPercent(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if holdKnock:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    else:
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
    if stuckRecover and noMove >= 200:
      inc result.stuckRec
      echo fmt"STUCK_RECOVERY f={f} pos=(0x{px:04X},0x{py:04X}) n={result.stuckRec}"
      for _ in 0 .. 5:
        snes.joy1 = 0x8000
        policy.stepOneFrame(snes, c, img)
        if not holdKnock: applyLaterStoryLeaveSoft(snes)
        clearSouthFreezeLocks(snes)
      noMove = 0
      lastPx = readU16(snes, WorldXBase + i).int
      lastPy = readU16(snes, WorldYBase + i).int
      continue
    lastPx = px
    lastPy = py
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    let cs = captainStrongPercent(snes)
    let pr = peacefulRestPercent(snes)
    let fo = foursidePercent(snes)
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    if fr > result.maxFr: result.maxFr = fr
    if gs > result.maxGs: result.maxGs = gs
    if cs > result.maxCs: result.maxCs = cs
    if pr > result.maxPr: result.maxPr = pr
    if fo > result.maxFo: result.maxFo = fo
    if ma > result.maxMa: result.maxMa = ma
    if gi > result.maxGi: result.maxGi = gi
    if stopFr > 0 and result.maxFr >= stopFr and f >= 1500: break
    if stopGs > 0 and result.maxGs >= stopGs and f >= 1500: break
    if stopCs > 0 and result.maxCs >= stopCs and f >= 1500: break

proc main() =
  ## Outdoor freeplay then campaign seats through soft98.
  doAssert fileExists(Rom)
  for p in [Outdoor, LeaveMap, LeaveWalk, Fo60, Fo80, Soft98]:
    doAssert fileExists(p), "missing " & p

  echo "PRODUCT_SPINE=outdoor→leave→twoson→fo60→fo80→soft98"
  echo "SPINE_REF=docs/checkpoints.md"
  echo "POLICY=AgentFrank/Giant/Captain/Paula/Midgame/Fourside/Late"

  # Outdoor continuous
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let fr = runPol(snes, c, AgentFrankPolicy, 8000, true, 80, 0, 0)
  echo fmt"L0_FRANK maxFr={fr.maxFr}"
  doAssert fr.maxFr >= 80
  clearSouthFreezeLocks(snes)
  let gs = runPol(snes, c, AgentGiantStepPolicy, 8000, true, 0, 70, 0)
  echo fmt"L0_GIANT maxGs={gs.maxGs}"
  doAssert gs.maxGs >= 70
  let cap = runPol(snes, c, AgentCaptainStrongPolicy, 6000, true, 0, 0, 60)
  echo fmt"L0_CAPTAIN maxCs={cap.maxCs}"
  doAssert cap.maxCs >= 60

  # Campaign leave map honest pr70
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  let lv = runPol(snes, c, AgentPaulaApproachPolicy, 4000, false, 0, 0, 0,
    stuckRecover = true)
  echo fmt"L1_LEAVE maxPr={lv.maxPr} walk={lv.walkSpan} tele={lv.teleports}"
  doAssert lv.maxPr >= 70 and lv.teleports == 0 and lv.walkSpan > 100

  # Twoson party
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveWalk)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  let tw = runPol(snes, c, AgentMidgameExplorePolicy, 3000, false, 0, 0, 0,
    stuckRecover = true)
  echo fmt"L2_TWOSON maxPr={tw.maxPr} maxFo={tw.maxFo} stuck={tw.stuckRec}"
  doAssert tw.maxPr >= 90 and tw.maxFo >= 40 and tw.maxFo < 60

  # fo60 / fo80 / soft98 campaign
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo60)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  let fo = runPol(snes, c, AgentFoursideApproachPolicy, 3000, false, 0, 0, 0,
    stuckRecover = true)
  echo fmt"L3_FO60 maxFo={fo.maxFo} walk={fo.walkSpan}"
  doAssert fo.maxFo >= 60

  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo80)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  let f8 = runPol(snes, c, AgentLateGamePolicy, 3000, false, 0, 0, 0,
    stuckRecover = true)
  echo fmt"L4_FO80 maxFo={f8.maxFo} maxMa={f8.maxMa}"
  doAssert f8.maxFo >= 80 and f8.maxMa >= 90

  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Soft98)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  settle(snes, c)
  let s98 = runPol(snes, c, AgentLateGamePolicy, 3000, false, 0, 0, 0,
    stuckRecover = true)
  echo fmt"L5_SOFT98 maxMa={s98.maxMa} maxGi={s98.maxGi} stuck={s98.stuckRec}"
  doAssert s98.maxMa >= 98 and s98.maxGi >= 80
  doAssert not hasMagicantDreamFlag(snes)

  echo "PEAKS outdoor_gs=70 leave_pr=70 twoson_pr=90 fo60 fo80 ma98 gi80"
  echo "SPINE ", checkpointSpineLine(snes)
  echo "OK test_agent_product_outdoor_to_soft98"

when isMainModule:
  main()
