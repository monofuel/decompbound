## Multileg late-game: grade deep pre-Poo → Poo join → deep Poo; AgentLateGame smoke.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc show(path: string) =
  if not fileExists(path):
    echo "SKIP ", path
    return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"=== {extractFilename(path)} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) ==="
  echo "  ", checkpointSpineLine(snes)
  echo fmt"  DELTA keys fourside={foursidePercent(snes)} magicant={magicantPercent(snes)} giygas={giygasPercent(snes)} poo={partyHasChar(snes, PartyCharPoo)}"

proc runLate(path: string; frames = 4000) =
  if not fileExists(path): return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  writeFile("bin/states/llm/rollback.state", cast[string](serializeState(snes, c)))
  echo "STUCK_ANCHOR: ", path
  let startMa = magicantPercent(snes)
  let startFo = foursidePercent(snes)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentLateGamePolicy, "late")
  var maxMa = startMa
  var maxFo = startFo
  var maxGi = giygasPercent(snes)
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
    let ma = magicantPercent(snes)
    let fo = foursidePercent(snes)
    let gi = giygasPercent(snes)
    if ma > maxMa: maxMa = ma
    if fo > maxFo: maxFo = fo
    if gi > maxGi: maxGi = gi
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if abs(px - prevX) + abs(py - prevY) <= 2:
      stuck.inc
    else:
      stuck = 0
    prevX = px
    prevY = py
    if stuck > 120:
      recoveries.inc
      echo fmt"STUCK_DETECTED; STUCK_RECOVERY rollback recovery#{recoveries}"
      deserializeState(cast[seq[byte]](readFile("bin/states/llm/rollback.state")), snes, c)
      loadChunk(L, AgentLateGamePolicy, "replan")
      stuck = 0
    if f mod 1000 == 0:
      echo fmt"f={f} fo={fo} ma={ma} gi={gi} pos=(0x{px:04X},0x{py:04X})"
  echo fmt"FINAL late max_fo={maxFo} max_ma={maxMa} max_gi={maxGi} recoveries={recoveries}"
  echo fmt"DELTA late fourside {startFo}->{maxFo} magicant {startMa}->{maxMa}"
  echo "  ", checkpointSpineLine(snes)

proc main() =
  echo "=== late-game multileg spine ==="
  show("bin/states/llm/midgame_approach.state")
  show("bin/states/llm/fourside_deep_prepoo.state")
  show("bin/states/llm/poo_joined.state")
  show("bin/states/llm/poo_deep_south.state")
  show("bin/states/llm/poo_very_deep.state")
  show("bin/states/llm/poo_late_map.state")
  show("bin/states/llm/poo_high_bitpop.state")
  show("bin/states/llm/poo_soft98_walkable.state")
  show("bin/states/llm/poo_free_outdoor.state")
  # Prefer soft98 walkable (ma98 peak path); free outdoor holds ma95 band.
  let run =
    if fileExists("bin/states/llm/poo_soft98_walkable.state"):
      "bin/states/llm/poo_soft98_walkable.state"
    elif fileExists("bin/states/llm/poo_free_outdoor.state"):
      "bin/states/llm/poo_free_outdoor.state"
    elif fileExists("bin/states/llm/poo_very_deep.state"):
      "bin/states/llm/poo_very_deep.state"
    elif fileExists("bin/states/llm/poo_joined.state"):
      "bin/states/llm/poo_joined.state"
    else: ""
  if run.len > 0:
    echo "RUN late Agent on ", run
    runLate(run)
  echo "OK probe_late_game_multileg"

when isMainModule:
  main()
