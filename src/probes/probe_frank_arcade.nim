## From frank_downtown (60), try to reach arcade band frank 80.
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

proc runPath(name, pol: string) =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/frank_downtown.state")), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua, "sk")
  loadChunk(L, pol, name)
  var maxFr = frankPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let fr = frankPercent(snes)
    if fr > maxFr:
      maxFr = fr
      echo fmt"{name} NEW frank={maxFr} f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
    if maxFr >= 80: break
  echo fmt"{name}: max_frank={maxFr} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  if maxFr >= 80:
    writeFile("bin/states/llm/frank_arcade.state", cast[string](serializeState(snes, cpu)))
    echo "WROTE frank_arcade.state"

proc main() =
  echo "start frank=", frankPercent(block:
    let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/frank_downtown.state")), snes, cpu)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes)
  # A: pure d-pad down with lateral wiggle
  runPath("dpad_south", """
function update()
  if escapeMenu() then return end
  local f = frame() % 32
  pad.press("Down")
  if f < 8 then pad.press("Left") elseif f < 16 then pad.press("Right") end
end
""",)
  # B: west along road then south
  runPath("west_then_south", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px > 0x0900 then walkTo(0x08E0, 0x026D); return end
  if py < 0x0300 then walkTo(0x08E0, 0x0320); return end
  walkTo(0x08C0, 0x0380)
end
""")
  # C: east then south
  runPath("east_then_south", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px < 0x0A80 then walkTo(0x0AA0, 0x02A0); return end
  if py < 0x0300 then walkTo(0x0AA0, 0x0320); return end
  walkTo(0x0A80, 0x0380)
end
""")
  # D: keep following onett_to_crater a bit then peel south from west
  runPath("route_then_south", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px > 0x0920 then
    if followRoute("onett_to_crater") then return end
  end
  if py < 0x0300 then
    pad.press("Down")
    if (frame() % 40) < 10 then pad.press("Left") end
    return
  end
  pad.press("Down")
end
""")
  # E: navTo south
  runPath("nav_south", """
function update()
  if escapeMenu() then return end
  if navTo then navTo(0x0980, 0x0340); return end
  pad.press("Down")
end
""")

when isMainModule: main()
