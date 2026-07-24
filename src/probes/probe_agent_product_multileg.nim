## Product multi-leg Agent probe: bedroom/onett/post-knock outdoor → metric deltas,
## stuck recovery, scene summary. Writes structured lines for SCRATCH capture.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Rollback = "bin/states/llm/rollback.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene() JSON for intent skills.
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

proc dumpScene(snes: SnesBus; tag: string) =
  ## Print perception summary for SCRATCH (overworld scene fields).
  let sj = scene.sceneJson(snes)
  let head = if sj.len > 400: sj[0 ..< 400] & "..." else: sj
  echo "SCENE ", tag, " len=", sj.len, " head=", head
  echo "  room=", currentRoomLabel(snes)
  echo "  ", checkpointSpineLine(snes)

proc runLeg(path, pol, label: string; frames, stuckThr: int; allowRoute: bool) =
  ## Run one Agent product leg; log metric deltas + stuck recovery.
  if not fileExists(path):
    echo "SKIP leg=", label, " missing=", path
    return
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  writeFile(Rollback, cast[string](serializeState(snes, c)))
  echo fmt"=== LEG {label} from {path} frames={frames} ==="
  echo "STUCK_ANCHOR: armed ", Rollback
  dumpScene(snes, "start_" & label)
  let startTg = touchGrassPercent(snes)
  let startPokey = pokeyPercent(snes)
  let startKnock = pokeyKnockPercent(snes)
  let startBuzz = buzzBuzzPercent(snes)
  let startSun = sunrisePercent(snes)
  let startFrank = frankPercent(snes)
  let startCs = captainStrongPercent(snes)
  let startFo = foursidePercent(snes)
  echo fmt"START_METRICS tg={startTg} pokey={startPokey} knock={startKnock} " &
    fmt"buzz={startBuzz} sun={startSun} frank={startFrank} cs={startCs} fo={startFo}"
  echo "POLICY=", label, " body_len=", pol.len
  if not allowRoute:
    doAssert "followRoute(" notin pol,
      "Agent product leg body must not call followRoute directly: " & label

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
  loadChunk(L, pol, label)

  var maxTg = startTg
  var maxPokey = startPokey
  var maxKnock = startKnock
  var maxBuzz = startBuzz
  var maxSun = startSun
  var maxFrank = startFrank
  var maxCs = startCs
  var maxFo = startFo
  var stuck = 0
  var recoveries = 0
  let i = PlayerSlot * SlotIndexStride
  var prevX = readU16(snes, WorldXBase + i)
  var prevY = readU16(snes, WorldYBase + i)

  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let tg = touchGrassPercent(snes)
    let pk = pokeyPercent(snes)
    let kn = pokeyKnockPercent(snes)
    let bz = buzzBuzzPercent(snes)
    let sn = sunrisePercent(snes)
    let fr = frankPercent(snes)
    let cs = captainStrongPercent(snes)
    let fo = foursidePercent(snes)
    if tg > maxTg: maxTg = tg
    if pk > maxPokey: maxPokey = pk
    if kn > maxKnock: maxKnock = kn
    if bz > maxBuzz: maxBuzz = bz
    if sn > maxSun: maxSun = sn
    if fr > maxFrank: maxFrank = fr
    if cs > maxCs: maxCs = cs
    if fo > maxFo: maxFo = fo
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let posDelta = abs(px - prevX) + abs(py - prevY)
    let metricProg = tg > startTg or kn > startKnock or pk > startPokey or
      fr > startFrank or cs > startCs or fo > startFo
    if posDelta <= 1 and not metricProg:
      stuck.inc
    else:
      stuck = 0
      if metricProg:
        writeFile(Rollback, cast[string](serializeState(snes, c)))
    prevX = px
    prevY = py
    if stuck > stuckThr:
      recoveries.inc
      echo fmt"STUCK_DETECTED (counter={stuck}); STUCK_RECOVERY rollback -> {Rollback} recovery#{recoveries}"
      deserializeState(cast[seq[byte]](readFile(Rollback)), snes, c)
      loadChunk(L, pol, "post_stuck_replan")
      echo fmt"STUCK_RECOVERY: policy reloaded {label}"
      stuck = 0
      prevX = readU16(snes, WorldXBase + i)
      prevY = readU16(snes, WorldYBase + i)
    if f mod 1500 == 0:
      echo fmt"f={f} tg={tg} kn={kn} frank={fr} cs={cs} fo={fo} pos=(0x{px:04X},0x{py:04X}) stuck={stuck}"
    if label == "house" and maxTg >= 100: break
    # Match test_agent_knock_bed / probe_home_knock_leg: bedroom knock≥80.
    if label == "home" and maxKnock >= 80: break
    if label == "outdoor" and maxPokey >= 80: break  # site box (d46 goToMeteor)
    # Day-1 arcade strip (frank 90) + captain 60 soft after commercial band.
    if label == "frank" and maxFrank >= 90 and maxCs >= 60: break
    if label == "fourside" and maxFo >= 60 and f >= 500: break
    if label in ["fo80late", "soft98"] and maxFo >= 80 and f >= 500: break

  echo fmt"FINAL {label} max_tg={maxTg} max_pokey={maxPokey} max_knock={maxKnock} " &
    fmt"max_buzz={maxBuzz} max_sun={maxSun} max_frank={maxFrank} max_cs={maxCs} " &
    fmt"max_fo={maxFo} recoveries={recoveries}"
  echo fmt"DELTA {label} tg {startTg}->{maxTg} pokey {startPokey}->{maxPokey} " &
    fmt"knock {startKnock}->{maxKnock} frank {startFrank}->{maxFrank} " &
    fmt"cs {startCs}->{maxCs} fo {startFo}->{maxFo}"
  dumpScene(snes, "end_" & label)

