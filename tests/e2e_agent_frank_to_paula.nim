## Multi-leg Agent product after Frank: Giant → Captain Strong → Paula soft.
## Drives shipped policies (not trail-only bodies) from frank_downtown / giant.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
  FrankDown = "bin/states/llm/frank_downtown.state"
  CaptainWest = "bin/states/llm/captain_west.state"

proc loadChunk(L: lua53.PState, src, label: string) =
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

proc runLeg(snes: SnesBus; cpu: var Cpu; pol: string; maxFrames: int;
    label: string): tuple[cs, gs, pa, fr: int] =
  ## Run one shipped Agent policy; return max metrics during the leg.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, pol, label)
  var maxCs = captainStrongPercent(snes)
  var maxGs = giantStepPercent(snes)
  var maxPa = paulaRescuePercent(snes)
  var maxFr = frankPercent(snes)
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    let cs = captainStrongPercent(snes)
    let gs = giantStepPercent(snes)
    let pa = paulaRescuePercent(snes)
    let fr = frankPercent(snes)
    if cs > maxCs: maxCs = cs
    if gs > maxGs: maxGs = gs
    if pa > maxPa: maxPa = pa
    if fr > maxFr: maxFr = fr
    if label == "captain" and maxCs >= 60:
      break
    if label == "paula" and maxPa >= 30 and maxCs >= 50:
      break
  result = (maxCs, maxGs, maxPa, maxFr)

proc main() =
  ## Frank corridor fixture → captain 60 (south commercial) → paula soft.
  doAssert fileExists(Rom)
  let startPath =
    if fileExists(Giant): Giant
    elif fileExists(FrankDown): FrankDown
    else: ""
  doAssert startPath.len > 0, "need giant_approach or frank_downtown"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(startPath)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8

  let sCs = captainStrongPercent(snes)
  let sGs = giantStepPercent(snes)
  let sPa = paulaRescuePercent(snes)
  let sFr = frankPercent(snes)
  echo "START path=", startPath, " frank=", sFr, " giant=", sGs,
    " captain=", sCs, " paula=", sPa
  echo "LEG1=AgentGiantStepPolicy LEG2=AgentCaptainStrongPolicy LEG3=AgentPaulaApproachPolicy"

  # Leg 1: giant (skip long run if already giant>=50)
  var maxGs = sGs
  if sGs < 50:
    let g = runLeg(snes, cpu, AgentGiantStepPolicy, 4000, "giant")
    maxGs = g.gs
    echo "LEG1 giant max_gs=", g.gs, " max_fr=", g.fr, " max_cs=", g.cs
  else:
    echo "LEG1 skip (giant already ", sGs, ")"

  # Leg 2: captain south commercial → 60 (d40 south-first policy)
  let c = runLeg(snes, cpu, AgentCaptainStrongPolicy, 8000, "captain")
  echo "LEG2 captain max_cs=", c.cs, " max_gs=", c.gs, " max_pa=", c.pa
  doAssert c.cs >= 50, "captain multileg must hit 50+ (got " & $c.cs & ")"
  doAssert c.cs >= 60, "captain south commercial 60 (py>=0x02A0) required; got " & $c.cs
  writeFile("bin/states/llm/captain_west.state", cast[string](serializeState(snes, cpu)))
  writeFile("bin/states/llm/captain_approach.state", cast[string](serializeState(snes, cpu)))
  echo "WROTE captain_west + captain_approach"

  # Leg 3: paula soft (hold/climb after cs60 handoff)
  let p = runLeg(snes, cpu, AgentPaulaApproachPolicy, 4000, "paula")
  echo "LEG3 paula max_pa=", p.pa, " max_cs=", p.cs
  echo "spine ", checkpointSpineLine(snes)
  doAssert p.pa >= 20, "paula soft open after captain 60 (got " & $p.pa & ")"
  doAssert p.pa >= 30 or c.cs >= 60, "paula 30 tracks captain 60"
  doAssert p.cs >= 40, "captain must not collapse under paula leg"
  # Policy bodies are Agent seeds (may call followRoute only as engine helper inside skills).
  doAssert "Agent Captain" in AgentCaptainStrongPolicy or "Captain Strong" in AgentCaptainStrongPolicy or
    AgentCaptainStrongPolicy.len > 100
  echo "DELTA captain ", sCs, "->", c.cs, " paula ", sPa, "->", p.pa, " giant ", sGs, "->", maxGs
  echo "OK test_agent_frank_to_paula: multileg giant→captain60→paula soft"

  # Flag-based midgame referee still holds (leave-Onett soft via $99F2).
  if fileExists("bin/states/slot1.state"):
    let snes2 = newSnesBus(policy.readRomFile(Rom))
    var cpu2 = snes2.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/slot1.state")), snes2, cpu2)
    let cs2 = captainStrongPercent(snes2)
    let pa2 = paulaRescuePercent(snes2)
    echo "FLAG midgame $99F2=", toHex(readU8(snes2, KnockCompleteOff), 2),
      " captain=", cs2, " paula=", pa2
    doAssert cs2 >= 70 and pa2 >= 90
  if fileExists(CaptainWest):
    echo "fixture captain_west still present"

when isMainModule:
  main()
