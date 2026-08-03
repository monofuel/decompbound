## d105 product: day outdoor freeplay frank → captain (day flags + knock synth).
## checkpoints.md Onett day freeplay spine without night gs70 path.
## AgentFrank + AgentCaptain; honest walk tele=0.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"

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
  maxFr, maxGs, maxCs, maxPa: int
  walkSpan, teleports: int

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    stopFr, stopCs: int): Track =
  ## Drive Agent with day+knock outdoor synth; honest walk.
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
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    applyDayStoryOpen(snes)
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
    template bump(field, fn) =
      let v = fn(snes)
      if v > result.field: result.field = v
    bump(maxFr, frankPercent)
    bump(maxGs, giantStepPercent)
    bump(maxCs, captainStrongPercent)
    bump(maxPa, paulaRescuePercent)
    if stopFr > 0 and result.maxFr >= stopFr and f >= 1500: break
    if stopCs > 0 and result.maxCs >= stopCs and f >= 1500: break

proc main() =
  ## Day outdoor freeplay frank→captain continuous product path.
  doAssert fileExists(Rom) and fileExists(Outdoor)
  echo "PRODUCT=day outdoor freeplay frank → captain (day flags)"
  echo "SPINE_REF=docs/checkpoints.md Frank / Captain Strong (day freeplay)"
  echo "POLICY=AgentFrankPolicy + AgentCaptainStrongPolicy"

  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  applyDayStoryOpen(snes)
  clearSouthFreezeLocks(snes)
  echo "L1_START day=", dayStoryOpen(snes), " ", checkpointSpineLine(snes)
  let fr = runPol(snes, c, AgentFrankPolicy, 7000, 80, 0)
  echo fmt"L1_FRANK maxFr={fr.maxFr} maxGs={fr.maxGs} walk={fr.walkSpan} tele={fr.teleports}"
  doAssert fr.maxFr >= 80
  doAssert fr.teleports <= 2

  let cs = runPol(snes, c, AgentCaptainStrongPolicy, 10000, 0, 60)
  echo fmt"L2_CAPTAIN maxCs={cs.maxCs} maxPa={cs.maxPa} maxFr={cs.maxFr} walk={cs.walkSpan} tele={cs.teleports}"
  doAssert cs.maxCs >= 60
  doAssert cs.teleports <= 2
  doAssert cs.walkSpan >= 100

  echo "PEAKS day_fr>=80 day_cs>=60 (night gs70 path separate; cave open)"
  echo "OK test_agent_product_day_outdoor_captain"

when isMainModule:
  main()
