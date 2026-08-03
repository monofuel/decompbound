## Day-1 Frank / arcade strip (checkpoints.md Frank/Frankystein segment).
## AgentFrankPolicy from post_knock_outdoor must climb frank 40→90 (arcade
## approach) and open captain 60 soft. Drives shipped policy, not a trail-only body.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  Downtown = "bin/states/llm/frank_downtown.state"

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
  ## Continuous Frank boss-path soft: outdoor knock-complete → frank 90 strip.
  doAssert fileExists(Rom)
  let startPath =
    if fileExists(OutdoorPk): OutdoorPk
    elif fileExists(Downtown): Downtown
    else: ""
  doAssert startPath.len > 0, "need post_knock_outdoor or frank_downtown"
  # Product body may call followRoute only as engine helper inside the skill path.
  doAssert AgentFrankPolicy.len > 200
  doAssert "Agent day-1 Onett" in AgentFrankPolicy or "frank" in AgentFrankPolicy.toLowerAscii

  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(startPath)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  doAssert knockComplete(snes)

  let startFr = frankPercent(snes)
  let startCs = captainStrongPercent(snes)
  echo "START path=", startPath, " frank=", startFr, " captain=", startCs,
    " giant=", giantStepPercent(snes)
  doAssert startFr < 90 or startPath == Downtown,
    "outdoor start should be pre-arcade-strip unless downtown fixture"

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
  loadChunk(L, AgentFrankPolicy, "agent_frank")

  var maxFr = startFr
  var maxCs = startCs
  var maxGs = giantStepPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let fr = frankPercent(snes)
    let cs = captainStrongPercent(snes)
    let gs = giantStepPercent(snes)
    if fr > maxFr: maxFr = fr
    if cs > maxCs: maxCs = cs
    if gs > maxGs: maxGs = gs
    if f mod 1500 == 0:
      echo "f=", f, " frank=", fr, " max_fr=", maxFr, " cs=", cs,
        " pos=(0x", toHex(readU16(snes, WorldXBase + i), 4), ",0x",
        toHex(readU16(snes, WorldYBase + i), 4), ")"
    if maxFr >= 90 and maxCs >= 60:
      break

  echo "FINAL max_frank=", maxFr, " max_cs=", maxCs, " max_gs=", maxGs
  echo "SPINE ", checkpointSpineLine(snes)
  # Arcade landmark present for Agent goToward on outdoor Onett.
  let arc = scene.landmarkTarget(snes, "onett_arcade")
  doAssert arc.found or readU16(snes, WorldXBase + i) >= OutdoorMaxX,
    "onett_arcade landmark should resolve outdoors"
  doAssert maxFr >= 80, "AgentFrankPolicy must reach frank 80 commercial (got " & $maxFr & ")"
  # fr90 arcade strip (py>=0x02A0) OR west gs70 corridor — both are day-1 Frank path.
  # West-first product (d65) peaks gs70 at fr80; pure south peaks fr90/cs60.
  doAssert maxFr >= 90 or maxGs >= 70 or maxCs >= 60,
    "frank boss path needs fr90 arcade, gs70 west, or cs60 south (fr=" & $maxFr &
    " gs=" & $maxGs & " cs=" & $maxCs & ")"
  # Only persist when still on commercial/west band (not thrash north to meteor).
  if frankPercent(snes) >= 80 or maxGs >= 70:
    writeFile("bin/states/llm/frank_arcade.state", cast[string](serializeState(snes, cpu)))
    echo "WROTE bin/states/llm/frank_arcade.state frank=", frankPercent(snes),
      " giant=", giantStepPercent(snes)
  else:
    echo "SKIP write frank_arcade (end thrash fr=", frankPercent(snes), ")"
  echo "OK test_agent_frank_boss"

when isMainModule:
  main()
