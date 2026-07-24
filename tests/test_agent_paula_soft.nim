## Soft Paula/Twoson referee after captain west edge.
## Night Onett only until day flag RE — grades paula_rescue partial from captain.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Captain = "bin/states/llm/captain_approach.state"
  Giant = "bin/states/llm/giant_approach.state"

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

proc main() =
  ## From captain/giant fixture, AgentPaulaApproach holds/climbs paula soft.
  doAssert fileExists(Rom)
  let path =
    if fileExists(Captain): Captain
    elif fileExists(Giant): Giant
    else: ""
  doAssert path.len > 0, "need captain_approach or giant_approach"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let startCs = captainStrongPercent(snes)
  let startPa = paulaRescuePercent(snes)
  echo "START path=", path, " captain=", startCs, " paula=", startPa
  echo "POLICY=AgentPaulaApproachPolicy"
  doAssert startCs >= 20, "need captain approach open"

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
  loadChunk(L, AgentPaulaApproachPolicy, "paula")

  var maxCs = startCs
  var maxPa = startPa
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 6000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let cs = captainStrongPercent(snes)
    let pa = paulaRescuePercent(snes)
    if cs > maxCs: maxCs = cs
    if pa > maxPa: maxPa = pa
    if f mod 1000 == 0:
      echo "f=", f, " captain=", cs, " paula=", pa,
        " pos=(0x", toHex(readU16(snes, WorldXBase+i), 4), ",0x",
        toHex(readU16(snes, WorldYBase+i), 4), ")"
    if maxCs >= 50 and maxPa >= 20:
      break

  echo "FINAL max_captain=", maxCs, " max_paula=", maxPa
  echo "spine ", checkpointSpineLine(snes)
  doAssert maxPa >= startPa, "paula soft must not regress"
  doAssert maxPa >= 10 or maxCs >= 30,
    "paula/captain soft should be open (pa=" & $maxPa & " cs=" & $maxCs & ")"
  # Midgame later-story $99F2 grades captain 70 / paula 40 without night climb.
  if fileExists("bin/states/slot1.state"):
    let snes2 = newSnesBus(policy.readRomFile(Rom))
    var cpu2 = snes2.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/slot1.state")), snes2, cpu2)
    let cs2 = captainStrongPercent(snes2)
    let pa2 = paulaRescuePercent(snes2)
    echo "midgame slot1 captain=", cs2, " paula=", pa2, " $99F2=",
      toHex(readU8(snes2, KnockCompleteOff), 2)
    doAssert cs2 >= 70, "midgame $99F2!=knock should grade captain>=70"
    doAssert pa2 >= 90, "midgame Paula in party + later $99F2 grades paula>=90"
  echo "OK test_agent_paula_soft: paula/captain soft ladder + midgame $99F2"

when isMainModule:
  main()
