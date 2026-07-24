## Pure Up from continuous indoor seat vs home_indoor seat.
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

proc toLiveIndoor(): tuple[snes: SnesBus, c: Cpu] =
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
      # run home a bit more to seat
      for e in 1 .. 800:
        ctx.frameCount = f+e
        discard policy.runPolicyFrame(L, ctx)
        snes.joy1 = ctx.joy1
        policy.stepOneFrame(snes, c, img)
      break
  result = (snes, c)

proc main() =
  let i = PlayerSlot * SlotIndexStride
  # Live
  var t = toLiveIndoor()
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  echo fmt"LIVE seat pos=(0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X}) 9877={readU8(t.snes,0x9877):#04x} win1={readU8(t.snes,0x8654):#04x}"
  for n in 1 .. 300:
    t.snes.joy1 = 0x0800
    policy.stepOneFrame(t.snes, t.c, img)
    if n mod 50 == 0:
      echo fmt"  LIVE Up n={n} pos=(0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X}) knock={pokeyKnockPercent(t.snes)}"

  # home_indoor forced to same coords after load
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/home_indoor.state")), snes, c)
  # move to 0x1D10,0x0175 by poking pos
  snes.bus.mem[0x7E0000 + WorldXBase+i] = 0x10
  snes.bus.mem[0x7E0000 + WorldXBase+i+1] = 0x1D
  snes.bus.mem[0x7E0000 + WorldYBase+i] = 0x75
  snes.bus.mem[0x7E0000 + WorldYBase+i+1] = 0x01
  echo fmt"FIXTURE poke seat pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  for n in 1 .. 300:
    snes.joy1 = 0x0800
    policy.stepOneFrame(snes, c, img)
    if n mod 50 == 0:
      echo fmt"  FIX Up n={n} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) knock={pokeyKnockPercent(snes)}"

  # home_indoor natural long left then up
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/home_indoor.state")), snes, c)
  for n in 1 .. 200:
    snes.joy1 = if (n mod 3)==0: 0x0400'u16 else: 0x0200'u16
    policy.stepOneFrame(snes, c, img)
  echo fmt"FIXTURE after DL pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  for n in 1 .. 300:
    snes.joy1 = 0x0800
    policy.stepOneFrame(snes, c, img)
    if n mod 50 == 0:
      echo fmt"  FIX2 Up n={n} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) knock={pokeyKnockPercent(snes)} room={currentRoomLabel(snes)}"
main()
