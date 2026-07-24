## Gap past fourside 60: free-flag combos with Poo party / deep pos for fo80+ walkability.
## fo80 is partyHasChar(Poo), not py alone — RE which flag/party blends stay free.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Free = "bin/states/slot4.state"
  Mid = "bin/states/llm/midgame_approach.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"
  PooJoined = "bin/states/llm/poo_joined.state"
  PooDeep = "bin/states/llm/poo_deep_south.state"
  PooVery = "bin/states/llm/poo_very_deep.state"
  FreeOut = "bin/states/llm/poo_free_outdoor.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc loadPath(path: string): tuple[snes: SnesBus, c: Cpu] =
  ## Fresh SNES + deserialize path.
  result.snes = newSnesBus(policy.readRomFile(Rom))
  result.c = result.snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), result.snes, result.c)

proc copyPos(dst, src: SnesBus) =
  ## Copy player world X/Y from src to dst.
  let i = PlayerSlot * SlotIndexStride
  let x = readU16(src, WorldXBase + i)
  let y = readU16(src, WorldYBase + i)
  dst.bus.mem[0x7E0000 + WorldXBase + i] = uint8(x and 0xFF)
  dst.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8((x shr 8) and 0xFF)
  dst.bus.mem[0x7E0000 + WorldYBase + i] = uint8(y and 0xFF)
  dst.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8((y shr 8) and 0xFF)

proc copyPartyIds(dst, src: SnesBus) =
  ## Copy battle-party identity slots $988B..$988E + size mirrors.
  for off in [PartySlot0, PartySlot1, PartySlot2, PartySlot3,
              PartySizeOffA, PartySizeOffB]:
    dst.bus.mem[0x7E0000 + off] = readU8(src, off).uint8

proc copyEventBlock(dst, src: SnesBus; lo, hi: int) =
  ## Copy a WRAM byte range (story/event window experiments).
  for off in lo .. hi:
    dst.bus.mem[0x7E0000 + off] = readU8(src, off).uint8

proc walkSpan(snes: SnesBus; c: var Cpu; frames: int): tuple[span, maxFo, maxMa: int] =
  ## South-biased free walk; return span + peak fo/ma.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  pad.press("Down")
  local f = frame() % 50
  if f < 15 then pad.press("Right")
  elseif f < 30 then pad.press("Left") end
