## From captain_approach, try to hit captain 50 (px<=0x0880) and 60 (py>=0x02A0).
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

proc run(name, pol: string) =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/captain_approach.state")), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua, "sk")
  loadChunk(L, pol, name)
  var maxCs = captainStrongPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 6000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let cs = captainStrongPercent(snes)
    if cs > maxCs:
      maxCs = cs
      echo fmt"{name} NEW cs={maxCs} f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
    if maxCs >= 60: break
  echo fmt"{name}: max_cs={maxCs} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"

proc main() =
  run("agent", AgentCaptainStrongPolicy)
  run("dpad_sw", """
function update()
  if escapeMenu() then return end
  local f = frame() % 24
  if f < 12 then pad.press("Left") else pad.press("Down") end
  if (frame() % 48) < 6 then pad.press("Up") end
end
""")
  run("north_then_west", """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if py > 0x0260 then pad.press("Up"); return end
  pad.press("Left")
  if (frame() % 30) < 8 then pad.press("Up") end
end
""")

when isMainModule: main()
