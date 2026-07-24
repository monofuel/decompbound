## After live pokey100, does pure pad.press move Ness? Compare fixture.
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

proc padTest(snes: SnesBus; c: var Cpu; tag: string; frames: int) =
  let i = PlayerSlot * SlotIndexStride
  let x0 = readU16(snes, WorldXBase+i)
  let y0 = readU16(snes, WorldYBase+i)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for f in 1 .. frames:
    snes.joy1 = 0x0400  # Right
    policy.stepOneFrame(snes, c, img)
  let x1 = readU16(snes, WorldXBase+i)
  let y1 = readU16(snes, WorldYBase+i)
  echo fmt"{tag} Right x{frames}: (0x{x0:04X},0x{y0:04X})->(0x{x1:04X},0x{y1:04X}) d={abs(x1-x0)+abs(y1-y0)}"
  # dump more control candidates
  for off in [0x5D52, 0x5D62, 0x9670, 0x9870, 0x4A00, 0x0B56, 0x0B58, 0x0B5A, 0x0B62,
              0x9652, 0x9654, 0x9656, 0x96C5, 0x9875, 0x9876, 0x9877, 0x9879, 0x987A, 0x987D]:
    echo fmt"  ${off:04X}={readU8(snes,off):#04x}"

proc main() =
  # Fixture pad test
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), snes, c)
    padTest(snes, c, "FIXTURE", 60)
  # Live
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
  for f in 1 .. 5000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if pokeyPercent(snes) >= 100:
      # extra frames to clear talk
      for e in 1 .. 200:
        ctx.frameCount = f+e
        discard policy.runPolicyFrame(L, ctx)
        snes.joy1 = ctx.joy1
        policy.stepOneFrame(snes, c, img)
      break
  padTest(snes, c, "LIVE_post_pokey", 60)
  # Try mashing A/B then move
  for f in 1 .. 120:
    snes.joy1 = if (f mod 4) < 2: 0x0080'u16 else: 0x8000'u16  # A/B alternate guess
    # use pad via policy
  loadChunk(L, """
function update()
  local f = frame() % 8
  if f < 2 then pad.press("A")
  elseif f < 4 then pad.press("B")
  elseif f < 6 then pad.press("Right")
  else pad.press("Down") end
end
""", "clear")
  for f in 1 .. 180:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
  padTest(snes, c, "LIVE_after_clear", 60)
  echo "OK probe_post_pokey_locomotion"
main()
