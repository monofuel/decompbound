## Capture walkable soft Magicant ceiling (ma98/gi80): free-walk from poo_very_deep.
## RE: full F12 corpus max ma=98 (no dream F12); free Agent walk peaks ma98/bp606.
## Writes bin/states/llm/poo_soft98_walkable.state when soft+span proven.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Src = "bin/states/llm/poo_very_deep.state"
  Out = "bin/states/llm/poo_soft98_walkable.state"
  Rollback = "bin/states/llm/rollback.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc proveWalkable(blob: seq[byte]; frames = 2000): int =
  ## Reload blob and wander; return position span.
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(blob, snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentLateGamePolicy, "late")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  result = (maxX - minX) + (maxY - minY)
  echo fmt"prove span={result} end_ma={magicantPercent(snes)} soft={hasAllSanctuarySoft(snes)}"

proc main() =
  ## Walk from very_deep; keep best soft ma98 snapshot; prove free walk.
  doAssert fileExists(Rom) and fileExists(Src)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Src)), snes, c)
  echo "START ", checkpointSpineLine(snes),
    " soft=", hasAllSanctuarySoft(snes), " bp=", eventFlagBitPop(snes)
  doAssert magicantPercent(snes) >= 95, "need deep late start"
  # very_deep grades soft98 at load — snapshot immediately before free walk drops bp.
  var best = serializeState(snes, c)
  var bestBp = eventFlagBitPop(snes)
  var bestSoft = hasAllSanctuarySoft(snes)
  writeFile(Rollback, cast[string](best))
  writeFile(Out, cast[string](best))
  echo "WROTE initial soft snapshot fo=", foursidePercent(snes),
    " ma=", magicantPercent(snes), " bp=", bestBp

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentLateGamePolicy, "late")
  let i = PlayerSlot * SlotIndexStride
  var maxMa = magicantPercent(snes)
  var maxGi = giygasPercent(snes)
  var maxBp = bestBp
  var softHits = 0
  var stuck = 0
  var prevX = readU16(snes, WorldXBase + i)
  var prevY = readU16(snes, WorldYBase + i)
  for f in 1 .. 10000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    let bp = eventFlagBitPop(snes)
    let soft = hasAllSanctuarySoft(snes)
    if ma > maxMa: maxMa = ma
    if gi > maxGi: maxGi = gi
    if bp > maxBp: maxBp = bp
    if soft:
      softHits.inc
      if ma >= 98 and bp >= bestBp:
        best = serializeState(snes, c)
        bestBp = bp
        bestSoft = true
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if abs(px - prevX) + abs(py - prevY) <= 2:
      stuck.inc
    else:
      stuck = 0
    prevX = px
    prevY = py
    if stuck > 120:
      deserializeState(cast[seq[byte]](readFile(Rollback)), snes, c)
      loadChunk(L, AgentLateGamePolicy, "replan")
      stuck = 0
    if f mod 2500 == 0:
      echo fmt"f={f} ma={ma} gi={gi} bp={bp} soft={soft} softHits={softHits} " &
        fmt"pos=(0x{px:04X},0x{py:04X})"

  echo fmt"WALK peak maxMa={maxMa} maxGi={maxGi} maxBp={maxBp} softHits={softHits}"
  doAssert maxMa >= 98, "Agent free walk must peak soft ma98 (got max " & $maxMa & ")"
  doAssert maxGi >= 80, "Agent free walk must peak soft gi80"
  doAssert bestSoft, "need a soft ma98 snapshot"

  writeFile(Out, cast[string](best))
  let snes2 = newSnesBus(policy.readRomFile(Rom))
  var c2 = snes2.resetCpu()
  deserializeState(best, snes2, c2)
  echo "WROTE ", Out, " ", checkpointSpineLine(snes2),
    " soft=", hasAllSanctuarySoft(snes2), " bp=", eventFlagBitPop(snes2)
  doAssert magicantPercent(snes2) >= 98
  doAssert giygasPercent(snes2) >= 80
  let span = proveWalkable(best, 2500)
  doAssert span >= 32, "soft98 fixture must be walkable (span=" & $span & ")"
  echo "OK synth_ma98_walkable span=", span

when isMainModule:
  main()
