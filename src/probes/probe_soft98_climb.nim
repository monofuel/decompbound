## d69: climb from fo80_from_paula toward soft98 (ma98/gi80).
## Tries freewalk bitpop climb, flag overlays from soft98, hold AgentLate.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fo80Paula = "bin/states/llm/fourside80_from_paula.state"
  Soft98 = "bin/states/llm/poo_soft98_walkable.state"
  FreeOut = "bin/states/llm/poo_free_outdoor.state"
  HighBp = "bin/states/llm/poo_high_bitpop.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc dump(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"GRADE {tag} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"fo={foursidePercent(snes)} ma={magicantPercent(snes)} gi={giygasPercent(snes)} " &
    fmt"soft={hasAllSanctuarySoft(snes)} lv={partyLeaderLevel(snes)} bp={eventFlagBitPop(snes)} " &
    fmt"dream={hasMagicantDreamFlag(snes)}"

proc runLate(snes: SnesBus; c: var Cpu; frames: int; label: string):
    tuple[maxMa, maxGi, maxBp, span: int] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" & AdvanceDialogueSkillLua, "sk")
  loadChunk(L, AgentLateGamePolicy, label)
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  result.maxMa = magicantPercent(snes)
  result.maxGi = giygasPercent(snes)
  result.maxBp = eventFlagBitPop(snes)
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
    let bp = eventFlagBitPop(snes)
    if ma > result.maxMa: result.maxMa = ma
    if gi > result.maxGi: result.maxGi = gi
    if bp > result.maxBp: result.maxBp = bp
  result.span = (maxX - minX) + (maxY - minY)
  echo fmt"LATE {label} maxMa={result.maxMa} maxGi={result.maxGi} maxBp={result.maxBp} span={result.span} " &
    fmt"end_ma={magicantPercent(snes)} soft={hasAllSanctuarySoft(snes)}"

proc load(path: string): tuple[snes: SnesBus, c: Cpu] =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  (snes, c)

proc main() =
  echo "=== d69 soft98 climb probe ==="
  doAssert fileExists(Rom)

  # A) fo80_from_paula freewalk — can bitpop climb to soft98?
  if fileExists(Fo80Paula):
    var (snes, c) = load(Fo80Paula)
    dump(snes, "A_fo80paula_start")
    discard runLate(snes, c, 8000, "A_late_climb")
    dump(snes, "A_end")

  # B) soft98 hold baseline
  if fileExists(Soft98):
    var (snes, c) = load(Soft98)
    dump(snes, "B_soft98_start")
    discard runLate(snes, c, 4000, "B_soft98_hold")
    dump(snes, "B_end")

  # C) fo80paula + soft98 event flags 0x9A00..0x9BFF (keep free control / party)
  if fileExists(Fo80Paula) and fileExists(Soft98):
    var (snes, c) = load(Fo80Paula)
    let (soft, _) = load(Soft98)
    for off in 0x9A00 .. 0x9BFF:
      snes.bus.mem[0x7E0000 + off] = soft.bus.mem[0x7E0000 + off]
    dump(snes, "C_fo80+soft98_9A00")
    let r = runLate(snes, c, 4000, "C_late")
    if r.maxMa >= 98 and r.span > 32:
      # write initial (pre-walk)
      var (s2, c2) = load(Fo80Paula)
      for off in 0x9A00 .. 0x9BFF:
        s2.bus.mem[0x7E0000 + off] = soft.bus.mem[0x7E0000 + off]
      writeFile("bin/states/llm/soft98_from_fo80paula.state", cast[string](serializeState(s2, c2)))
      echo "WROTE soft98_from_fo80paula initial ma=", magicantPercent(s2),
        " soft=", hasAllSanctuarySoft(s2), " bp=", eventFlagBitPop(s2)

  # D) fo80paula + high bitpop full 9880..9BFF except party
  if fileExists(Fo80Paula) and fileExists(HighBp):
    var (snes, c) = load(Fo80Paula)
    let (hi, _) = load(HighBp)
    for off in 0x9880 .. 0x9BFF:
      if off >= 0x988B and off <= 0x988E: continue
      if off == PartyLeaderLevelOff: continue
      snes.bus.mem[0x7E0000 + off] = hi.bus.mem[0x7E0000 + off]
    dump(snes, "D_fo80+highbp")
    discard runLate(snes, c, 3000, "D_late")

  # E) free outdoor soft98 path
  if fileExists(FreeOut):
    var (snes, c) = load(FreeOut)
    dump(snes, "E_freeout")
    discard runLate(snes, c, 3000, "E_late")

  # F) fo80paula + soft98 full except party/level — wider flag overlay
  if fileExists(Fo80Paula) and fileExists(Soft98):
    var (snes, c) = load(Fo80Paula)
    let (soft, _) = load(Soft98)
    for off in 0x9880 .. 0x9BFF:
      if off >= 0x988B and off <= 0x988E: continue
      if off == PartyLeaderLevelOff: continue
      if off == PartySizeOffA or off == PartySizeOffB: continue
      snes.bus.mem[0x7E0000 + off] = soft.bus.mem[0x7E0000 + off]
    dump(snes, "F_fo80+soft98_wide")
    let r = runLate(snes, c, 3000, "F_late")
    if hasAllSanctuarySoft(snes) and r.span > 32:
      var (s2, c2) = load(Fo80Paula)
      for off in 0x9880 .. 0x9BFF:
        if off >= 0x988B and off <= 0x988E: continue
        if off == PartyLeaderLevelOff: continue
        if off == PartySizeOffA or off == PartySizeOffB: continue
        s2.bus.mem[0x7E0000 + off] = soft.bus.mem[0x7E0000 + off]
      if hasAllSanctuarySoft(s2):
        writeFile("bin/states/llm/soft98_from_fo80paula.state", cast[string](serializeState(s2, c2)))
        echo "WROTE soft98_from_fo80paula wide ma=", magicantPercent(s2),
          " bp=", eventFlagBitPop(s2)

  echo "OK probe_soft98_climb"

when isMainModule: main()
