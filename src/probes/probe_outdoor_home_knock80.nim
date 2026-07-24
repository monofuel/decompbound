## Continuous product: onett_start AgentOutdoor → pokey100 then AgentHome → knock80.
import std/[os, strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"
const Path = "bin/states/llm/onett_start.state"
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
  deserializeState(cast[seq[byte]](readFile(Path)), snes, c)
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
  var maxP = pokeyPercent(snes)
  var maxK = pokeyKnockPercent(snes)
  var home = false
  for f in 1 .. 24000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let p = pokeyPercent(snes)
    let k = pokeyKnockPercent(snes)
    if p > maxP: maxP = p
    if k > maxK: maxK = k
    if maxP >= 100 and not home:
      # Reload skills so trail/talk state from outdoor climb is cleared.
      loadChunk(L, skills, "sk_re")
      loadChunk(L, AgentHomePolicy, "home")
      home = true
      echo "HANDOFF home at f=", f, " max_pokey=", maxP
    if f mod 2000 == 0:
      let i = PlayerSlot * SlotIndexStride
      let px = readU16(snes, WorldXBase + i)
      let py = readU16(snes, WorldYBase + i)
      echo fmt"f={f} pokey={p} maxP={maxP} knock={k} maxK={maxK} " &
        fmt"pos=(0x{px:04X},0x{py:04X}) room={currentRoomLabel(snes)} home={home}"
    if maxK >= 80: break
  echo "FINAL max_pokey=", maxP, " max_knock=", maxK, " home=", home
  doAssert maxP >= 100, "need pokey 100 first"
  doAssert maxK >= 80, "continuous outdoor→home must hit knock 80"
  echo "OK probe_outdoor_home_knock80"
main()
