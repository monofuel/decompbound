## Headless multileg after Frank: giant → captain → paula + stuck recovery sample.
## Logs metric deltas for SCRATCH; drives shipped Agent policies.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
  Frank = "bin/states/llm/frank_downtown.state"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  Rollback = "bin/states/llm/rollback.state"

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

proc runWithStuck(path, pol, label: string; frames, stuckThr: int) =
  if not fileExists(path):
    echo "SKIP path=", path
    return
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  writeFile(Rollback, cast[string](serializeState(snes, cpu)))
  echo fmt"STUCK_ANCHOR: armed {Rollback} from {path}"

  let startCs = captainStrongPercent(snes)
  let startGs = giantStepPercent(snes)
  let startPa = paulaRescuePercent(snes)
  let startFr = frankPercent(snes)
  echo fmt"START {label} frank={startFr} giant={startGs} captain={startCs} paula={startPa}"
  echo "POLICY=", label, " stuck_threshold=", stuckThr

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
  loadChunk(L, pol, label)

  var maxCs = startCs
  var maxGs = startGs
  var maxPa = startPa
  var maxFr = startFr
  var stuck = 0
  var recoveries = 0
  var prevX = readU16(snes, WorldXBase + PlayerSlot * SlotIndexStride)
  var prevY = readU16(snes, WorldYBase + PlayerSlot * SlotIndexStride)
  var prevCs = startCs
  let i = PlayerSlot * SlotIndexStride

  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8

    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let cs = captainStrongPercent(snes)
    let gs = giantStepPercent(snes)
    let pa = paulaRescuePercent(snes)
    let fr = frankPercent(snes)
    if cs > maxCs: maxCs = cs
    if gs > maxGs: maxGs = gs
    if pa > maxPa: maxPa = pa
    if fr > maxFr: maxFr = fr

    let posDelta = abs(px - prevX) + abs(py - prevY)
    if posDelta <= 4 and cs <= prevCs:
      stuck.inc
    else:
      stuck = 0
    prevX = px
    prevY = py
    if cs > prevCs:
      prevCs = cs
      # Forward milestone so recovery lands at best captain seat.
      writeFile(Rollback, cast[string](serializeState(snes, cpu)))
      echo fmt"MILESTONE captain={cs} pos=(0x{px:04X},0x{py:04X}) -> {Rollback}"

    if stuck > stuckThr:
      recoveries.inc
      echo fmt"STUCK_DETECTED (counter={stuck}); STUCK_RECOVERY rollback -> {Rollback} (recovery#{recoveries})"
      deserializeState(cast[seq[byte]](readFile(Rollback)), snes, cpu)
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
      loadChunk(L, pol, "post_stuck_replan")
      echo fmt"STUCK_RECOVERY: policy reloaded {label}"
      stuck = 0
      prevX = readU16(snes, WorldXBase + i)
      prevY = readU16(snes, WorldYBase + i)
      prevCs = captainStrongPercent(snes)

    if f mod 1500 == 0:
      echo fmt"f={f} cs={cs} gs={gs} pa={pa} pos=(0x{px:04X},0x{py:04X}) stuck={stuck}"
    if label == "captain" and maxCs >= 50:
      break
    if label == "paula" and maxPa >= 30 and maxCs >= 50:
      break
    if label == "giant" and maxGs >= 50:
      break

  echo fmt"FINAL {label} max_cs={maxCs} max_gs={maxGs} max_pa={maxPa} max_fr={maxFr} recoveries={recoveries}"
  echo fmt"DELTA {label} captain {startCs}->{maxCs} paula {startPa}->{maxPa} giant {startGs}->{maxGs}"
  echo "spine ", checkpointSpineLine(snes)
  if maxCs >= 50:
    writeFile("bin/states/llm/captain_west.state", cast[string](serializeState(snes, cpu)))
    echo "WROTE captain_west"
  if maxCs >= 40:
    writeFile("bin/states/llm/captain_approach.state", cast[string](serializeState(snes, cpu)))

proc main() =
  let base =
    if fileExists(Giant): Giant
    elif fileExists(Frank): Frank
    elif fileExists(Outdoor): Outdoor
    else: ""
  doAssert base.len > 0
  echo "=== multileg post-frank from ", base, " ==="
  runWithStuck(base, AgentGiantStepPolicy, "giant", 3000, 80)
  let capBase =
    if fileExists(Giant): Giant else: base
  runWithStuck(capBase, AgentCaptainStrongPolicy, "captain", 10000, 100)
  let paulaBase =
    if fileExists("bin/states/llm/captain_west.state"):
      "bin/states/llm/captain_west.state"
    elif fileExists("bin/states/llm/captain_approach.state"):
      "bin/states/llm/captain_approach.state"
    else: capBase
  runWithStuck(paulaBase, AgentPaulaApproachPolicy, "paula", 4000, 90)
  echo "OK probe_multileg_post_frank"

when isMainModule:
  main()
