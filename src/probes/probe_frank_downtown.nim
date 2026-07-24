## Drive deeper south/west from frank_corridor; aim frank 60–80.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1

proc main() =
  var path = "bin/states/llm/frank_corridor.state"
  if not fileExists(path):
    path = "bin/states/llm/post_knock_outdoor.state"
  doAssert fileExists(path), path
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  # ensure knock signature
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "sk")
  # Deep downtown: from mid-town push south then west/south toward arcade
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local w0 = mem.read(0x8650)
  local w1 = mem.read(0x8654)
  if w0 ~= 0xFF or w1 ~= 0xFF then
    if (frame() % 8) < 4 then pad.press("A") else pad.press("B") end
    return
  end
  -- Reach west road first
  if px > 0x0900 then
    walkTo(0x0880, py)
    return
  end
  -- South to y 0x0240 (frank 60)
  if py < 0x0240 then
    walkTo(0x0860, 0x0250)
    return
  end
  -- South to y 0x0300 (frank 80)
  if py < 0x0300 then
    walkTo(0x0840, 0x0320)
    return
  end
  -- Arcade band: explore SW
  if py < 0x0400 then
    walkTo(0x0780, 0x0420)
    return
  end
  local f = frame() % 100
  if f < 50 then pad.press("Down") else pad.press("Left") end
end
""", "deep")
  var maxFr = frankPercent(snes)
  var maxBb = buzzBuzzPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"START path={path} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) frank={maxFr} buzz={maxBb}"
  for f in 1 .. 10000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let ea = 0x7E0000 + KnockCompleteOff
    if snes.bus.mem[ea] != KnockCompleteVal.uint8:
      snes.bus.mem[ea] = KnockCompleteVal.uint8
    let fr = frankPercent(snes)
    let bb = buzzBuzzPercent(snes)
    if fr > maxFr: maxFr = fr
    if bb > maxBb: maxBb = bb
    if f mod 500 == 0:
      echo fmt"f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) frank={fr} maxF={maxFr} buzz={bb} joy=0x{ctx.joy1:04X}"
    if maxFr >= 80: break
  echo fmt"FINAL max_frank={maxFr} max_buzz={maxBb} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let outp = "bin/states/llm/frank_downtown.state"
  writeFile(outp, cast[string](serializeState(snes, cpu)))
  echo "WROTE ", outp, " frank=", frankPercent(snes), " buzz=", buzzBuzzPercent(snes)

when isMainModule: main()
