## From giant_approach, try west/south/east for captain_strong / deeper map.
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
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/giant_approach.state")), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua, "sk")
  loadChunk(L, pol, name)
  var minX, maxX, minY, maxY: int
  let i = PlayerSlot * SlotIndexStride
  minX = readU16(snes, WorldXBase+i); maxX = minX
  minY = readU16(snes, WorldYBase+i); maxY = minY
  var maxCs = captainStrongPercent(snes)
  var maxFr = frankPercent(snes)
  var maxGs = giantStepPercent(snes)
  for f in 1 .. 8000:
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
    let cs = captainStrongPercent(snes)
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    if cs > maxCs: maxCs = cs
    if fr > maxFr: maxFr = fr
    if gs > maxGs: maxGs = gs
  echo fmt"{name}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) extent x=0x{minX:04X}..0x{maxX:04X} y=0x{minY:04X}..0x{maxY:04X} max_cs={maxCs} max_fr={maxFr} max_gs={maxGs}"

proc main() =
  runPath("dpad_west", """
function update()
  if escapeMenu() then return end
  local f = frame() % 32
  pad.press("Left")
  if f < 8 then pad.press("Up") elseif f < 16 then pad.press("Down") end
end
""")
  runPath("dpad_south", """
function update()
  if escapeMenu() then return end
  local f = frame() % 32
  pad.press("Down")
  if f < 8 then pad.press("Left") elseif f < 16 then pad.press("Right") end
end
""")
  runPath("west_then_south", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px > 0x0880 then walkTo(0x0860, py); return end
  if py < 0x02C0 then walkTo(0x0860, 0x02D0); return end
  walkTo(0x0800, 0x0300)
end
""")
  runPath("follow_crater_west", """
function update()
  if escapeMenu() then return end
  if followRoute("onett_to_crater") then return end
  pad.press("Left")
end
""")
  runPath("to_onett_road_lm", """
function update()
  if escapeMenu() then return end
  -- landmark onett_road is 0x0680,0x01F8
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if py > 0x0220 then walkTo(px, 0x0200); return end
  if px > 0x0700 then walkTo(0x06A0, 0x01F8); return end
  walkTo(0x0680, 0x01F8)
end
""")

when isMainModule: main()
