## Continuous: onett_start outdoor→home knock80, then bed A for knock100/day flags.
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
  var home = false
  var maxK = 0
  var maxSun = 0
  var maxBuzz = 0
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 30000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let k = pokeyKnockPercent(snes)
    let sun = sunrisePercent(snes)
    let bz = buzzBuzzPercent(snes)
    if k > maxK: maxK = k
    if sun > maxSun: maxSun = sun
    if bz > maxBuzz: maxBuzz = bz
    if pokeyPercent(snes) >= 100 and not home:
      loadChunk(L, skills, "sk2")
      loadChunk(L, AgentHomePolicy, "home")
      home = true
      echo "HANDOFF home f=", f
    if f mod 2000 == 0 or maxK >= 100 or maxSun >= 50:
      echo fmt"f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
        fmt"knock={k} maxK={maxK} sun={sun} maxSun={maxSun} buzz={bz} maxBuzz={maxBuzz} " &
        fmt"room={currentRoomLabel(snes)} 99F2={readU8(snes,0x99F2):#04x} win1={readU8(snes,0x8654):#04x}"
    if maxK >= 100: break
  echo "FINAL maxK=", maxK, " maxSun=", maxSun, " maxBuzz=", maxBuzz,
    " knockComplete=", knockComplete(snes), " room=", currentRoomLabel(snes)
  echo "OK probe_continuous_bed_sleep"
main()
