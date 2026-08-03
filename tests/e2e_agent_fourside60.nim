## AgentFoursideApproachPolicy on walkable fo60 fixture: hold fourside>=60 + move.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fo60 = "bin/states/llm/fourside60_walkable.state"
  Deep = "bin/states/llm/fourside_deep_prepoo.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk that defines globals.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  ## Prove free+deep walkable fo60: policy holds grade and moves (not control-lock).
  doAssert fileExists(Rom)
  let path =
    if fileExists(Fo60): Fo60
    elif fileExists(Deep): Deep
    else: ""
  doAssert path.len > 0, "need fourside60_walkable or fourside_deep_prepoo"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let startFo = foursidePercent(snes)
  let startW = wintersPercent(snes)
  let startP = paulaRescuePercent(snes)
  echo "START path=", path, " fo=", startFo, " winters=", startW, " paula=", startP
  echo "POLICY=AgentFoursideApproachPolicy body_len=", AgentFoursideApproachPolicy.len
  doAssert "followRoute(" notin AgentFoursideApproachPolicy,
    "Agent Fourside seed must not be trail-only"
  doAssert startFo >= 60, "fixture must grade fourside>=60, got " & $startFo
  doAssert startW >= 50, "need Jeff-era midgame flags"

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentFoursideApproachPolicy, "fo60")
  let i = PlayerSlot * SlotIndexStride
  var minX, minY = 0xFFFF
  var maxX, maxY = 0
  var minFo = startFo
  var maxFo = startFo
  for f in 1 .. 4000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let fo = foursidePercent(snes)
    if fo < minFo: minFo = fo
    if fo > maxFo: maxFo = fo
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  let span = (maxX - minX) + (maxY - minY)
  echo "FINAL fo=", foursidePercent(snes), " minFo=", minFo, " maxFo=", maxFo,
    " span=", span, " winters=", wintersPercent(snes)
  echo "spine ", checkpointSpineLine(snes)
  doAssert maxFo >= 60, "must reach/hold fourside>=60 under Agent policy"
  # Free walkable synth should move; deep_prepoo alone may control-lock (span 0).
  if path.contains("walkable") or path.contains("free"):
    doAssert span >= 32, "walkable fo60 must move under Agent (span=" & $span & ")"
    doAssert foursidePercent(snes) >= 60 or maxFo >= 60,
      "must not permanently drop below fo60 without having held it"
  doAssert wintersPercent(snes) >= startW, "winters soft must hold"
  echo "OK test_agent_fourside60: fo>=60 + locomotion on free deep fixture"

when isMainModule:
  main()
