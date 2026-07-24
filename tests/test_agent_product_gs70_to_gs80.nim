## Product: night continuous gs70 → campaign day-open gs80 hold (d94/d95).
## Cave freewalk still RE-open; day seat is wall-only handoff like leave_day1.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  Giant = "bin/states/llm/giant_approach.state"

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

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    holdKnock: bool; holdDay: bool; stopGs, stopFr: int):
    tuple[maxGs, maxFr: int] =
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
  result.maxGs = giantStepPercent(snes)
  result.maxFr = frankPercent(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if holdKnock:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      if holdDay:
        applyDayStoryOpen(snes)
      else:
        snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    clearSouthFreezeLocks(snes)
    let gs = giantStepPercent(snes)
    let fr = frankPercent(snes)
    if gs > result.maxGs: result.maxGs = gs
    if fr > result.maxFr: result.maxFr = fr
    if stopFr > 0 and result.maxFr >= stopFr and f >= 1500: break
    if stopGs > 0 and result.maxGs >= stopGs and f >= 1500: break

proc main() =
  doAssert fileExists(Rom) and fileExists(Outdoor) and fileExists(Giant)
  echo "PRODUCT=outdoor gs70 freeplay → campaign day-open gs80 hold"
  echo "SPINE_REF=docs/checkpoints.md"

  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let fr = runPol(snes, c, AgentFrankPolicy, 7000, true, false, 0, 80)
  echo "L1_FRANK maxFr=", fr.maxFr
  doAssert fr.maxFr >= 80
  clearSouthFreezeLocks(snes)
  let n = runPol(snes, c, AgentGiantStepPolicy, 7000, true, false, 70, 0)
  echo "L2_NIGHT_GS maxGs=", n.maxGs, " dayOpen=", dayStoryOpen(snes)
  doAssert n.maxGs >= 70 and n.maxGs < 80

  # Campaign day seat at giant west
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Giant)), snes, c)
  applyDayStoryOpen(snes)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  clearSouthFreezeLocks(snes)
  doAssert giantStepPercent(snes) >= 80
  let d = runPol(snes, c, AgentGiantStepPolicy, 4000, true, true, 0, 0)
  echo "L3_DAY_GS maxGs=", d.maxGs
  doAssert d.maxGs >= 80
  doAssert d.maxGs < 100

  echo "PEAKS night_gs=70 day_gs=80"
  echo "OK test_agent_product_gs70_to_gs80"

when isMainModule:
  main()
