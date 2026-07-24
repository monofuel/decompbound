## Continuous to indoor then dump path; compare home_door_postmeteor indoor walk.
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
  # postmeteor path
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/home_door_postmeteor.state")), snes, c)
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
    let L = lua53.newstate()
    L.openSandbox(); policy.setupPolicyApi(L, ctx)
    L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
    L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
    let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
      NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
    loadChunk(L, skills, "sk")
    loadChunk(L, AgentHomePolicy, "home")
    let i = PlayerSlot * SlotIndexStride
    var maxK = pokeyKnockPercent(snes)
    echo fmt"postmeteor start pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
    for f in 1 .. 3000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
      let k = pokeyKnockPercent(snes)
      if k > maxK: maxK = k
      let px = readU16(snes, WorldXBase+i)
      let py = readU16(snes, WorldYBase+i)
      if px >= 0x1C00 and (f mod 100 == 0 or maxK >= 80 or f < 1300 and f > 1100):
        echo fmt"PM f={f} joy=0x{ctx.joy1:04X} pos=(0x{px:04X},0x{py:04X}) knock={k} max={maxK}"
      if maxK >= 80:
        echo fmt"PM hit 80 f={f} pos=(0x{px:04X},0x{py:04X})"
        break
    echo "PM FINAL maxK=", maxK

  # live continuous
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
  let i = PlayerSlot * SlotIndexStride
  var maxK = 0
  var indoorF = 0
  for f in 1 .. 20000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let k = pokeyKnockPercent(snes)
    if k > maxK: maxK = k
    if pokeyPercent(snes) >= 100 and not home:
      loadChunk(L, skills, "sk2")
      loadChunk(L, AgentHomePolicy, "home")
      home = true
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    if home and px >= 0x1C00:
      indoorF.inc
      if indoorF <= 20 or indoorF mod 100 == 0 or maxK >= 80:
        echo fmt"LV f={f} in={indoorF} joy=0x{ctx.joy1:04X} pos=(0x{px:04X},0x{py:04X}) knock={k} max={maxK}"
    if maxK >= 80: break
  echo fmt"LV FINAL maxK={maxK} room={currentRoomLabel(snes)} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
main()
