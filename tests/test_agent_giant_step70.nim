## Giant Step past gs60: AgentGiantStepPolicy continuous west to police edge (gs70).
## checkpoints.md Titanic Ant / Giant Step soft ladder (not cave clear).

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  Downtown = "bin/states/llm/frank_downtown.state"
  Giant = "bin/states/llm/giant_approach.state"
  Arcade = "bin/states/llm/frank_arcade.state"

proc loadChunk(L: lua53.PState, src, label: string) =
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
  ## Bind landmarkTarget(name).
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc main() =
  ## Continuous Giant Step soft: frank corridor → gs70 police west edge.
  doAssert fileExists(Rom)
  let startPath =
    if fileExists(OutdoorPk): OutdoorPk
    elif fileExists(Arcade): Arcade
    elif fileExists(Downtown): Downtown
    elif fileExists(Giant): Giant
    else: ""
  doAssert startPath.len > 0, "need outdoor/frank/giant fixture"
  doAssert AgentGiantStepPolicy.len > 200
  doAssert "Giant Step" in AgentGiantStepPolicy or "giant" in AgentGiantStepPolicy.toLowerAscii

  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(startPath)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  doAssert knockComplete(snes)

  let startGs = giantStepPercent(snes)
  let startFr = frankPercent(snes)
  echo "START path=", startPath, " frank=", startFr, " giant=", startGs,
    " captain=", captainStrongPercent(snes)
  doAssert startGs < 70 or startPath == Giant,
    "outdoor/frank start should be pre-gs70 unless giant fixture already west"

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
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "skills")
  # Product path: frank corridor then giant west (two shipped policies).
  if startFr < 80 and startPath != Giant:
    loadChunk(L, AgentFrankPolicy, "frank")
    var maxFr = startFr
    for f in 1 .. 6000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, cpu, img)
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      let fr = frankPercent(snes)
      if fr > maxFr: maxFr = fr
      if maxFr >= 80: break
    echo "FRANK_LEG max_frank=", maxFr
    doAssert maxFr >= 80, "need frank 80 commercial before giant west"

  loadChunk(L, AgentGiantStepPolicy, "giant")
  var maxGs = giantStepPercent(snes)
  var maxFr2 = frankPercent(snes)
  var maxCs = captainStrongPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let gs = giantStepPercent(snes)
    let fr = frankPercent(snes)
    let cs = captainStrongPercent(snes)
    if gs > maxGs: maxGs = gs
    if fr > maxFr2: maxFr2 = fr
    if cs > maxCs: maxCs = cs
    if f mod 1500 == 0:
      echo "f=", f, " gs=", gs, " max_gs=", maxGs, " fr=", fr,
        " pos=(0x", toHex(readU16(snes, WorldXBase + i), 4), ",0x",
        toHex(readU16(snes, WorldYBase + i), 4), ")"
    if maxGs >= 70:
      break

  echo "FINAL max_giant=", maxGs, " max_frank=", maxFr2, " max_cs=", maxCs
  echo "SPINE ", checkpointSpineLine(snes)
  doAssert maxGs >= 60, "must reach giant_step 60 soft (got " & $maxGs & ")"
  doAssert maxGs >= 70, "AgentGiantStepPolicy must reach gs70 police west (got " & $maxGs & ")"
  writeFile("bin/states/llm/giant_approach.state", cast[string](serializeState(snes, cpu)))
  echo "WROTE bin/states/llm/giant_approach.state giant=", giantStepPercent(snes)
  echo "OK test_agent_giant_step70"

when isMainModule:
  main()
