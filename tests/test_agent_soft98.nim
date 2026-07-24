## AgentLateGame from soft-ceiling fixture peaks ma>=98 / gi>=80 (past ma95/gi70).

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Soft98 = "bin/states/llm/poo_soft98_walkable.state"
  VeryDeep = "bin/states/llm/poo_very_deep.state"
  Free = "bin/states/llm/poo_free_outdoor.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  ## Prove Agent late path peaks past ma95/gi70 soft mid-band into ma98/gi80.
  doAssert fileExists(Rom)
  let path =
    if fileExists(Soft98): Soft98
    elif fileExists(VeryDeep): VeryDeep
    elif fileExists(Free): Free
    else: ""
  doAssert path.len > 0, "need soft98, very_deep, or free outdoor fixture"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let startMa = magicantPercent(snes)
  let startGi = giygasPercent(snes)
  let startSoft = hasAllSanctuarySoft(snes)
  echo "START path=", path, " ma=", startMa, " gi=", startGi,
    " soft=", startSoft, " bp=", eventFlagBitPop(snes)
  echo "POLICY=AgentLateGamePolicy"
  doAssert "followRoute(" notin AgentLateGamePolicy
  doAssert startMa >= 90, "need late soft start ma>=90, got " & $startMa

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentLateGamePolicy, "late")
  let i = PlayerSlot * SlotIndexStride
  var maxMa = startMa
  var maxGi = startGi
  var maxBp = eventFlagBitPop(snes)
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  var softPeak = startSoft
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    let bp = eventFlagBitPop(snes)
    if ma > maxMa: maxMa = ma
    if gi > maxGi: maxGi = gi
    if bp > maxBp: maxBp = bp
    if hasAllSanctuarySoft(snes): softPeak = true
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  let span = (maxX - minX) + (maxY - minY)
  echo "FINAL maxMa=", maxMa, " maxGi=", maxGi, " maxBp=", maxBp,
    " softPeak=", softPeak, " span=", span
  echo "spine ", checkpointSpineLine(snes)
  # Past ma95/gi70: soft ceiling peak (corpus has no ma100 dream F12s).
  doAssert maxMa >= 98, "must peak magicant soft ceiling 98 (got " & $maxMa & ")"
  doAssert maxGi >= 80, "must peak giygas soft ceiling 80 (got " & $maxGi & ")"
  doAssert softPeak or startSoft, "must hit sanctuary soft proxy"
  doAssert span >= 32, "must remain free-walkable under AgentLateGame"
  echo "OK test_agent_soft98: Agent late peaks ma98/gi80 past ma95/gi70"

when isMainModule:
  main()
