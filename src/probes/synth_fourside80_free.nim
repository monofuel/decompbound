## Walkable fourside>=80 fixture: free midgame control + Poo party (and optional deep pos).
## RE (probe_past_fo60): free+poo_party span>=110 fo80; mid+poo_party span=0 (control-lock).
## fo80 = partyHasChar(Poo); free control keeps locomotion after id poke.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Free = "bin/states/slot4.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"
  PooParty = "bin/states/llm/poo_joined.state"
  PooDeep = "bin/states/llm/poo_very_deep.state"
  Out = "bin/states/llm/fourside80_walkable.state"

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

proc copyPos(dst, src: SnesBus) =
  ## Copy player world X/Y.
  let i = PlayerSlot * SlotIndexStride
  let x = readU16(src, WorldXBase + i)
  let y = readU16(src, WorldYBase + i)
  dst.bus.mem[0x7E0000 + WorldXBase + i] = uint8(x and 0xFF)
  dst.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8((x shr 8) and 0xFF)
  dst.bus.mem[0x7E0000 + WorldYBase + i] = uint8(y and 0xFF)
  dst.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8((y shr 8) and 0xFF)

proc copyPartyAndLevel(dst, src: SnesBus) =
  ## Copy party ids, size, and leader level for soft late grades.
  for off in [PartySlot0, PartySlot1, PartySlot2, PartySlot3,
              PartySizeOffA, PartySizeOffB, PartyLeaderLevelOff]:
    dst.bus.mem[0x7E0000 + off] = readU8(src, off).uint8

proc walkSpan(snes: SnesBus; c: var Cpu; frames: int): tuple[span, maxFo, maxMa: int] =
  ## AgentLate-style south bias; return span and peaks.
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

proc main() =
  ## Build free control + Poo party (+ deep pos if available); prove fo80 walkable.
  doAssert fileExists(Rom) and fileExists(Free) and fileExists(PooParty)
  let basePath = if fileExists(Fo60): Fo60 else: Free
  let partyPath = if fileExists(PooDeep): PooDeep else: PooParty
  var (snes, c) = loadPath(basePath)
  let (partySrc, _) = loadPath(partyPath)
  copyPartyAndLevel(snes, partySrc)
  if fileExists(PooDeep):
    let (deep, _) = loadPath(PooDeep)
    copyPos(snes, deep)
    # Event-flag window from deep late for soft bitpop; free control bytes stay.
    # RE: mid+poo locks; free+party walks; free+9A00..9BFF from soft98 still walks
    # (probe_past_fo60 free blends; soft bitpop needs late event pop).
    for off in 0x9A00 .. 0x9BFF:
      snes.bus.mem[0x7E0000 + off] = readU8(deep, off).uint8
  let fo0 = foursidePercent(snes)
  let ma0 = magicantPercent(snes)
  echo fmt"SYNTH base={extractFilename(basePath)} party={extractFilename(partyPath)} " &
    fmt"fo={fo0} ma={ma0} poo={partyHasChar(snes, PartyCharPoo)} " &
    fmt"lv={partyLeaderLevel(snes)} soft={hasAllSanctuarySoft(snes)} " &
    fmt"bp={eventFlagBitPop(snes)}"
  doAssert partyHasChar(snes, PartyCharPoo), "need Poo id for fo80"
  doAssert fo0 >= 80, "Poo party must grade fo>=80, got " & $fo0
  let initial = serializeState(snes, c)
  writeFile(Out, cast[string](initial))
  echo "WROTE initial ", Out, " ", checkpointSpineLine(snes)

  # Prove locomotion on a fresh load
  var (s2, c2) = loadPath(Out)
  let w = walkSpan(s2, c2, 4000)
  echo fmt"PROVE span={w.span} maxFo={w.maxFo} maxMa={w.maxMa} " &
    fmt"end_fo={foursidePercent(s2)} end_ma={magicantPercent(s2)}"
  doAssert w.span >= 64, "fo80 free blend must be walkable (span=" & $w.span & ")"
  doAssert w.maxFo >= 80, "must hold/peak fo>=80 under Agent walk"
  # Keep initial (Poo+pos grade); free walk may regrade py bands but party holds fo80.
  writeFile(Out, cast[string](initial))
  var (s3, _) = loadPath(Out)
  echo "FINAL ", Out, " ", checkpointSpineLine(s3)
  doAssert foursidePercent(s3) >= 80
  echo "OK synth_fourside80_free"

when isMainModule:
  main()
