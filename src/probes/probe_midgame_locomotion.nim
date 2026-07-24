## Try midgame outdoor locomotion on several slots; record free movement.
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

proc runPath(path: string) =
  if not fileExists(path): return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua, "sk")
  loadChunk(L, AgentMidgameExplorePolicy, "mid")
  let i = PlayerSlot * SlotIndexStride
  let sx = readU16(snes, WorldXBase+i)
  let sy = readU16(snes, WorldYBase+i)
  var minX, minY = 0xFFFF
  var maxX, maxY = 0
  for f in 1 .. 2000:
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
  echo fmt"{extractFilename(path)} start=(0x{sx:04X},0x{sy:04X}) span={span} bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X} end=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"

proc main() =
  for p in ["bin/states/slot1.state", "bin/states/slot73.state",
            "bin/states/slot75.state", "bin/states/slot80.state",
            "bin/states/slot4.state", "bin/states/battle_menu_healthy.state"]:
    runPath(p)

when isMainModule: main()
