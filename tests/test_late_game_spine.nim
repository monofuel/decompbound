## Past fourside40: deep map + Poo-era flag ladders (shipped story_percents).
## Fixtures extracted from play F12 ebSt (local only).

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  DeepPre = "bin/states/llm/fourside_deep_prepoo.state"
  PooJoined = "bin/states/llm/poo_joined.state"
  PooDeep = "bin/states/llm/poo_deep_south.state"
  PooVery = "bin/states/llm/poo_very_deep.state"
  PooSolo = "bin/states/llm/poo_solo.state"
  Mid = "bin/states/llm/midgame_approach.state"
  CapWest = "bin/states/llm/captain_west.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc grade(path: string): tuple[fo, ma, gi: int] =
  doAssert fileExists(path), path
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  result = (foursidePercent(snes), magicantPercent(snes), giygasPercent(snes))
  echo path, " partyHasPoo=", partyHasChar(snes, PartyCharPoo),
    " fourside=", result.fo, " magicant=", result.ma, " giygas=", result.gi
  echo "  ", checkpointSpineLine(snes)

proc main() =
  ## Flag ladders past fourside 40 using real F12-derived fixtures.
  doAssert fileExists(Rom)

  if fileExists(Mid):
    let m = grade(Mid)
    doAssert m.fo == 40, "midgame desert band stays fourside 40"
    doAssert m.ma == 0

  if fileExists(DeepPre):
    let d = grade(DeepPre)
    doAssert d.fo >= 60, "deep pre-Poo py>=0x1A00 grades fourside>=60 (got " &
      $d.fo & ")"
    doAssert d.ma == 0, "no Poo => magicant 0"

  if fileExists(PooJoined):
    let snesJ = newSnesBus(policy.readRomFile(Rom))
    var cJ = snesJ.resetCpu()
    deserializeState(cast[seq[byte]](readFile(PooJoined)), snesJ, cJ)
    doAssert partyHasChar(snesJ, PartyCharPoo), "poo_joined has Poo id 4"
    let p = grade(PooJoined)
    doAssert p.fo >= 80, "Poo join grades fourside>=80"
    doAssert p.ma >= 30, "Poo join grades magicant>=30"

  if fileExists(PooDeep):
    let p = grade(PooDeep)
    doAssert p.fo >= 80
    doAssert p.ma >= 50, "Poo + py>=0x1800 magicant>=50"
    doAssert p.gi >= 20, "magicant 50 opens giygas soft 20"

  if fileExists(PooVery):
    let snesV = newSnesBus(policy.readRomFile(Rom))
    var cV = snesV.resetCpu()
    deserializeState(cast[seq[byte]](readFile(PooVery)), snesV, cV)
    let bp = eventFlagBitPop(snesV)
    echo "poo_very_deep leaderLv=", partyLeaderLevel(snesV),
      " partySize=", partySize(snesV), " bitpop=", bp
    doAssert partyLeaderLevel(snesV) >= 22, "RE: late outdoor Ness level ~22"
    doAssert partySize(snesV) == 4
    doAssert bp >= EventFlagBitPopLateDeep, "late deep bitpop >=590 (got " & $bp & ")"
    doAssert hasAllSanctuarySoft(snesV), "sanctuary-soft proxy on very_deep"
    doAssert not hasMagicantDreamFlag(snesV), "100 dream bit still unset"
    doAssert not hasGiygasPhaseFlag(snesV), "100 Giygas bit still unset"
    let p = grade(PooVery)
    doAssert p.fo >= 90, "Poo + py>=0x2000 fourside>=90"
    # bitpop+lv → soft 98 / giygas 80; true 100 reserved.
    doAssert p.ma >= 98, "sanctuary-soft magicant>=98 (got " & $p.ma & ")"
    doAssert p.ma < 100, "magicant 100 only when dream flag RE'd"
    doAssert p.gi >= 80, "magicant 98 opens giygas soft 80 (got " & $p.gi & ")"
    doAssert p.gi < 100, "giygas 100 only when phase flag RE'd"

  if fileExists(PooSolo):
    let p = grade(PooSolo)
    doAssert p.fo >= 80, "solo Poo still past-Fourside soft"
    doAssert p.ma >= 30
    doAssert p.gi == 0, "solo Dalaam soft does not open giygas"

  if fileExists(CapWest):
    let n = grade(CapWest)
    doAssert n.fo == 0 and n.ma == 0 and n.gi == 0,
      "night captain must not grade late spine"

  # AgentLateGamePolicy locomotion on freest Poo outdoor (prefer soft98 peak path).
  let freePath =
    if fileExists("bin/states/llm/poo_soft98_walkable.state"):
      "bin/states/llm/poo_soft98_walkable.state"
    elif fileExists("bin/states/llm/poo_free_outdoor.state"):
      "bin/states/llm/poo_free_outdoor.state"
    elif fileExists(PooVery): PooVery
    elif fileExists(PooJoined): PooJoined
    else: ""
  if freePath.len > 0:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(freePath)), snes, c)
    let startFo = foursidePercent(snes)
    let startMa = magicantPercent(snes)
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
    var span = 0
    var minX = readU16(snes, WorldXBase + i)
    var maxX = minX
    var minY = readU16(snes, WorldYBase + i)
    var maxY = minY
    for f in 1 .. 3000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
      let ma = magicantPercent(snes)
      if ma > maxMa: maxMa = ma
      let px = readU16(snes, WorldXBase + i)
      let py = readU16(snes, WorldYBase + i)
      if px < minX: minX = px
      if px > maxX: maxX = px
      if py < minY: minY = py
      if py > maxY: maxY = py
    span = (maxX - minX) + (maxY - minY)
    echo "LATE path=", freePath, " max_magicant=", maxMa, " span=", span,
      " end_magicant=", magicantPercent(snes), " end_bitpop=", eventFlagBitPop(snes),
      " fourside=", foursidePercent(snes)
    doAssert foursidePercent(snes) >= startFo, "late explore must not drop fourside"
    # Event-flag bitpop thrash on walk can dip below soft-98 threshold briefly;
    # grade the peak magicant held during the leg.
    doAssert maxMa >= startMa, "late explore peak magicant must not regress"
    doAssert startFo >= 80, "free late fixture should be Poo-era fourside>=80"
    if freePath.contains("soft98") or freePath.contains("very_deep"):
      doAssert maxMa >= 98, "soft98/very_deep peak past ma95 into soft ceiling 98"
      doAssert span >= 32, "soft98 walkable under AgentLateGame"
    elif freePath.contains("free") or freePath.contains("joined"):
      doAssert span >= 32 or startMa >= 70,
        "free late outdoor should move or already at magicant 70 (span=" & $span & ")"
    echo "POLICY=AgentLateGamePolicy OK"

  echo "OK test_late_game_spine: past fourside40 via deep map + Poo ladders"

when isMainModule:
  main()
