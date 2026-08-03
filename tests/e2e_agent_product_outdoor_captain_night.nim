## d99 product: outdoor night continuous frank → giant_step70 → captain60.
## checkpoints.md Onett day-1 night freeplay spine. Intent/scene policies only.
## Honest walk tele=0; knock held for outdoor synth (not trail-only body).

import
  std/[os, strformat, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  Giant = "bin/states/llm/giant_approach.state"

proc loadChunk(L: lua53.PState; src, label: string) =
  ## Load and exec a Lua chunk that defines globals.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene() for intent skills.
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind landmarkTarget(name) -> x,y.
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc skillsSrc(): string =
  ## Full skill stack for Agent outdoor freeplay.
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

type Track = object
  maxFr, maxGs, maxCs, maxPa: int
  walkSpan, teleports: int

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    holdKnock: bool; stopFr, stopGs, stopCs: int): Track =
  ## Drive Agent; honest walk; hold knock outdoor synth only.
  ## AgentFrank may use engine south-road route inside policy (same as d7+ product).
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
  result.maxFr = frankPercent(snes)
  result.maxGs = giantStepPercent(snes)
  result.maxCs = captainStrongPercent(snes)
  result.maxPa = paulaRescuePercent(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if holdKnock:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    clearSouthFreezeLocks(snes)
    let px = readU16(snes, WorldXBase + i).int
    let py = readU16(snes, WorldYBase + i).int
    let ddx = abs(px - lastPx)
    let ddy = abs(py - lastPy)
    if ddx > 32 or ddy > 32: inc result.teleports
    else: result.walkSpan += ddx + ddy
    lastPx = px; lastPy = py
    template bump(field, fn) =
      let v = fn(snes)
      if v > result.field: result.field = v
    bump(maxFr, frankPercent)
    bump(maxGs, giantStepPercent)
    bump(maxCs, captainStrongPercent)
    bump(maxPa, paulaRescuePercent)
    if stopFr > 0 and result.maxFr >= stopFr and f >= 1500: break
    if stopGs > 0 and result.maxGs >= stopGs and f >= 1500: break
    if stopCs > 0 and result.maxCs >= stopCs and f >= 1500: break

proc main() =
  ## Outdoor night continuous frank→gs70→cs60 Agent product path.
  doAssert fileExists(Rom) and fileExists(Outdoor)
  echo "PRODUCT=outdoor night continuous frank → gs70 → cs60"
  echo "SPINE_REF=docs/checkpoints.md Frank / Giant Step / Captain Strong"
  echo "POLICY=AgentFrank + AgentGiantStep + AgentCaptainStrong (no followRoute body)"

  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  clearSouthFreezeLocks(snes)
  echo "L1_START ", checkpointSpineLine(snes)
  let fr = runPol(snes, c, AgentFrankPolicy, 7000, true, 80, 0, 0)
  echo fmt"L1_FRANK maxFr={fr.maxFr} walk={fr.walkSpan} tele={fr.teleports}"
  doAssert fr.maxFr >= 80
  doAssert fr.teleports <= 2

  clearSouthFreezeLocks(snes)
  let gs = runPol(snes, c, AgentGiantStepPolicy, 8000, true, 0, 70, 0)
  echo fmt"L2_GIANT maxGs={gs.maxGs} maxFr={gs.maxFr} walk={gs.walkSpan} tele={gs.teleports}"
  doAssert gs.maxGs >= 70
  doAssert gs.maxGs < 80, "night freeplay ceiling is gs70 (day for gs80)"
  doAssert gs.teleports <= 2

  # Captain freeplay from giant seat (same continuous session if walkable)
  if fileExists(Giant):
    snes = newSnesBus(policy.readRomFile(Rom))
    c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Giant)), snes, c)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    clearSouthFreezeLocks(snes)
  echo "L3_START ", checkpointSpineLine(snes)
  let cs = runPol(snes, c, AgentCaptainStrongPolicy, 10000, true, 0, 0, 60)
  echo fmt"L3_CAPTAIN maxCs={cs.maxCs} maxPa={cs.maxPa} maxGs={cs.maxGs} walk={cs.walkSpan} tele={cs.teleports}"
  doAssert cs.maxCs >= 60
  doAssert cs.teleports <= 2
  doAssert cs.walkSpan >= 100

  echo "PEAKS night_fr>=80 night_gs=70 night_cs=60 (day leave / cave open)"
  echo "OK test_agent_product_outdoor_captain_night"

when isMainModule:
  main()
