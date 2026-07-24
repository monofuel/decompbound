## Long wander from freest midgame slot4; record bbox + midgame_wander fixture.
import
  std/strformat,
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/slot4.state")), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentMidgameExplorePolicy, "m")
  let i = PlayerSlot * SlotIndexStride
  var minX, minY = 0xFFFF
  var maxX, maxY = 0
  for f in 1 .. 15000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if py < minY: minY = py
    if px > maxX: maxX = px
    if py > maxY: maxY = py
    if f mod 3000 == 0:
      echo fmt"f={f} pos=(0x{px:04X},0x{py:04X}) bbox y 0x{minY:04X}..0x{maxY:04X}"
  echo fmt"FINAL bbox 0x{minX:04X}..0x{maxX:04X}, 0x{minY:04X}..0x{maxY:04X} span={(maxX-minX)+(maxY-minY)}"
  echo checkpointSpineLine(snes)
  writeFile("bin/states/llm/midgame_wander.state", cast[string](serializeState(snes, c)))
  echo "WROTE midgame_wander"

when isMainModule:
  main()
