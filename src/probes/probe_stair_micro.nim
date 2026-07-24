import std/[strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"
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
proc toSeat(): tuple[snes: SnesBus, c: Cpu] =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/onett_start.state")), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentOutdoorPolicy, "out")
  var home = false
  for f in 1 .. 12000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if pokeyPercent(snes) >= 100 and not home:
      loadChunk(L, skills, "sk2")
      loadChunk(L, AgentHomePolicy, "home")
      home = true
    if home and pokeyKnockPercent(snes) >= 70:
      for e in 1 .. 1500:
        ctx.frameCount = f+e
        discard policy.runPolicyFrame(L, ctx)
        snes.joy1 = ctx.joy1
        policy.stepOneFrame(snes, c, img)
      break
  result = (snes, c)
proc main() =
  let i = PlayerSlot * SlotIndexStride
  var t = toSeat()
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  echo fmt"seat (0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X})"
  # Down 20, Left 10, Up 300
  for _ in 1..30:
    t.snes.joy1 = 0x0400
    policy.stepOneFrame(t.snes, t.c, img)
  echo fmt"after Down (0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X})"
  for _ in 1..20:
    t.snes.joy1 = 0x0200
    policy.stepOneFrame(t.snes, t.c, img)
  echo fmt"after Left (0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X})"
  for n in 1..400:
    t.snes.joy1 = 0x0800
    policy.stepOneFrame(t.snes, t.c, img)
    if n mod 50 == 0:
      echo fmt"Up n={n} (0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X}) knock={pokeyKnockPercent(t.snes)}"
  for n in 1..400:
    t.snes.joy1 = 0x0100
    policy.stepOneFrame(t.snes, t.c, img)
    if n mod 50 == 0:
      echo fmt"Right n={n} (0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X}) knock={pokeyKnockPercent(t.snes)} room={currentRoomLabel(t.snes)}"
  echo "FINAL knock=", pokeyKnockPercent(t.snes)
main()
