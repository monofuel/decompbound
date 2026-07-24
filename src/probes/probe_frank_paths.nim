## Try alternate routes from frank_corridor past the mid-town wall.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc runPath(name, pol: string, maxF: int) =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/frank_corridor.state")), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua, "sk")
  loadChunk(L, pol, name)
  var maxFr = frankPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. maxF:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let fr = frankPercent(snes)
    if fr > maxFr: maxFr = fr
    if maxFr >= 80: break
  echo fmt"{name}: max_frank={maxFr} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"

proc main() =
  # Path A: further west first then south
  runPath("west_then_south", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px > 0x0800 then walkTo(0x07E0, py); return end
  if py < 0x0240 then walkTo(0x07E0, 0x0250); return end
  if py < 0x0300 then walkTo(0x07C0, 0x0320); return end
  walkTo(0x0780, 0x0400)
end
""", 6000)
  # Path B: pure d-pad left then down with wiggle
  runPath("dpad_left_down", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px > 0x0780 then
    pad.press("Left")
    if (frame() % 40) < 8 then pad.press("Up") end
    if (frame() % 40) >= 30 then pad.press("Down") end
    return
  end
  pad.press("Down")
  if (frame() % 30) < 6 then pad.press("Left") end
end
""", 6000)
  # Path C: south-east around house then south
  runPath("east_south", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px < 0x0A80 and py < 0x01A0 then walkTo(0x0B00, 0x0180); return end
  if py < 0x0240 then walkTo(0x0A80, 0x0250); return end
  if py < 0x0300 then walkTo(0x0A00, 0x0320); return end
  walkTo(0x0980, 0x0400)
end
""", 6000)
  # Path D: followRoute onett_to_crater reverse? or go south from door band
  runPath("from_door_south", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- first get back near door then south along road
  if py < 0x0180 and px > 0x0A00 then
    walkTo(0x0A60, 0x0188)
    return
  end
  if py < 0x0240 then
    walkTo(0x0A40, 0x0250)
    return
  end
  if py < 0x0300 then
    walkTo(0x0A20, 0x0320)
    return
  end
  walkTo(0x0A00, 0x0400)
end
""", 6000)
  # Path E: raw down+left spam from corridor
  runPath("spam_down_left", """
function update()
  if escapeMenu() then return end
  local f = frame() % 16
  if f < 10 then pad.press("Down")
  elseif f < 14 then pad.press("Left")
  else pad.press("Right") end
end
""", 8000)

when isMainModule: main()
