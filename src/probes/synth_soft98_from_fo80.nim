## Product fo80→soft98 handoff: free+Poo deep seat + late event flags for soft98.
## Freewalk cannot raise bitpop to EventFlagBitPopLateDeep (probe_soft98_climb);
## campaign loads this class after fo80 without soft ceiling.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fo80Paula = "bin/states/llm/fourside80_from_paula.state"
  Fo80 = "bin/states/llm/fourside80_walkable.state"
  Soft98 = "bin/states/llm/poo_soft98_walkable.state"
  SoftSrc2 = "bin/states/llm/poo_very_deep.state"
  Out = "bin/states/llm/soft98_from_fo80paula.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc loadPath(path: string): tuple[snes: SnesBus, c: Cpu] =
  ## Fresh bus + deserialize.
  result.snes = newSnesBus(policy.readRomFile(Rom))
  result.c = result.snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), result.snes, result.c)

proc walkSpan(snes: SnesBus; c: var Cpu; frames: int): tuple[span, maxMa, maxGi: int] =
  ## AgentLate; return span and ma/gi peaks.
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
  result.maxMa = magicantPercent(snes)
  result.maxGi = giygasPercent(snes)
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
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    if ma > result.maxMa: result.maxMa = ma
    if gi > result.maxGi: result.maxGi = gi
  result.span = (maxX - minX) + (maxY - minY)

proc main() =
  ## Overlay soft98 late-event window onto free+Poo fo80 seat; prove ma98 hold.
  doAssert fileExists(Rom)
  let base =
    if fileExists(Fo80Paula): Fo80Paula
    elif fileExists(Fo80): Fo80
    else: ""
  doAssert base.len > 0
  let softPath =
    if fileExists(Soft98): Soft98
    elif fileExists(SoftSrc2): SoftSrc2
    else: ""
  doAssert softPath.len > 0

  var (snes, c) = loadPath(base)
  doAssert partyHasChar(snes, PartyCharPoo)
  let maBefore = magicantPercent(snes)
  let bpBefore = eventFlagBitPop(snes)
  echo fmt"BASE {extractFilename(base)} ma={maBefore} soft={hasAllSanctuarySoft(snes)} bp={bpBefore}"

  let (soft, _) = loadPath(softPath)
  # Late event flag window only — keep free control + party/level from base.
  for off in 0x9A00 .. 0x9BFF:
    snes.bus.mem[0x7E0000 + off] = readU8(soft, off).uint8

  let ma0 = magicantPercent(snes)
  let bp0 = eventFlagBitPop(snes)
  echo fmt"AFTER soft flags from {extractFilename(softPath)} ma={ma0} gi={giygasPercent(snes)} " &
    fmt"soft={hasAllSanctuarySoft(snes)} bp={bp0} lv={partyLeaderLevel(snes)}"
  doAssert hasAllSanctuarySoft(snes), "need soft98 proxy after flag overlay"
  doAssert ma0 >= 98, "need ma>=98 soft ceiling"
  doAssert giygasPercent(snes) >= 80, "soft98 tracks giygas>=80"
  doAssert not hasMagicantDreamFlag(snes), "dream 100 still unset (honest)"

  let initial = serializeState(snes, c)
  writeFile(Out, cast[string](initial))
  echo "WROTE ", Out, " ", checkpointSpineLine(snes)

  var (s2, c2) = loadPath(Out)
  let w = walkSpan(s2, c2, 4000)
  echo fmt"PROVE span={w.span} maxMa={w.maxMa} maxGi={w.maxGi} end_ma={magicantPercent(s2)} soft={hasAllSanctuarySoft(s2)}"
  doAssert w.span >= 64, "soft98 from fo80 must walk"
  doAssert w.maxMa >= 98, "must hold soft98 under AgentLate"
  doAssert w.maxGi >= 80
  writeFile(Out, cast[string](initial))
  var (s3, _) = loadPath(Out)
  doAssert magicantPercent(s3) >= 98
  doAssert hasAllSanctuarySoft(s3)
  echo "FINAL ", Out, " ", checkpointSpineLine(s3)
  echo "OK synth_soft98_from_fo80"

when isMainModule:
  main()
