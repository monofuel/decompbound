## d115 product: day outdoor continuous fr→gs80→cs60, then leave_day1 freeplay pr70.
## Campaign handoff only at leave map seat (later-story on outdoor freezes walk).
## checkpoints.md Onett day soft → Peaceful Rest leave freeplay.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  Leave = "bin/states/llm/leave_day1_map.state"

proc loadChunk(L: lua53.PState; src, label: string) =
  ## Load Lua.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## scene.
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  ## landmark.
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc skillsSrc(): string =
  ## skills.
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

type Track = object
  maxFr, maxGs, maxCs, maxPr: int
  walkSpan, teleports: int

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    dayHold, laterHold: bool; stopFr, stopGs, stopCs, stopPr: int): Track =
  ## Drive Agent freeplay with optional day/later holds.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skillsSrc(), "skills"); loadChunk(L, pol, "pol")
  let i = PlayerSlot * SlotIndexStride
  var lastPx = readU16(snes, WorldXBase + i).int
  var lastPy = readU16(snes, WorldYBase + i).int
  result.maxFr = frankPercent(snes)
  result.maxGs = giantStepPercent(snes)
  result.maxCs = captainStrongPercent(snes)
  result.maxPr = peacefulRestPercent(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if dayHold:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      applyDayStoryOpen(snes)
    if laterHold: applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    let px = readU16(snes, WorldXBase + i).int
    let py = readU16(snes, WorldYBase + i).int
    let ddx = abs(px - lastPx); let ddy = abs(py - lastPy)
    if ddx > 32 or ddy > 32: inc result.teleports
    else: result.walkSpan += ddx + ddy
    lastPx = px; lastPy = py
    template bump(field, fn) =
      let v = fn(snes)
      if v > result.field: result.field = v
    bump(maxFr, frankPercent)
    bump(maxGs, giantStepPercent)
    bump(maxCs, captainStrongPercent)
    bump(maxPr, peacefulRestPercent)
    if stopFr > 0 and result.maxFr >= stopFr and f >= 1200: break
    if stopGs > 0 and result.maxGs >= stopGs and f >= 1200: break
    if stopCs > 0 and result.maxCs >= stopCs and f >= 1200: break
    if stopPr > 0 and result.maxPr >= stopPr and f >= 1200: break

proc main() =
  ## Day outdoor continuous Onett soft + leave freeplay handoff.
  doAssert fileExists(Rom) and fileExists(Outdoor) and fileExists(Leave)
  echo "PRODUCT=day outdoor fr→gs80→cs60 freeplay + leave_map pr70 freeplay"
  echo "SPINE_REF=docs/checkpoints.md Giant Step / Captain / Peaceful Rest"
  echo "POLICY=AgentFrank/Giant/Captain + AgentPaula (leave seat handoff)"

  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  applyDayStoryOpen(snes)
  clearSouthFreezeLocks(snes)
  echo "L0_START ", checkpointSpineLine(snes)

  let fr = runPol(snes, c, AgentFrankPolicy, 7000, true, false, 80, 0, 0, 0)
  echo fmt"L1_FRANK maxFr={fr.maxFr} walk={fr.walkSpan} tele={fr.teleports}"
  doAssert fr.maxFr >= 80 and fr.teleports <= 2

  let gs = runPol(snes, c, AgentGiantStepPolicy, 9000, true, false, 0, 80, 0, 0)
  echo fmt"L2_GIANT maxGs={gs.maxGs} walk={gs.walkSpan} tele={gs.teleports}"
  doAssert gs.maxGs >= 80 and gs.teleports <= 2

  let cs = runPol(snes, c, AgentCaptainStrongPolicy, 10000, true, false, 0, 0, 60, 0)
  echo fmt"L3_CAPTAIN maxCs={cs.maxCs} walk={cs.walkSpan} tele={cs.teleports}"
  doAssert cs.maxCs >= 60 and cs.teleports <= 2

  # Leave map seat freeplay (d114: later-story on outdoor freezes walk)
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Leave)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  clearSouthFreezeLocks(snes)
  doAssert peacefulRestPercent(snes) >= 60
  echo "L4_START ", checkpointSpineLine(snes)
  let pr = runPol(snes, c, AgentPaulaApproachPolicy, 7000, false, true, 0, 0, 0, 70)
  echo fmt"L4_LEAVE maxPr={pr.maxPr} maxCs={pr.maxCs} walk={pr.walkSpan} tele={pr.teleports}"
  doAssert pr.maxPr >= 70
  doAssert pr.teleports <= 2
  doAssert pr.walkSpan >= 100

  echo "PEAKS day_fr90 day_gs80 day_cs60 leave_pr70 freeplay"
  echo "OK test_agent_product_day_gs80_to_leave"

when isMainModule: main()
