## Product fo60→fo80 handoff: free+Paula deep seat + Poo party ids.
## fo80 = partyHasChar(Poo) (story_percents). Free control keeps locomotion
## (probe_d68 / probe_past_fo60). Bot cannot join Poo via freewalk story.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fo60Paula = "bin/states/llm/fourside60_from_paula.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"
  PooJoined = "bin/states/llm/poo_joined.state"
  PooDeep = "bin/states/llm/poo_very_deep.state"
  Out = "bin/states/llm/fourside80_from_paula.state"

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

proc copyPartyAndLevel(dst, src: SnesBus) =
  ## Copy party ids, size, and leader level.
  for off in [PartySlot0, PartySlot1, PartySlot2, PartySlot3,
              PartySizeOffA, PartySizeOffB, PartyLeaderLevelOff]:
    dst.bus.mem[0x7E0000 + off] = readU8(src, off).uint8

proc walkSpan(snes: SnesBus; c: var Cpu; frames: int): tuple[span, maxFo, maxMa: int] =
  ## AgentLate south bias; return span and peaks.
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
  result.maxFo = foursidePercent(snes)
  result.maxMa = magicantPercent(snes)
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
    if fo > result.maxFo: result.maxFo = fo
    if ma > result.maxMa: result.maxMa = ma
  result.span = (maxX - minX) + (maxY - minY)

proc main() =
  ## Build fo80 from Paula fo60 free seat + Poo party (continuous midgame handoff).
  doAssert fileExists(Rom)
  doAssert fileExists(PooJoined)
  let base =
    if fileExists(Fo60Paula): Fo60Paula
    elif fileExists(Fo60): Fo60
    else: ""
  doAssert base.len > 0, "need fourside60_from_paula or fourside60_walkable"
  let partyPath = if fileExists(PooDeep): PooDeep else: PooJoined

  var (snes, c) = loadPath(base)
  let foBefore = foursidePercent(snes)
  doAssert foBefore >= 60 or partyHasChar(snes, PartyCharPoo),
    "base should be fo60 free seat (got fo=" & $foBefore & ")"
  doAssert not partyHasChar(snes, PartyCharPoo) or foBefore >= 80

  let (partySrc, _) = loadPath(partyPath)
  copyPartyAndLevel(snes, partySrc)
  let fo0 = foursidePercent(snes)
  echo fmt"SYNTH base={extractFilename(base)} party={extractFilename(partyPath)} " &
    fmt"fo={fo0} ma={magicantPercent(snes)} poo={partyHasChar(snes, PartyCharPoo)} " &
    fmt"lv={partyLeaderLevel(snes)} pa={paulaRescuePercent(snes)} wi={wintersPercent(snes)}"
  doAssert partyHasChar(snes, PartyCharPoo)
  doAssert fo0 >= 80, "Poo join must grade fo>=80 (got " & $fo0 & ")"
  doAssert partyHasChar(snes, PartyCharPaula), "keep Paula through handoff"
  doAssert partyHasChar(snes, PartyCharJeff), "keep Jeff through handoff"

  let initial = serializeState(snes, c)
  writeFile(Out, cast[string](initial))
  echo "WROTE ", Out, " ", checkpointSpineLine(snes)

  var (s2, c2) = loadPath(Out)
  let w = walkSpan(s2, c2, 3500)
  echo fmt"PROVE span={w.span} maxFo={w.maxFo} maxMa={w.maxMa} end_fo={foursidePercent(s2)}"
  doAssert w.span >= 64, "fo80 from Paula seat must walk (span=" & $w.span & ")"
  doAssert w.maxFo >= 80, "must peak fo>=80 under AgentLate"
  # Keep initial grade snapshot (walk may regrade py soft bands).
  writeFile(Out, cast[string](initial))
  var (s3, _) = loadPath(Out)
  doAssert foursidePercent(s3) >= 80
  doAssert partyHasChar(s3, PartyCharPoo)
  echo "FINAL ", Out, " ", checkpointSpineLine(s3)
  echo "OK synth_fourside80_from_paula"

when isMainModule:
  main()
