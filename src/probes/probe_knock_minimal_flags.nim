## Find minimal knock flag set: mobile + meteor reach + optional $9887.
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene]

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

proc runVariant(name: string; flags: seq[(int, int)]) =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/onett_start.state")), snes, cpu)
  for (off, val) in flags:
    snes.bus.mem[0x7E0000 + off] = uint8(val)
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua &
    "\n" & AdvanceDialogueSkillLua, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  local w0 = mem.read(0x8650)
  local w1 = mem.read(0x8654)
  if w0 ~= 0xFF or w1 ~= 0xFF then
    if advanceDialogue and advanceDialogue() then return end
    if (frame() % 6) < 3 then pad.press("A") else pad.press("B") end
    return
  end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local nearSite = (px >= 0x0800 and px <= 0x08D0 and py >= 0x00C0 and py <= 0x0130)
  if not nearSite then
    if followRoute and followRoute("onett_to_crater") then return end
    return
  end
  local e = nearestEntity and nearestEntity() or nil
  if e ~= nil and talk and talk(e.slot) then return end
  if (frame() % 8) < 3 then pad.press("A") end
end
""", "pol")
  var maxBb = buzzBuzzPercent(snes)
  var maxPk = pokeyPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 5000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    # reassert $99F2 if present in flags list
    for (off, val) in flags:
      if off == KnockCompleteOff:
        snes.bus.mem[0x7E0000 + off] = uint8(val)
    let bb = buzzBuzzPercent(snes)
    let pk = pokeyPercent(snes)
    if bb > maxBb: maxBb = bb
    if pk > maxPk: maxPk = pk
    if maxBb >= 90 and maxPk >= 80: break
  echo fmt"{name}: maxbb={maxBb} maxpk={maxPk} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) $9887={readU8(snes,0x9887):02X} indoor={readU16(snes,WorldXBase+i)>=0x1C00}"

proc main() =
  runVariant("99F2_only", @[(KnockCompleteOff, KnockCompleteVal)])
  runVariant("99F2+9887", @[(KnockCompleteOff, KnockCompleteVal), (0x9887, 0x01)])
  runVariant("99F2+9887+9A0F10", @[
    (KnockCompleteOff, KnockCompleteVal), (0x9887, 0x01),
    (0x9A0F, 0x00), (0x9A10, 0x00)])
  runVariant("99F2+9C_band", block:
    var f: seq[(int, int)] = @[(KnockCompleteOff, KnockCompleteVal)]
    # selective 9C flags from post_knock diff
    for (off, val) in [(0x9C09, 0x00), (0x9C11, 0x08), (0x9C13, 0x80), (0x9C14, 0x01),
                       (0x9C2D, 0x10), (0x9C36, 0x40), (0x9C42, 0x9C), (0x9C4A, 0x06),
                       (0x9C8A, 0x02), (0x9C8C, 0x10), (0x9C90, 0x80)]:
      f.add (off, val)
    f)

when isMainModule: main()
