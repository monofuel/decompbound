import
  std/strformat,
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc run(path, name: string) =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  pad.press("Left")
  if (frame() % 32) < 10 then pad.press("Up") end
  if (frame() % 32) >= 24 then pad.press("Down") end
end
""", name)
  var maxCs = captainStrongPercent(snes)
  var minX = 0xFFFF
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 10000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    if px < minX: minX = px
    let cs = captainStrongPercent(snes)
    if cs > maxCs:
      maxCs = cs
      echo fmt"{name} NEW cs={maxCs} f={f} pos=(0x{px:04X},0x{py:04X})"
    if maxCs >= 50: break
  echo fmt"{name}: max_cs={maxCs} minX=0x{minX:04X} end=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  if maxCs >= 50:
    writeFile("bin/states/llm/captain_west.state", cast[string](serializeState(snes, cpu)))
    echo "WROTE captain_west"

proc main() =
  run("bin/states/llm/giant_approach.state", "from_giant")
  # synth a state slightly east of wall by loading giant and only left without down
  run("bin/states/llm/captain_approach.state", "from_captain")

when isMainModule: main()
