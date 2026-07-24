## RE late-game progress markers: party size, candidate Ness level, free-walk diffs.
import
  std/[os, strformat, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc snapFlags(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in 0x9880 .. 0x9BFF:
    result[off] = readU8(snes, off)

proc dumpMarkers(path: string) =
  if not fileExists(path): return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  let i = PlayerSlot * SlotIndexStride
  # Candidate party-size bytes (observed 03 mid / 04 Poo / 01 solo).
  let partySizeA = readU8(snes, 0x98A3)
  let partySizeB = readU8(snes, 0x98A4)
  # Candidate Ness level at $98B8 (observed 4 mid / 7 Poo-join / 16 deep).
  let candLevel = readU8(snes, 0x98B8)
  # Candidate max HP LE at $98B2 (grows with late fixtures).
  let candHp = readU16(snes, 0x98B2)
  echo fmt"{extractFilename(path)}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X},{readU8(snes,0x988D):02X},{readU8(snes,0x988E):02X} " &
    fmt"$98A3={partySizeA:02X} $98A4={partySizeB:02X} $9881={readU8(snes,0x9881):02X} " &
    fmt"candLv=$98B8={candLevel} candHp=$98B2=0x{candHp:04X} money={readU16(snes,0x9831)} " &
    fmt"ma={magicantPercent(snes)} gi={giygasPercent(snes)}"

proc walkDiff(path: string; frames = 5000) =
  if not fileExists(path): return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  let before = snapFlags(snes)
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
  var maxMa = magicantPercent(snes)
  var maxGi = giygasPercent(snes)
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
    if ma > maxMa: maxMa = ma
    if gi > maxGi: maxGi = gi
  let after = snapFlags(snes)
  var n = 0
  echo fmt"WALK {extractFilename(path)} bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X} maxMa={maxMa} maxGi={maxGi}"
  for off, va in before:
    let vb = after.getOrDefault(off, va)
    if va != vb:
      if n < 25:
        echo fmt"  walkdiff ${off:04X}: 0x{va:02X}->0x{vb:02X}"
      n.inc
  echo "  walk_flagdiffs=", n
  if maxY > 0x25A0 or maxX != minX:
    writeFile("bin/states/llm/poo_endgame_walk.state", cast[string](serializeState(snes, c)))
    echo "  WROTE poo_endgame_walk"

proc main() =
  echo "=== MARKERS ==="
  for p in [
    "bin/states/llm/midgame_approach.state",
    "bin/states/llm/fourside_deep_prepoo.state",
    "bin/states/llm/poo_joined.state",
    "bin/states/llm/poo_deep_south.state",
    "bin/states/llm/poo_very_deep.state",
    "bin/states/llm/poo_free_outdoor.state",
    "bin/states/llm/poo_solo.state",
    "bin/states/battle_menu_healthy.state"
  ]:
    dumpMarkers(p)
  echo "=== FREE WALK FLAGDIFF ==="
  walkDiff("bin/states/llm/poo_free_outdoor.state", 6000)
  walkDiff("bin/states/llm/poo_joined.state", 3000)

when isMainModule:
  main()
