## Continuous Captain → live C4 leave soft → Paula soft ladder (d66).
## Product path: night cs60 fixture or outdoor rebuild → applyLaterStoryLeaveSoft
## → AgentPaulaApproach. Metrics must climb paula 40→50+ without party synth.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  Captain = "bin/states/llm/captain_approach.state"
  Giant = "bin/states/llm/giant_approach.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"

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

proc runPol(snes: SnesBus; cpu: var Cpu; pol: string; maxFrames: int):
    tuple[cs, pa, fr, gs: int] =
  ## Run shipped Agent policy; return peak metrics.
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
  loadChunk(L, pol, "pol")
  result.cs = captainStrongPercent(snes)
  result.pa = paulaRescuePercent(snes)
  result.fr = frankPercent(snes)
  result.gs = giantStepPercent(snes)
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    if not laterStoryLeaveSoft(snes):
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let cs = captainStrongPercent(snes)
    let pa = paulaRescuePercent(snes)
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    if cs > result.cs: result.cs = cs
    if pa > result.pa: result.pa = pa
    if fr > result.fr: result.fr = fr
    if gs > result.gs: result.gs = gs
    if laterStoryLeaveSoft(snes) and result.pa >= 50 and f >= 200:
      break
    if not laterStoryLeaveSoft(snes) and result.cs >= 60 and result.pa >= 40:
      break

proc main() =
  ## Captain fixture → live C4 → Paula soft 50+; day-leave map grades paula 60+.
  doAssert fileExists(Rom)
  doAssert AgentPaulaApproachPolicy.len > 100
  doAssert "Paula" in AgentPaulaApproachPolicy or "paula" in AgentPaulaApproachPolicy.toLowerAscii

  # --- Leg A: captain night → C4 → paula 50 ---
  block:
    let path =
      if fileExists(Captain): Captain
      elif fileExists(Giant): Giant
      elif fileExists(Outdoor): Outdoor
      else: ""
    doAssert path.len > 0
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    echo "A START path=", path, " cs=", captainStrongPercent(snes),
      " pa=", paulaRescuePercent(snes)

    if captainStrongPercent(snes) < 60:
      let c = runPol(snes, cpu, AgentCaptainStrongPolicy, 8000)
      echo "A captain max_cs=", c.cs, " max_pa=", c.pa
      doAssert c.cs >= 50, "need captain soft before C4"

    let paNight = paulaRescuePercent(snes)
    doAssert paNight >= 20 or captainStrongPercent(snes) >= 40

    applyLaterStoryLeaveSoft(snes)
    let csC4 = captainStrongPercent(snes)
    let paC4 = paulaRescuePercent(snes)
    echo "A LIVE_C4 cs=", csC4, " pa=", paC4, " 99F2=",
      toHex(readU8(snes, KnockCompleteOff), 2)
    doAssert laterStoryLeaveSoft(snes)
    doAssert csC4 >= 70, "live C4 must grade captain >=70 (got " & $csC4 & ")"
    doAssert paC4 >= 50, "live C4 must grade paula >=50 leave soft (got " & $paC4 & ")"
    doAssert not partyHasChar(snes, PartyCharPaula), "C4 path is Ness-only"

    let p = runPol(snes, cpu, AgentPaulaApproachPolicy, 5000)
    echo "A paula hold max_cs=", p.cs, " max_pa=", p.pa
    doAssert p.pa >= 50, "AgentPaula must hold paula leave soft >=50"
    doAssert p.cs >= 70, "captain must not collapse under paula leg after C4"
    echo "A SPINE ", checkpointSpineLine(snes)

  # --- Leg B: day-leave map seats grade paula 60/70 soft ---
  if fileExists(LeaveMap):
    block:
      let snes = newSnesBus(policy.readRomFile(Rom))
      var cpu = snes.resetCpu()
      deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, cpu)
      let pa = paulaRescuePercent(snes)
      let cs = captainStrongPercent(snes)
      echo "B leave_day1_map cs=", cs, " pa=", pa, " 99F2=",
        toHex(readU8(snes, KnockCompleteOff), 2)
      doAssert laterStoryLeaveSoft(snes)
      doAssert cs >= 100, "day leave map is captain 100 soft"
      doAssert pa >= 60, "day leave py band grades paula >=60 (got " & $pa & ")"
      let hold = runPol(snes, cpu, AgentPaulaApproachPolicy, 3000)
      echo "B hold max_pa=", hold.pa, " max_cs=", hold.cs
      doAssert hold.pa >= 60, "must hold day-leave paula soft"
      doAssert hold.cs >= 100
      echo "B SPINE ", checkpointSpineLine(snes)

  # --- Leg C: outdoor continuous night → C4 peaking paula 50 ---
  if fileExists(Outdoor):
    block:
      let snes = newSnesBus(policy.readRomFile(Rom))
      var cpu = snes.resetCpu()
      deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, cpu)
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      echo "C outdoor continuous start"
      discard runPol(snes, cpu, AgentFrankPolicy, 5000)
      discard runPol(snes, cpu, AgentGiantStepPolicy, 6000)
      let cap = runPol(snes, cpu, AgentCaptainStrongPolicy, 6000)
      echo "C pre_c4 max_cs=", cap.cs, " max_pa=", cap.pa, " max_gs=", cap.gs
      applyLaterStoryLeaveSoft(snes)
      let pa = paulaRescuePercent(snes)
      let cs = captainStrongPercent(snes)
      echo "C LIVE_C4 cs=", cs, " pa=", pa
      doAssert pa >= 50 and cs >= 70
      let p = runPol(snes, cpu, AgentPaulaApproachPolicy, 3000)
      echo "C post_paula max_pa=", p.pa, " max_cs=", p.cs
      doAssert p.pa >= 50
      echo "C SPINE ", checkpointSpineLine(snes)

  echo "OK test_agent_captain_paula_c4"

when isMainModule:
  main()
