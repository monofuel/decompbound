## Full-spine campaign debug: early Agent multileg + late AgentLateGame.
## Captures metric deltas, stuck recovery, bitpop, and spine for SCRATCH.

import
  std/[os, strformat, strutils, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
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

proc snapFlags(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in 0x9880 .. 0x9BFF:
    result[off] = readU8(snes, off)

proc runLeg(path, pol, label: string; frames, stuckThr: int) =
  if not fileExists(path):
    echo "SKIP leg=", label, " path=", path
    return
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  # Post-knock outdoor ladders only — do not poke bedroom (breaks exitHouse).
  if label in ["captain", "giant", "frank"]:
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  writeFile(Rollback, cast[string](serializeState(snes, c)))
  echo fmt"STUCK_ANCHOR: armed {Rollback} for {label} from {path}"

  let startTg = touchGrassPercent(snes)
  let startKnock = pokeyKnockPercent(snes)
  let startMa = magicantPercent(snes)
  let startGi = giygasPercent(snes)
  let startBp = eventFlagBitPop(snes)
  let startFo = foursidePercent(snes)
  let startCs = captainStrongPercent(snes)
  echo fmt"START {label} tg={startTg} knock={startKnock} cs={startCs} fo={startFo} ma={startMa} gi={startGi} bitpop={startBp}"
  echo "POLICY=", label, " body_len=", pol.len
  doAssert "followRoute(" notin pol or label in ["giant", "captain", "frank"],
    "Agent product legs must not be trail-only outdoor bodies"

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
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, pol, label)

  var maxTg = startTg
  var maxKnock = startKnock
  var maxMa = startMa
  var maxGi = startGi
  var maxBp = startBp
  var maxFo = startFo
  var maxCs = startCs
  var stuck = 0
  var recoveries = 0
  let i = PlayerSlot * SlotIndexStride
  var prevX = readU16(snes, WorldXBase + i)
  var prevY = readU16(snes, WorldYBase + i)
  let before = snapFlags(snes)

  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if label in ["captain", "giant", "frank"]:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8

    let tg = touchGrassPercent(snes)
    let kn = pokeyKnockPercent(snes)
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    let bp = eventFlagBitPop(snes)
    let fo = foursidePercent(snes)
    let cs = captainStrongPercent(snes)
    if tg > maxTg: maxTg = tg
    if kn > maxKnock: maxKnock = kn
    if ma > maxMa: maxMa = ma
    if gi > maxGi: maxGi = gi
    if bp > maxBp: maxBp = bp
    if fo > maxFo: maxFo = fo
    if cs > maxCs: maxCs = cs

    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let posDelta = abs(px - prevX) + abs(py - prevY)
    let metricProg = tg > startTg or kn > startKnock or ma > startMa or cs > startCs
    # Indoor exit moves slowly (walkTo steps); only treat near-zero delta as stall.
    if posDelta <= 1 and not metricProg:
      stuck.inc
    else:
      stuck = 0
      # Forward milestone when metrics climb so recovery does not undo wins.
      if metricProg:
        writeFile(Rollback, cast[string](serializeState(snes, c)))
    prevX = px
    prevY = py

    if stuck > stuckThr:
      recoveries.inc
      echo fmt"STUCK_DETECTED (counter={stuck}); STUCK_RECOVERY rollback -> {Rollback} recovery#{recoveries}"
      deserializeState(cast[seq[byte]](readFile(Rollback)), snes, c)
      if label in ["captain", "giant", "frank"]:
        snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      loadChunk(L, pol, "post_stuck_replan")
      echo fmt"STUCK_RECOVERY: policy reloaded {label}"
      stuck = 0
      prevX = readU16(snes, WorldXBase + i)
      prevY = readU16(snes, WorldYBase + i)

    if f mod 2000 == 0:
      echo fmt"f={f} tg={tg} kn={kn} cs={cs} fo={fo} ma={ma} gi={gi} bp={bp} pos=(0x{px:04X},0x{py:04X}) stuck={stuck}"

    # Early exit when leg goal met
    if label == "house" and maxTg >= 100: break
    if label == "outdoor" and maxKnock >= 30: break
    if label == "captain" and maxCs >= 50: break
    if label == "late" and maxMa >= 98 and recoveries >= 0: break

  let after = snapFlags(snes)
  var nDiff = 0
  for off, va in before:
    let vb = after.getOrDefault(off, va)
    if va != vb:
      if nDiff < 12:
        echo fmt"  flagdiff ${off:04X}: 0x{va:02X}->0x{vb:02X}"
      nDiff.inc
  echo fmt"FINAL {label} max_tg={maxTg} max_knock={maxKnock} max_cs={maxCs} max_fo={maxFo} max_ma={maxMa} max_gi={maxGi} max_bp={maxBp} recoveries={recoveries} flagdiffs={nDiff}"
  echo fmt"DELTA {label} tg {startTg}->{maxTg} knock {startKnock}->{maxKnock} cs {startCs}->{maxCs} ma {startMa}->{maxMa} gi {startGi}->{maxGi} bp {startBp}->{maxBp}"
  echo "  ", checkpointSpineLine(snes)
  if maxMa >= 95 or maxCs >= 50:
    writeFile("bin/states/llm/campaign_" & label & "_best.state",
      cast[string](serializeState(snes, c)))
    echo "WROTE campaign_", label, "_best"

proc main() =
  echo "=== FULL SPINE CAMPAIGN PROBE ==="
  # Leg A: house exit (Agent product, no trail body)
  if fileExists("bin/states/llm/bedroom.state"):
    # Higher stuck threshold: exitHouse walkTo is slow but not stalled.
    runLeg("bin/states/llm/bedroom.state", AgentHouseExitPolicy, "house", 8000, 200)
  # Leg B: outdoor pokey / early (if outdoor seed exists)
  if fileExists("bin/states/llm/onett_start.state"):
    runLeg("bin/states/llm/onett_start.state", AgentOutdoorPolicy, "outdoor", 3000, 80)
  # Leg C: captain from giant
  if fileExists("bin/states/llm/giant_approach.state"):
    runLeg("bin/states/llm/giant_approach.state", AgentCaptainStrongPolicy, "captain", 6000, 100)
  # Leg D: late game from poo_very_deep
  let latePath =
    if fileExists("bin/states/llm/poo_very_deep.state"):
      "bin/states/llm/poo_very_deep.state"
    elif fileExists("bin/states/llm/poo_free_outdoor.state"):
      "bin/states/llm/poo_free_outdoor.state"
    else: ""
  if latePath.len > 0:
    runLeg(latePath, AgentLateGamePolicy, "late", 8000, 90)
  # Flag RE: static grade late fixtures
  echo "=== LATE FIXTURE STATIC GRADES ==="
  for p in ["bin/states/llm/poo_joined.state", "bin/states/llm/poo_deep_south.state",
            "bin/states/llm/poo_very_deep.state", "bin/states/llm/poo_free_outdoor.state",
            "bin/states/llm/midgame_approach.state"]:
    if not fileExists(p): continue
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(p)), snes, c)
    echo extractFilename(p), " ", checkpointSpineLine(snes),
      " dream=", hasMagicantDreamFlag(snes), " giygasFlag=", hasGiygasPhaseFlag(snes),
      " sanctuarySoft=", hasAllSanctuarySoft(snes)
  echo "OK probe_campaign_full_spine"

when isMainModule:
  main()
