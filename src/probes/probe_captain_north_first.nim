## Try north-to-y=0x0200 then west from giant for captain 50.
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

proc run(name, pol: string) =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/giant_approach.state")), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua, "sk")
  loadChunk(L, pol, name)
  var maxCs = captainStrongPercent(snes)
  var minX = 0xFFFF
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 10000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let px = readU16(snes, WorldXBase+i)
    if px < minX: minX = px
    let cs = captainStrongPercent(snes)
    if cs > maxCs:
      maxCs = cs
      echo fmt"{name} NEW cs={maxCs} f={f} pos=(0x{px:04X},0x{readU16(snes,WorldYBase+i):04X})"
    if maxCs >= 50: break
  echo fmt"{name}: max_cs={maxCs} minX=0x{minX:04X} end=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  if maxCs >= 50:
    writeFile("bin/states/llm/captain_west.state", cast[string](serializeState(snes, c)))
    echo "WROTE captain_west"

proc main() =
  run("north_then_west", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if py > 0x0208 then
    pad.press("Up")
    return
  end
  pad.press("Left")
  if (frame() % 40) < 8 then pad.press("Up") end
end
""")
  run("north_west_diag", """
function update()
  if escapeMenu() then return end
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if py > 0x0220 then
    pad.press("Up")
    pad.press("Left")
    return
  end
  pad.press("Left")
end
""")
  run("crater_west", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  if px > 0x0780 then
    if followRoute("onett_to_crater") then return end
  end
  pad.press("Left")
end
""")

when isMainModule: main()