end
""", "walk")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  var maxFo = foursidePercent(snes)
  var maxMa = magicantPercent(snes)
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
    let fo = foursidePercent(snes)
    let ma = magicantPercent(snes)
    if fo > maxFo: maxFo = fo
    if ma > maxMa: maxMa = ma
  result = ((maxX - minX) + (maxY - minY), maxFo, maxMa)

proc report(label: string; snes: SnesBus; span, maxFo, maxMa: int) =
  ## One-line grade after a walk trial.
  let i = PlayerSlot * SlotIndexStride
  echo fmt"{label}: start_fo={foursidePercent(snes)} start_ma={magicantPercent(snes)} " &
    fmt"poo={partyHasChar(snes, PartyCharPoo)} lv={partyLeaderLevel(snes)} " &
    fmt"span={span} maxFo={maxFo} maxMa={maxMa} " &
    fmt"end_pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"end_fo={foursidePercent(snes)} soft={hasAllSanctuarySoft(snes)}"

proc trial(label, basePath, posPath, partyPath: string; frames = 2500;
           copyEvents = false): bool =
  ## Build blend, walk, report. Returns true if walkable and maxFo>=80.
  if not fileExists(basePath):
    echo "SKIP ", label, " missing base ", basePath
    return false
  var (snes, c) = loadPath(basePath)
  if posPath.len > 0 and fileExists(posPath):
    let (src, _) = loadPath(posPath)
    copyPos(snes, src)
  if partyPath.len > 0 and fileExists(partyPath):
    let (src, _) = loadPath(partyPath)
    copyPartyIds(snes, src)
    if copyEvents:
      # Late story block only — avoid full overlay warp (post_knock lesson).
      copyEventBlock(snes, src, 0x9880, 0x98B8)
  let fo0 = foursidePercent(snes)
  let ma0 = magicantPercent(snes)
  echo fmt"TRIAL {label} fo0={fo0} ma0={ma0} poo={partyHasChar(snes, PartyCharPoo)}"
  # Snapshot before walk for fixture write if green.
  let initial = serializeState(snes, c)
  let w = walkSpan(snes, c, frames)
  # Re-grade from walked bus for end; report peaks from walk.
  report(label, snes, w.span, w.maxFo, w.maxMa)
  if w.span >= 64 and w.maxFo >= 80:
    let outp = "bin/states/llm/fourside80_walkable.state"
    # Prefer initial if it already grades fo80 (party poke); else walked if still 80.
    var blob = initial
    var (s2, c2) = loadPath(basePath)  # dummy
    deserializeState(initial, s2, c2)
    if foursidePercent(s2) >= 80:
      writeFile(outp, cast[string](initial))
      echo "WROTE ", outp, " (initial blend) fo=", foursidePercent(s2)
    elif foursidePercent(snes) >= 80:
      writeFile(outp, cast[string](serializeState(snes, c)))
      echo "WROTE ", outp, " (post-walk) fo=", foursidePercent(snes)
    else:
      writeFile(outp, cast[string](initial))
      echo "WROTE ", outp, " (initial; peak fo=", w.maxFo, ")"
    return true
  false

proc main() =
  ## Enumerate free/mid + Poo blends for walkable fo80+.
  doAssert fileExists(Rom)
  echo "=== BASELINE FIXTURES (static) ==="
  for p in [Free, Mid, Fo60, PooJoined, PooDeep, PooVery, FreeOut]:
    if not fileExists(p): continue
    let (s, _) = loadPath(p)
    let i = PlayerSlot * SlotIndexStride
    echo fmt"  {extractFilename(p)} fo={foursidePercent(s)} ma={magicantPercent(s)} " &
      fmt"poo={partyHasChar(s, PartyCharPoo)} lv={partyLeaderLevel(s)} " &
      fmt"pos=(0x{readU16(s,WorldXBase+i):04X},0x{readU16(s,WorldYBase+i):04X})"

  echo "=== WALK TRIALS ==="
  # A) free flags + poo_joined party only (mid/free pos)
  discard trial("free+poo_party", Free, "", PooJoined)
  # B) free flags + poo_joined pos + party
  discard trial("free+poo_pos+party", Free, PooJoined, PooJoined)
  # C) free flags + poo_deep pos + party
  discard trial("free+poodeep_pos+party", Free, PooDeep, PooJoined)
  # D) free flags + very_deep pos + party
  discard trial("free+very_pos+party", Free, PooVery, PooJoined)
  # E) free flags + free_outdoor pos (already soft98 path) + party if missing
  discard trial("free+freeout_pos+party", Free, FreeOut, PooJoined)
  # F) fo60 walkable + party poke only
  if fileExists(Fo60):
    discard trial("fo60+poo_party", Fo60, "", PooJoined)
  # G) mid flags + poo party (control-lock check)
  discard trial("mid+poo_party", Mid, "", PooJoined)
  # H) free + party + partial event copy from poo_joined
  discard trial("free+party+events9880", Free, PooJoined, PooJoined, 2500, true)
  # I) pure poo_joined / free outdoor walk baselines
  if fileExists(PooJoined):
    var (s, c) = loadPath(PooJoined)
    let w = walkSpan(s, c, 2000)
    report("baseline_poo_joined", s, w.span, w.maxFo, w.maxMa)
  if fileExists(FreeOut):
    var (s, c) = loadPath(FreeOut)
    let w = walkSpan(s, c, 2000)
    report("baseline_poo_free_outdoor", s, w.span, w.maxFo, w.maxMa)
  if fileExists(PooVery):
    var (s, c) = loadPath(PooVery)
    let w = walkSpan(s, c, 2000)
    report("baseline_poo_very_deep", s, w.span, w.maxFo, w.maxMa)
  echo "OK probe_past_fo60"

when isMainModule:
  main()
