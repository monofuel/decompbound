## Live outdoor→pokey100, peel south off Pokey, then AgentHome.
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

proc main() =
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
  let i = PlayerSlot * SlotIndexStride
  var maxP = 0
  for f in 1 .. 5000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    maxP = max(maxP, pokeyPercent(snes))
    if maxP >= 100:
      for e in 1 .. 120:
        ctx.frameCount = f+e
        discard policy.runPolicyFrame(L, ctx)
        snes.joy1 = ctx.joy1
        policy.stepOneFrame(snes, c, img)
      break
  echo fmt"after talk pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) pokey={pokeyPercent(snes)}"
  # peel south
  for _ in 1 .. 80:
    snes.joy1 = 0x0400
    policy.stepOneFrame(snes, c, img)
  echo fmt"after peel pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  # also try west peel if south failed
  if readU16(snes, WorldYBase+i) < 0x0118:
    for _ in 1 .. 80:
      snes.joy1 = 0x0200
      policy.stepOneFrame(snes, c, img)
    echo fmt"after west pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"

  loadChunk(L, skills, "sk2")
  loadChunk(L, AgentHomePolicy, "home")
  var maxK = pokeyKnockPercent(snes)
  for f in 1 .. 12000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let k = pokeyKnockPercent(snes)
    if k > maxK: maxK = k
    if f mod 1000 == 0:
      echo fmt"f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) knock={k} maxK={maxK}"
    if maxK >= 80: break
  echo "FINAL maxK=", maxK, " room=", currentRoomLabel(snes)
  if maxK >= 80: echo "OK peel_south_home"
  else: echo "FAIL peel_south_home"
main()
