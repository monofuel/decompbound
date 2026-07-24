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
proc dumpCtrl(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"{tag}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"knock={pokeyKnockPercent(snes)} pokey={pokeyPercent(snes)} " &
    fmt"win0={readU8(snes,0x8650):#04x} win1={readU8(snes,0x8654):#04x} " &
    fmt"arm={readU8(snes,0x9885):#04x} $99F2={readU8(snes,0x99F2):#04x} " &
    fmt"$5D98={readU8(snes,0x5D98):#04x} room={currentRoomLabel(snes)}"
proc main() =
  # fixture
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), snes, c)
    dumpCtrl(snes, "FIXTURE_pokey_done")
  # live outdoor
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
  for f in 1 .. 4000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if pokeyPercent(snes) >= 100: break
  dumpCtrl(snes, "LIVE_after_pokey100")
  # mash B a bit
  for f in 1 .. 60:
    snes.joy1 = 0x8000 # B?
    # use policy pad B
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  pad.press("B")
end
""", "b")
  for f in 1 .. 90:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
  dumpCtrl(snes, "LIVE_after_B_mash")
  loadChunk(L, AgentHomePolicy, "home")
  var maxK = pokeyKnockPercent(snes)
  for f in 1 .. 6000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let k = pokeyKnockPercent(snes)
    if k > maxK: maxK = k
    if maxK >= 80: break
  dumpCtrl(snes, "LIVE_after_home")
  echo "max_knock=", maxK
main()
