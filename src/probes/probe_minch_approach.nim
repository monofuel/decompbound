## From buzz_meteor, walk toward Minch house outdoor for sunrise partial ladder RE.
import
  std/[os, strformat, tables, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene]

const FlagLo = 0x9880
const FlagHi = 0x9A20

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc snap(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in FlagLo ..< FlagHi:
    result[off] = readU8(snes, off)

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc main() =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/buzz_meteor.state")), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let base = snap(snes)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua &
    "\n" & AdvanceDialogueSkillLua, "sk")
  # Minch house is SW of Ness, west side of Onett — try west road then south
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
  -- talk nearby first at site
  local e = nearestEntity and nearestEntity() or nil
  if e ~= nil and e.dist_tiles and e.dist_tiles <= 3 then
    if talk and talk(e.slot) then return end
  end
  -- head SW toward Minch area (west road band ~0x0680,0x01F8 then further west)
  if followRoute and followRoute("crater_to_onett") then return end
  if px > 0x0700 then
    if walkTo then walkTo(0x06A0, 0x01F8) else pad.press("Left") end
    return
  end
  if py < 0x0220 then
    if walkTo then walkTo(0x0680, 0x0240) else pad.press("Down") end
    return
  end
  pad.press("Left")
end
""", "pol")
  var maxBb = buzzBuzzPercent(snes)
  var maxSu = sunrisePercent(snes)
  var maxPk = pokeyPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"START bb={maxBb} su={maxSu} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  for f in 1 .. 10000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    let bb = buzzBuzzPercent(snes)
    let su = sunrisePercent(snes)
    let pk = pokeyPercent(snes)
    if bb > maxBb: maxBb = bb
    if su > maxSu: maxSu = su
    if pk > maxPk: maxPk = pk
    if f mod 2000 == 0:
      echo fmt"f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) bb={bb} su={su} pk={pk} party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X}"
  echo fmt"FINAL maxbb={maxBb} maxsu={maxSu} maxpk={maxPk} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  let cur = snap(snes)
  var n = 0
  for off, va in base:
    let vb = cur.getOrDefault(off, va)
    if va != vb:
      if n < 30: echo fmt"  ${off:04X}: 0x{va:02X}->0x{vb:02X}"
      n.inc
  echo "flag diffs ", n
  writeFile("bin/states/llm/minch_approach_attempt.state", cast[string](serializeState(snes, cpu)))

when isMainModule: main()
