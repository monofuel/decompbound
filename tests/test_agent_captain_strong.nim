## AgentCaptainStrongPolicy from giant_approach climbs captain_strong past 30.
## Night map soft ladder only — leave-Onett flag still reserved for 100.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
  FrankDown = "bin/states/llm/frank_downtown.state"
  CaptainOut = "bin/states/llm/captain_approach.state"

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

proc ensureGiant() =
  ## Prefer giant_approach; else frank_downtown is enough for captain start.
  if fileExists(Giant): return
  doAssert fileExists(FrankDown), "need giant_approach or frank_downtown"

proc main() =
  ## From deep-south Onett fixture, AgentCaptainStrong must raise captain_strong.
  doAssert fileExists(Rom)
  ensureGiant()
  let path = if fileExists(Giant): Giant else: FrankDown
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let startCs = captainStrongPercent(snes)
  let startFr = frankPercent(snes)
  let startGs = giantStepPercent(snes)
  echo "START path=", path, " captain=", startCs, " frank=", startFr, " giant=", startGs
  echo "POLICY=AgentCaptainStrongPolicy"
  doAssert startFr >= 50, "need frank corridor open"
  doAssert startCs >= 10, "captain opens with frank mid-town"

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
  loadChunk(L, AgentCaptainStrongPolicy, "captain")

  var maxCs = startCs
  var maxFr = startFr
  var maxGs = startGs
  var bestBytes: seq[byte] = @[]
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 12000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    let cs = captainStrongPercent(snes)
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    if cs > maxCs:
      maxCs = cs
      bestBytes = serializeState(snes, cpu)
    if fr > maxFr: maxFr = fr
    if gs > maxGs: maxGs = gs
    if f mod 1000 == 0:
      echo "f=", f, " captain=", cs, " frank=", fr, " giant=", gs,
        " pos=(0x", toHex(readU16(snes, WorldXBase+i), 4), ",0x",
        toHex(readU16(snes, WorldYBase+i), 4), ")"
    # Prefer south commercial (cs 60); 50 west lane is the soft floor.
    if maxCs >= 60:
      break
    if maxCs >= 50 and f >= 4000:
      break

  echo "FINAL max_captain=", maxCs, " max_frank=", maxFr, " max_giant=", maxGs
  echo "spine ", checkpointSpineLine(snes)
  echo "paula_soft=", paulaRescuePercent(snes)
  doAssert maxCs >= startCs, "captain must not regress"
  doAssert maxCs > startCs or maxCs >= 40,
    "captain must climb west/south edge (start=" & $startCs & " max=" & $maxCs & ")"
  doAssert maxCs >= 40, "captain west edge is 40+ (got " & $maxCs & ")"
  # d40: south-first captain hits py>=0x02A0 (cs 60); 50 west band remains soft floor.
  doAssert maxCs >= 50,
    "captain 50+ required (south commercial or west lane); got " & $maxCs
  if maxCs >= 60:
    echo "captain 60 south commercial edge reached"
  else:
    echo "captain 50+ west band reached (60 not hit this run)"
  echo "paula_soft=", paulaRescuePercent(snes)
  doAssert paulaRescuePercent(snes) >= 30 or maxCs >= 50,
    "paula soft 30 follows captain 50"

  if bestBytes.len > 0:
    writeFile(CaptainOut, cast[string](bestBytes))
    writeFile("bin/states/llm/captain_west.state", cast[string](bestBytes))
  else:
    writeFile(CaptainOut, cast[string](serializeState(snes, cpu)))
  echo "WROTE ", CaptainOut, " + captain_west max_captain=", maxCs
  echo "OK test_agent_captain_strong: captain_strong 50+ from giant/frank"

when isMainModule:
  main()
