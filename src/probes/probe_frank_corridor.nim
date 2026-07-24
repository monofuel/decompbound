## Drive south/west from post_knock_outdoor; log frank/buzz and pos.
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

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc main() =
  let path = "bin/states/llm/post_knock_outdoor.state"
  doAssert fileExists(path)
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "sk")
  # Aggressive downtown policy: west then south hard.
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  if advanceDialogue and advanceDialogue() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- Head west to main road then south toward arcade/downtown.
  if px > 0x0900 then
    if navTo then navTo(0x0880, py) else walkTo(0x0880, py) end
    return
  end
  if py < 0x0300 then
    if navTo then navTo(px, 0x0320) else walkTo(px, 0x0320) end
    return
  end
  if navTo then navTo(0x0800, 0x0400) else walkTo(0x0800, 0x0400) end
end
""", "downtown")
  var maxFr = frankPercent(snes)
  var maxBb = buzzBuzzPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"START pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) frank={maxFr} buzz={maxBb} knock={pokeyKnockPercent(snes)}"
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    # re-poke knock signature if game clears it during walk
    let ea = 0x7E0000 + KnockCompleteOff
    if snes.bus.mem[ea] != KnockCompleteVal.uint8:
      snes.bus.mem[ea] = KnockCompleteVal.uint8
    let fr = frankPercent(snes)
    let bb = buzzBuzzPercent(snes)
    if fr > maxFr: maxFr = fr
    if bb > maxBb: maxBb = bb
    if f mod 500 == 0:
      echo fmt"f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) frank={fr} maxF={maxFr} buzz={bb} joy=0x{ctx.joy1:04X} complete={knockComplete(snes)}"
    if maxFr >= 60: break
  echo fmt"FINAL max_frank={maxFr} max_buzz={maxBb} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  # save reached state for fixture
  if maxFr >= 40:
    let outp = "bin/states/llm/frank_corridor.state"
    let bytes = serializeState(snes, cpu)
    # ensure signature
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let bytes2 = serializeState(snes, cpu)
    writeFile(outp, cast[string](bytes2))
    echo "WROTE ", outp, " frank=", frankPercent(snes)

when isMainModule: main()
