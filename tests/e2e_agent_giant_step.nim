## Next referee after Frank: AgentGiantStepPolicy from frank_downtown advances
## giant_step percent (and keeps frank high). Headless multi-leg product path.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Downtown = "bin/states/llm/frank_downtown.state"
  Corridor = "bin/states/llm/frank_corridor.state"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"

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

proc ensureDowntown() =
  ## Prefer real downtown fixture; else climb with AgentFrank first.
  if fileExists(Downtown): return
  doAssert fileExists(OutdoorPk), "need post_knock_outdoor or frank_downtown"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua &
    "\n" & IntentNavSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentFrankPolicy, "frank")
  for f in 1 .. 6000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    if frankPercent(snes) >= 60:
      break
  doAssert frankPercent(snes) >= 60
  writeFile(Downtown, cast[string](serializeState(snes, cpu)))

proc runGiant(path: string; wantClimb: bool) =
  ## Drive AgentGiantStepPolicy from a real LLM fixture; require climb when asked.
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let startFr = frankPercent(snes)
  let startGs = giantStepPercent(snes)
  let startCs = captainStrongPercent(snes)
  echo "START path=", path, " frank=", startFr, " giant=", startGs, " captain=", startCs
  echo "POLICY=AgentGiantStepPolicy"

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
  loadChunk(L, AgentGiantStepPolicy, "giant")

  var maxFr = startFr
  var maxGs = startGs
  var maxCs = startCs
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    let cs = captainStrongPercent(snes)
    if fr > maxFr: maxFr = fr
    if gs > maxGs: maxGs = gs
    if cs > maxCs: maxCs = cs
    if f mod 1000 == 0:
      echo "f=", f, " frank=", fr, " giant=", gs, " captain=", cs,
        " pos=(0x", toHex(readU16(snes, WorldXBase+i), 4), ",0x",
        toHex(readU16(snes, WorldYBase+i), 4), ")"
    if maxGs >= 50 and maxFr >= 80:
      break

  echo "FINAL max_frank=", maxFr, " max_giant=", maxGs, " max_captain=", maxCs
  echo "spine ", checkpointSpineLine(snes)
  doAssert maxGs >= startGs, "giant_step must not regress"
  if wantClimb:
    doAssert maxGs > startGs or maxFr > startFr,
      "must climb giant/frank from " & path & " (start gs=" & $startGs &
      " max gs=" & $maxGs & " start fr=" & $startFr & " max fr=" & $maxFr & ")"
    doAssert maxGs >= 40, "giant_step downtown approach is 40+ (got " & $maxGs & ")"
    doAssert maxFr >= 60, "frank downtown is 60+ (got " & $maxFr & ")"
  else:
    doAssert maxGs >= 40 or maxFr >= 60,
      "must hold frank downtown / giant approach (gs=" & $maxGs & " fr=" & $maxFr & ")"

proc main() =
  ## Climb giant_step from post-Frank mid-town corridor; hold on downtown fixture.
  doAssert fileExists(Rom)
  ensureDowntown()
  # Primary: from frank_corridor (frank~50) climb to downtown giant_step 40+.
  if fileExists(Corridor):
    runGiant(Corridor, wantClimb = true)
  else:
    runGiant(OutdoorPk, wantClimb = true)
  # Secondary: from frank_downtown climb west edge to giant_step 60.
  if fileExists(Downtown):
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Downtown)), snes, cpu)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let startGs = giantStepPercent(snes)
    echo "DOWNTOWN climb start giant=", startGs, " frank=", frankPercent(snes)
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let ctx = policy.PolicyContext(
      snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
    let L = lua53.newstate()
    L.openSandbox()
    policy.setupPolicyApi(L, ctx)
    L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
    L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
    let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
      NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua &
      "\n" & IntentNavSkillLua
    loadChunk(L, skills, "sk")
    loadChunk(L, AgentGiantStepPolicy, "giant")
    var maxGs = startGs
    for f in 1 .. 8000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, cpu, img)
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      let gs = giantStepPercent(snes)
      if gs > maxGs: maxGs = gs
      if maxGs >= 60: break
    echo "DOWNTOWN climb max_giant=", maxGs, " frank=", frankPercent(snes)
    doAssert maxGs >= 60, "giant_step west edge is 60 (got " & $maxGs & ")"
    writeFile("bin/states/llm/giant_approach.state", cast[string](serializeState(snes, cpu)))
    echo "WROTE bin/states/llm/giant_approach.state"
  echo "OK test_agent_giant_step: giant_step referee advanced from post-Frank fixture"

when isMainModule:
  main()
