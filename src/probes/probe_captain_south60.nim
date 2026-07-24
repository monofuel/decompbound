## From captain_west, push south for captain_strong 60 (py>=0x02A0).
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

proc main() =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/captain_west.state")), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if py < 0x02A0 then
    pad.press("Down")
    if (frame() % 40) < 10 then pad.press("Left") end
    if (frame() % 40) >= 30 then pad.press("Right") end
  else
    pad.press("Left")
  end
end
""", "south")
  var maxCs = captainStrongPercent(snes)
  var maxPy = 0
  let i = PlayerSlot * SlotIndexStride
  echo fmt"START cs={maxCs} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let py = readU16(snes, WorldYBase + i)
    if py > maxPy: maxPy = py
    let cs = captainStrongPercent(snes)
    if cs > maxCs:
      maxCs = cs
      echo fmt"NEW cs={maxCs} f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{py:04X})"
    if maxCs >= 60: break
  echo fmt"FINAL max_cs={maxCs} maxPy=0x{maxPy:04X} end=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) paula={paulaRescuePercent(snes)}"

when isMainModule:
  main()