proc main() =
  ## Multi-leg product path: house exit, outdoor/home, post-knock frank, fo60.
  echo "=== AGENT PRODUCT MULTILEG PROBE ==="
  echo "NOTE: product legs use intent/scene seeds; not trail-only outdoor bodies"
  if fileExists("bin/states/llm/bedroom.state"):
    runLeg("bin/states/llm/bedroom.state", AgentHouseExitPolicy, "house", 6000, 180, false)
  if fileExists("bin/states/llm/pokey_done.state"):
    # Very high stuck threshold: goHome walkTo is slow; recovery undoes knock climb.
    runLeg("bin/states/llm/pokey_done.state", AgentHomePolicy, "home", 10000, 500, false)
  if fileExists("bin/states/llm/onett_start.state"):
    runLeg("bin/states/llm/onett_start.state", AgentOutdoorPolicy, "outdoor", 2500, 90, false)
  # Post-knock outdoor synth (playable after sleep unreproducible)
  let postOutdoor =
    if fileExists("bin/states/llm/post_knock_outdoor.state"):
      "bin/states/llm/post_knock_outdoor.state"
    elif fileExists("bin/states/llm/frank_corridor.state"):
      "bin/states/llm/frank_corridor.state"
    else: ""
  if postOutdoor.len > 0:
    runLeg(postOutdoor, AgentFrankPolicy, "frank", 4000, 100, true)
  if fileExists("bin/states/llm/fourside60_walkable.state"):
    runLeg("bin/states/llm/fourside60_walkable.state", AgentFoursideApproachPolicy,
      "fourside", 3000, 80, false)
  # Past fo60: free+Poo fo80 soft ceiling path
  if fileExists("bin/states/llm/fourside80_walkable.state"):
    runLeg("bin/states/llm/fourside80_walkable.state", AgentLateGamePolicy,
      "fo80late", 3000, 90, false)
  elif fileExists("bin/states/llm/poo_soft98_walkable.state"):
    runLeg("bin/states/llm/poo_soft98_walkable.state", AgentLateGamePolicy,
      "soft98", 3000, 90, false)
  echo "OK probe_agent_product_multileg"

when isMainModule:
  main()
