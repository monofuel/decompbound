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

proc main() =
  # From home_indoor fixture: AgentHome
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/home_indoor.state")), snes, c)
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
    var maxK = 70
    for f in 1 .. 4000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
      let k = pokeyKnockPercent(snes)
      if k > maxK: maxK = k
      if f mod 200 == 0 or maxK >= 80:
        echo fmt"indoor f={f} joy=0x{ctx.joy1:04X} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) max={maxK}"
      if maxK >= 80: break
    echo "home_indoor AgentHome maxK=", maxK

  # Pure long left from home_indoor
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/home_indoor.state")), snes, c)
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let i = PlayerSlot * SlotIndexStride
    for n in 1 .. 400:
      snes.joy1 = 0x0200
      policy.stepOneFrame(snes, c, img)
      if n mod 50 == 0:
        echo fmt"Left n={n} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
    for n in 1 .. 400:
      snes.joy1 = 0x0800
      policy.stepOneFrame(snes, c, img)
      if n mod 50 == 0:
        echo fmt"Up n={n} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) knock={pokeyKnockPercent(snes)}"
main()
