## Leave-Onett soft fixture: free midgame control + Paula/Jeff party (cs 80–90).
## RE probe_leave_onett_deep: later $99F2 + Paula → cs80; +Jeff → cs90.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Free = "bin/states/slot4.state"
  Mid = "bin/states/llm/midgame_approach.state"
  Out = "bin/states/llm/leave_onett_walkable.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  ## Free control + midgame party/story flags → walkable leave soft cs≥80.
  doAssert fileExists(Rom) and fileExists(Free) and fileExists(Mid)
  let free = newSnesBus(policy.readRomFile(Rom))
  var cf = free.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Free)), free, cf)
  let mid = newSnesBus(policy.readRomFile(Rom))
  var cm = mid.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Mid)), mid, cm)
  # Copy party + story progress from mid onto free control.
  for off in [PartySlot0, PartySlot1, PartySlot2, PartySlot3,
              PartySizeOffA, PartySizeOffB, PartyLeaderLevelOff,
              KnockCompleteOff, KnockStoryFlagOff]:
    free.bus.mem[0x7E0000 + off] = readU8(mid, off).uint8
  # Event-flag window for later-story soft (same class as fo80 synth).
  for off in 0x9A00 .. 0x9BFF:
    free.bus.mem[0x7E0000 + off] = readU8(mid, off).uint8
  # Keep free outdoor pos (walkable mid pocket).
  let cs0 = captainStrongPercent(free)
  echo fmt"SYNTH leave_onett cs={cs0} paula={paulaRescuePercent(free)} " &
    fmt"winters={wintersPercent(free)} fo={foursidePercent(free)} " &
    fmt"paulaIn={partyHasChar(free, PartyCharPaula)} " &
    fmt"jeffIn={partyHasChar(free, PartyCharJeff)}"
  doAssert cs0 >= 80, "leave soft must grade cs≥80, got " & $cs0
  writeFile(Out, cast[string](serializeState(free, cf)))
  echo "WROTE ", Out, " ", checkpointSpineLine(free)

  # Prove walk
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Out)), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentMidgameExplorePolicy, "mid")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  var minCs = captainStrongPercent(snes)
  var maxCs = minCs
  for f in 1 .. 3000:
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
    let cs = captainStrongPercent(snes)
    if cs < minCs: minCs = cs
    if cs > maxCs: maxCs = cs
  let span = (maxX - minX) + (maxY - minY)
  echo fmt"PROVE span={span} minCs={minCs} maxCs={maxCs} " &
    fmt"end_cs={captainStrongPercent(snes)}"
  doAssert span >= 64, "leave fixture must be walkable"
  doAssert maxCs >= 80, "must hold leave soft cs≥80"
  doAssert minCs >= 70, "must not drop below later-story soft"
  echo "OK synth_leave_onett"

when isMainModule:
  main()
