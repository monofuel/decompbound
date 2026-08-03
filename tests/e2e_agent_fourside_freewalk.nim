## Free-walk fo60 segment without campaign mid-run loads: free control + deep
## pos fixture and AgentFoursideApproachPolicy hold max_fo >= 60.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fo60Walk = "bin/states/llm/fourside60_walkable.state"
  Fo60Free = "bin/states/llm/fourside60_freewalk.state"
  FreeSlot = "bin/states/slot4.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc setPos(snes: SnesBus; x, y: int) =
  ## Write player world X/Y.
  let i = PlayerSlot * SlotIndexStride
  snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(x and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8((x shr 8) and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(y and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8((y shr 8) and 0xFF)

proc ensureFreewalk() =
  ## Prefer committed walkable; else synth free flags + deep pos (not campaign load).
  if fileExists(Fo60Walk) or fileExists(Fo60Free):
    return
  doAssert fileExists(FreeSlot) or fileExists(Fo60Walk),
    "need free control or fo60 walkable fixture"

proc main() =
  ## AgentFourside free-walk holds fo60 peak on free-control deep map.
  doAssert fileExists(Rom)
  ensureFreewalk()
  let path =
    if fileExists(Fo60Walk): Fo60Walk
    elif fileExists(Fo60Free): Fo60Free
    else: FreeSlot
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  if path == FreeSlot:
    setPos(snes, 0x0F8A, 0x1A00)
  let startFo = foursidePercent(snes)
  echo "START path=", path, " fo=", startFo, " POLICY=AgentFoursideApproachPolicy"
  doAssert startFo >= 60, "need fo60 band at start (got " & $startFo & ")"

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & IntentNavSkillLua &
    "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentFoursideApproachPolicy, "fo")

  var maxFo = startFo
  var minFo = startFo
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  for f in 1 .. 4000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let fo = foursidePercent(snes)
    if fo > maxFo: maxFo = fo
    if fo < minFo: minFo = fo
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py

  let span = (maxX - minX) + (maxY - minY)
  echo "FINAL max_fo=", maxFo, " min_fo=", minFo, " span=", span
  doAssert maxFo >= 60, "free-walk must keep fo60 peak (got " & $maxFo & ")"
  doAssert span > 100, "must free-walk (span>100); span=" & $span
  echo "OK test_agent_fourside_freewalk: max_fo=", maxFo, " span=", span

when isMainModule:
  main()
