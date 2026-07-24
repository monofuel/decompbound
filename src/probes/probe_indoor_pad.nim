## After continuous door enter: pure pad deltas + try walk paths to stairs.
import std/[os, strformat], pixie
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

proc toIndoor(): tuple[snes: SnesBus, c: Cpu] =
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
      break
  result = (snes, c)

proc padD(snes: SnesBus; c: var Cpu; bit: uint16; n: int): int =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  let x0 = readU16(snes, WorldXBase+i)
  let y0 = readU16(snes, WorldYBase+i)
  for _ in 1 .. n:
    snes.joy1 = bit
    policy.stepOneFrame(snes, c, img)
  abs(readU16(snes, WorldXBase+i).int - x0.int) + abs(readU16(snes, WorldYBase+i).int - y0.int)

proc main() =
  for (name, bit) in [("R", 0x0100'u16), ("L", 0x0200'u16), ("D", 0x0400'u16), ("U", 0x0800'u16)]:
    var t = toIndoor()
    let i = PlayerSlot * SlotIndexStride
    echo fmt"start pos=(0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X}) $9877={readU8(t.snes,0x9877):#04x}"
    # clear bit0
    let v = readU8(t.snes, 0x9877)
    t.snes.bus.mem[0x7E0000 + 0x9877] = uint8(v and 0xFE)
    echo fmt"  {name} d={padD(t.snes, t.c, bit, 40)} pos=(0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X})"

  # Script: Down x40, Left x120, Up x200
  var t = toIndoor()
  let i = PlayerSlot * SlotIndexStride
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  echo fmt"script start (0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X})"
  for _ in 1 .. 40:
    t.snes.joy1 = 0x0400
    policy.stepOneFrame(t.snes, t.c, img)
  echo fmt" after Down (0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X})"
  for _ in 1 .. 150:
    t.snes.joy1 = 0x0200
    policy.stepOneFrame(t.snes, t.c, img)
  echo fmt" after Left (0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X})"
  for _ in 1 .. 300:
    t.snes.joy1 = 0x0800
    policy.stepOneFrame(t.snes, t.c, img)
  echo fmt" after Up knock={pokeyKnockPercent(t.snes)} (0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X}) room={currentRoomLabel(t.snes)}"

  # Try walkTo stairs via AgentHome from home_indoor fixture if exists
  for path in ["bin/states/llm/home_indoor.state", "bin/states/llm/home_downstairs_night.state",
               "bin/states/llm/home_natural_entry.state"]:
    if not fileExists(path): continue
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(path)), snes, c)
    echo fmt"{path.splitPath.tail} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) knock={pokeyKnockPercent(snes)}"
main()
