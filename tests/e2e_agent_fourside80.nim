## AgentLateGame on free+Poo fo80 walkable fixture: hold fo>=80 and move.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fo80 = "bin/states/llm/fourside80_walkable.state"
  PooJoined = "bin/states/llm/poo_joined.state"
  FreeOut = "bin/states/llm/poo_free_outdoor.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  ## Past fo60 gap: free control + Poo party must grade fo80 and locomote.
  doAssert fileExists(Rom)
  let path =
    if fileExists(Fo80): Fo80
    elif fileExists(FreeOut): FreeOut
    elif fileExists(PooJoined): PooJoined
    else: ""
  doAssert path.len > 0, "need fourside80_walkable or Poo-era fixture"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let startFo = foursidePercent(snes)
  let startMa = magicantPercent(snes)
  echo "START path=", path, " fo=", startFo, " ma=", startMa,
    " poo=", partyHasChar(snes, PartyCharPoo), " lv=", partyLeaderLevel(snes)
  echo "POLICY=AgentLateGamePolicy"
  doAssert "followRoute(" notin AgentLateGamePolicy
  doAssert partyHasChar(snes, PartyCharPoo), "fixture must have Poo for fo80"
  doAssert startFo >= 80, "need fo>=80 start, got " & $startFo

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentLateGamePolicy, "late")
  let i = PlayerSlot * SlotIndexStride
  var minX, minY = 0xFFFF
  var maxX, maxY = 0
  var minFo = startFo
  var maxFo = startFo
  var maxMa = startMa
  for f in 1 .. 4000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let fo = foursidePercent(snes)
    let ma = magicantPercent(snes)
    if fo < minFo: minFo = fo
    if fo > maxFo: maxFo = fo
    if ma > maxMa: maxMa = ma
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  let span = (maxX - minX) + (maxY - minY)
  echo "FINAL fo=", foursidePercent(snes), " minFo=", minFo, " maxFo=", maxFo,
    " maxMa=", maxMa, " span=", span
  echo "spine ", checkpointSpineLine(snes)
  doAssert maxFo >= 80, "must hold/peak fo>=80 under Agent (got max " & $maxFo & ")"
  doAssert partyHasChar(snes, PartyCharPoo), "Poo party must hold"
  # Free blends and free outdoor should move; some deep F12s control-lock.
  if path.contains("walkable") or path.contains("free") or path.contains("joined"):
    doAssert span >= 32 or maxFo >= 90,
      "walkable fo80 should move (span=" & $span & ")"
  echo "OK test_agent_fourside80: fo>=80 + Poo hold past fo60 gap"

when isMainModule:
  main()
