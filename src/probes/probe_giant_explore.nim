## Explore from giant_approach; log farthest N/S/E/W and max giant/frank.
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

proc runDir(name, pol: string) =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/giant_approach.state")), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua, "sk")
  loadChunk(L, pol, name)
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase+i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase+i)
  var maxY = minY
  var maxGs = giantStepPercent(snes)
  var maxFr = frankPercent(snes)
  for f in 1 .. 6000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    let gs = giantStepPercent(snes)
    let fr = frankPercent(snes)
    if gs > maxGs: maxGs = gs
    if fr > maxFr: maxFr = fr
  echo fmt"{name}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) extent x=0x{minX:04X}..0x{maxX:04X} y=0x{minY:04X}..0x{maxY:04X} max_gs={maxGs} max_fr={maxFr}"

proc main() =
  runDir("north_wiggle", """
function update()
  if escapeMenu() then return end
  local f = frame() % 40
  pad.press("Up")
  if f < 10 then pad.press("Left") elseif f < 20 then pad.press("Right") end
end
""")
  runDir("west_wiggle", """
function update()
  if escapeMenu() then return end
  local f = frame() % 40
  pad.press("Left")
  if f < 10 then pad.press("Up") elseif f < 20 then pad.press("Down") end
end
""")
  runDir("east_wiggle", """
function update()
  if escapeMenu() then return end
  local f = frame() % 40
  pad.press("Right")
  if f < 10 then pad.press("Up") elseif f < 20 then pad.press("Down") end
end
""")
  runDir("follow_crater", """
function update()
  if escapeMenu() then return end
  if followRoute("onett_to_crater") then return end
  pad.press("Up")
end
""")
  runDir("go_crater_route", """
function update()
  if escapeMenu() then return end
  -- continue west-north like crater trail from south band
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px > 0x0700 then walkTo(0x06A0, 0x01F8); return end
  if py > 0x0140 then walkTo(0x0600, 0x0120); return end
  walkTo(0x0858, 0x00F2)
end
""")

when isMainModule: main()
