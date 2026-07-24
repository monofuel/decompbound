## Drive flag-merge post_knock outdoor to meteor; log metrics, dialogue, flag diffs.
import
  std/[os, strformat, strutils, tables, osproc],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene]

const
  FlagLo = 0x9880
  FlagHi = 0xA000

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc snapshotFlags(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in FlagLo ..< FlagHi:
    result[off] = readU8(snes, off)

proc diffFlags(a, b: Table[int, int]): seq[string] =
  result = @[]
  for off, va in a:
    let vb = b.getOrDefault(off, va)
    if va != vb:
      result.add fmt"${off:04X}: 0x{va:02X}->0x{vb:02X}"

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc main() =
  # ensure fresh flag-merge outdoor
  let (so, sc) = execCmdEx("nim r -d:release src/probes/synth_post_knock_outdoor.nim")
  echo so
  doAssert sc == 0
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/post_knock_outdoor.state")), snes, cpu)
  let base = snapshotFlags(snes)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua &
    "\n" & AdvanceDialogueSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle and inBattle() then
    if winBattle then winBattle() end
    return
  end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local w0 = mem.read(0x8650)
  local w1 = mem.read(0x8654)
  -- Any open window: advance hard (A/B alternate)
  if w0 ~= 0xFF or w1 ~= 0xFF then
    if advanceDialogue and advanceDialogue() then return end
    if (frame() % 6) < 3 then pad.press("A") else pad.press("B") end
    return
  end
  local nearSite = (px >= 0x0800 and px <= 0x08D0 and py >= 0x00C0 and py <= 0x0130)
  if not nearSite then
    if followRoute and followRoute("onett_to_crater") then return end
    if goToward and goToward("meteor_crater") then return end
    pad.press("Up")
    return
  end
  -- At site: talk any nearby NPC (Buzz/Picky/cops), not only non-pokey
  local e = nearestEntity and nearestEntity() or nil
  if e ~= nil and e.dist_tiles and e.dist_tiles <= 4 then
    if talk and talk(e.slot) then return end
  end
  if (frame() % 10) < 4 then pad.press("A")
  elseif (frame() % 10) < 7 then pad.press("Up")
  else pad.press("Left") end
end
""", "pol")
  var maxBb = buzzBuzzPercent(snes)
  var maxPk = pokeyPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"START $9887={readU8(snes,0x9887):02X} bb={maxBb} party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X}"
  var dumpedScene = false
  for f in 1 .. 12000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    # keep knock if game clears — but prefer natural
    if not knockComplete(snes):
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let bb = buzzBuzzPercent(snes)
    let pk = pokeyPercent(snes)
    if bb > maxBb: maxBb = bb
    if pk > maxPk: maxPk = pk
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    let nearSite = px >= 0x0800 and px <= 0x08D0 and py >= 0x00C0 and py <= 0x0130
    if nearSite and not dumpedScene:
      dumpedScene = true
      echo "AT_SITE f=", f, " scene=", scene.sceneJson(snes)[0 .. min(500, scene.sceneJson(snes).len-1)]
    if f mod 1500 == 0 or (nearSite and f mod 400 == 0):
      echo fmt"f={f} pos=(0x{px:04X},0x{py:04X}) bb={bb} maxbb={maxBb} pk={pk} party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X} $9885={readU8(snes,0x9885):02X} $9887={readU8(snes,0x9887):02X} w0={readU8(snes,0x8650):02X} w1={readU8(snes,0x8654):02X}"
  let d = diffFlags(base, snapshotFlags(snes))
  echo fmt"FINAL maxbb={maxBb} maxpk={maxPk} party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  echo "flag diffs ", d.len
  for line in d:
    if line.contains("988") or line.contains("99") or line.contains("9A") or line.contains("9C") or line.contains("9E"):
      echo "  ", line
  writeFile("bin/states/llm/buzz_meteor_attempt.state", cast[string](serializeState(snes, cpu)))
  echo "WROTE buzz_meteor_attempt bb=", buzzBuzzPercent(snes)

when isMainModule:
  main()
