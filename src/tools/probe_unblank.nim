## After house exit force-blank, poke INIDISP and re-render to see if map data exists.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ./[touch_grass, llm_mock_policies]

proc loadChunk(L: lua53.PState, src: string, label: string): bool =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    L.pop(1); return false
  if L.pcall(0, 0, 0) != lua53.OK:
    L.pop(1); return false
  true

proc litCount(img: Image): int =
  for y in 0 ..< 224:
    for x in 0 ..< 256:
      let p = img[x, y]
      if p.r.int + p.g.int + p.b.int > 40: inc result

proc main() =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpuState = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/bedroom.state")), snes, cpuState)
  let frameImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: frameImage, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  discard loadChunk(L, touch_grass.EscapeMenuSkillLua & "\n" & touch_grass.WalkToSkillLua, "s")
  discard loadChunk(L, llm_mock_policies.NavHousePolicy, "n")
  var outF = -1
  for f in 0 .. 2000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = if outF >= 0: 0'u16 else: ctx.joy1
    policy.stepOneFrame(snes, cpuState, frameImage)
    if touch_grass.touchGrassPercent(snes) == 100 and outF < 0:
      outF = f
      echo fmt"outside f={f} INIDISP={snes.ppuRegs[0x00]:02X}"
    if outF >= 0 and f >= outF + 60:
      break
  echo fmt"before poke lit={litCount(frameImage)} INIDISP={snes.ppuRegs[0x00]:02X}"
  snes.ppuRegs[0x00] = 0x0F
  frameImage.fill(ppu.bgr555ToColor(snes.cgram[0]))
  for line in 0 ..< 224:
    ppu.renderScanline(snes, frameImage, line)
  ppu.renderSprites(snes, frameImage)
  echo fmt"after unblank lit={litCount(frameImage)} cgram0={snes.cgram[0]:04X}"
  createDir("bin")
  frameImage.writeFile("bin/outside_force_unblank.png")
  echo "wrote bin/outside_force_unblank.png"

when isMainModule: main()
