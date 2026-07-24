## Compare walkTo movement across indoor/outdoor fixtures.
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  ## Run walkTo for 800 frames; print position delta per fixture.
  let paths = [
    "bin/states/llm/bedroom.state",
    "bin/states/llm/home_indoor.state",
    "bin/states/llm/post_knock.state",
    "bin/states/llm/onett_start.state",
  ]
  for path in paths:
    if not fileExists(path): continue
    let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(path)), snes, c)
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let ctx = policy.PolicyContext(
      snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
    let L = lua53.newstate()
    L.openSandbox()
    policy.setupPolicyApi(L, ctx)
    loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua, "sk")
    let pol =
      if path.find("onett") >= 0:
        "function update() if escapeMenu() then return end; walkTo(0x0B00, 0x0180) end"
      else:
        "function update() if escapeMenu() then return end; walkTo(0x1F40, 0x0148) end"
    loadChunk(L, pol, "pol")
    let i = PlayerSlot * SlotIndexStride
    let px0 = readU16(snes, WorldXBase + i)
    let py0 = readU16(snes, WorldYBase + i)
    for f in 0 .. 800:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
    let px1 = readU16(snes, WorldXBase + i)
    let py1 = readU16(snes, WorldYBase + i)
    echo fmt"{path.splitPath.tail}: ({px0:04X},{py0:04X})->({px1:04X},{py1:04X}) d={abs(px1-px0)+abs(py1-py0)} joy=0x{ctx.joy1:04X} w1={touch_grass.readU8(snes,0x8654):02X}"

when isMainModule:
  main()
