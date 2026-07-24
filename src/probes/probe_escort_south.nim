## From buzz_meteor leave site south for sunrise 80 escort-start band.
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
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/buzz_meteor.state")), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  -- no talk thrash — leave site via home trail then south
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if py < 0x0180 then
    if followRoute("crater_to_onett") then return end
    pad.press("Down")
    return
  end
  if py < 0x0240 then
    if followRoute("onett_to_crater") then return end
    pad.press("Down")
    return
  end
  pad.press("Down")
end
""", "pol")
  var maxSu = sunrisePercent(snes)
  var maxBb = buzzBuzzPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"START su={maxSu} bb={maxBb} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    let su = sunrisePercent(snes)
    let bb = buzzBuzzPercent(snes)
    if su > maxSu: maxSu = su
    if bb > maxBb: maxBb = bb
    if f mod 1500 == 0 or su >= 80:
      echo fmt"f={f} su={su} maxsu={maxSu} bb={bb} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
    if maxSu >= 80: break
  echo fmt"FINAL maxsu={maxSu} maxbb={maxBb}"
  if maxSu >= 80:
    writeFile("bin/states/llm/escort_south.state", cast[string](serializeState(snes, cpu)))
    echo "WROTE escort_south.state"

when isMainModule: main()
