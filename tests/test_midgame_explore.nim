## AgentMidgameExplorePolicy runs on freest midgame fixture; holds winters/belch soft.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Mid = "bin/states/llm/midgame_approach.state"
  Slot4 = "bin/states/slot4.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  ## Midgame explore must not drop flag-based winters/paula; prefer free outdoor.
  doAssert fileExists(Rom)
  let path =
    if fileExists(Mid): Mid
    elif fileExists(Slot4): Slot4
    else: ""
  doAssert path.len > 0, "need midgame_approach or slot4"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let startW = wintersPercent(snes)
  let startB = belchPercent(snes)
  let startP = paulaRescuePercent(snes)
  let startF = foursidePercent(snes)
  echo "START path=", path, " winters=", startW, " belch=", startB,
    " paula=", startP, " fourside=", startF
  echo "POLICY=AgentMidgameExplorePolicy"
  doAssert startW >= 50, "need Jeff-joined midgame"
  doAssert startP >= 90, "need Paula-joined midgame"

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua, "sk")
  loadChunk(L, AgentMidgameExplorePolicy, "mid")
  let i = PlayerSlot * SlotIndexStride
  var minX = 0xFFFF
  var maxX = 0
  var minY = 0xFFFF
  var maxY = 0
  for f in 1 .. 2500:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  let span = (maxX - minX) + (maxY - minY)
  echo "FINAL winters=", wintersPercent(snes), " belch=", belchPercent(snes),
    " fourside=", foursidePercent(snes), " span=", span
  echo "spine ", checkpointSpineLine(snes)
  doAssert wintersPercent(snes) >= startW, "winters flag must hold"
  doAssert paulaRescuePercent(snes) >= startP, "paula flag must hold"
  doAssert belchPercent(snes) >= 30
  # Free outdoor midgame (slot4 family) should move; corridor locks may span~0.
  if path.contains("midgame") or path.contains("slot4"):
    doAssert span >= 64 or (maxX - minX) >= 32,
      "midgame explore should move outdoors (span=" & $span & ")"
  echo "OK test_midgame_explore: midgame flags hold + explore locomotion"

when isMainModule:
  main()
