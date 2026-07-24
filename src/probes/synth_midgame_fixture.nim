## Copy freest midgame outdoor slot into bin/states/llm/midgame_approach.state.
## slot4 probe: span~1800 px free walk (unlike slot1 corridor lock).
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  let src = "bin/states/slot4.state"
  doAssert fileExists(src)
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(src)), snes, cpu)
  echo "SRC ", checkpointSpineLine(snes)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua, "sk")
  loadChunk(L, AgentMidgameExplorePolicy, "mid")
  let i = PlayerSlot * SlotIndexStride
  var bestSpan = 0
  var best: seq[byte] = @[]
  var minX, minY = 0xFFFF
  var maxX, maxY = 0
  for f in 1 .. 3000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    if px < minX: minX = px
    if py < minY: minY = py
    if px > maxX: maxX = px
    if py > maxY: maxY = py
    let span = (maxX - minX) + (maxY - minY)
    if span > bestSpan:
      bestSpan = span
      best = serializeState(snes, cpu)
  doAssert best.len > 0
  writeFile("bin/states/llm/midgame_approach.state", cast[string](best))
  deserializeState(best, snes, cpu)
  echo fmt"WROTE midgame_approach span={bestSpan} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  echo "  ", checkpointSpineLine(snes)
  doAssert wintersPercent(snes) >= 50
  doAssert belchPercent(snes) >= 30
  echo "OK synth_midgame_fixture"

when isMainModule: main()
