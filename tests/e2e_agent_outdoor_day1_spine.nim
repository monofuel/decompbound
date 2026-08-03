## Continuous outdoor product: post_knock_outdoor → Frank → Giant → Captain.
## Agent policies only; peak metrics (not end-state). d80 Frank west-escape fix.

import
  std/[os],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"

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

proc runLeg(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    stopFr, stopGs, stopCs: int): tuple[maxFr, maxGs, maxCs: int] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skillsSrc(), "skills")
  loadChunk(L, pol, "pol")
  result.maxFr = frankPercent(snes)
  result.maxGs = giantStepPercent(snes)
  result.maxCs = captainStrongPercent(snes)
  for f in 1 .. frames:
    ctx.frameCount = f
    # Clear freeze before pad so locomotion can act this frame.
    clearSouthFreezeLocks(snes)
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    clearSouthFreezeLocks(snes)
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    let cs = captainStrongPercent(snes)
    if fr > result.maxFr: result.maxFr = fr
    if gs > result.maxGs: result.maxGs = gs
    if cs > result.maxCs: result.maxCs = cs
    if stopFr > 0 and result.maxFr >= stopFr and f >= 2000: break
    if stopGs > 0 and result.maxGs >= stopGs and f >= 2000: break
    if stopCs > 0 and result.maxCs >= stopCs and f >= 2000: break

proc main() =
  doAssert fileExists(Rom) and fileExists(Outdoor)
  echo "POLICY=AgentFrank + AgentGiant + AgentCaptain continuous outdoor"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  echo "START fr=", frankPercent(snes), " gs=", giantStepPercent(snes)
  doAssert frankPercent(snes) < 80

  let f = runLeg(snes, c, AgentFrankPolicy, 10000, 80, 0, 0)
  echo "FRANK maxFr=", f.maxFr, " maxGs=", f.maxGs, " maxCs=", f.maxCs
  doAssert f.maxFr >= 80, "continuous frank commercial 80"

  # d85: escapeMenu clears $10E5/$10E7 C0 freeze so continuous gs70 is freeplay.
  clearSouthFreezeLocks(snes)
  let g = runLeg(snes, c, AgentGiantStepPolicy, 10000, 0, 70, 0)
  echo "GIANT maxFr=", g.maxFr, " maxGs=", g.maxGs, " maxCs=", g.maxCs
  doAssert g.maxGs >= 70, "continuous outdoor+freeze-clear must hit gs70 (got " & $g.maxGs & ")"

  let cap = runLeg(snes, c, AgentCaptainStrongPolicy, 10000, 0, 0, 60)
  echo "CAPTAIN maxFr=", cap.maxFr, " maxGs=", cap.maxGs, " maxCs=", cap.maxCs
  doAssert cap.maxCs >= 60, "captain continuous cs60 (got " & $cap.maxCs & ")"
  echo "PEAKS fr=", max(f.maxFr, max(g.maxFr, cap.maxFr)),
    " gs=", max(f.maxGs, max(g.maxGs, cap.maxGs)),
    " cs=", max(f.maxCs, max(g.maxCs, cap.maxCs))
  echo "OK test_agent_outdoor_day1_spine"

when isMainModule:
  main()
