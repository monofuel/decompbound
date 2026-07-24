## AgentFrankPolicy from buzz_meteor (campaign handoff case).
import std/[os, strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"
const Path = "bin/states/llm/buzz_meteor.state"
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
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  echo "START frank=", frankPercent(snes), " POLICY=AgentFrankPolicy"
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentFrankPolicy, "frank")
  var maxFr = frankPercent(snes)
  var maxCs = captainStrongPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 10000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let fr = frankPercent(snes); let cs = captainStrongPercent(snes)
    if fr > maxFr: maxFr = fr
    if cs > maxCs: maxCs = cs
    if f mod 2000 == 0:
      let px = readU16(snes, WorldXBase+i); let py = readU16(snes, WorldYBase+i)
      echo fmt"f={f} frank={fr} max={maxFr} cs={cs} max_cs={maxCs} pos=(0x{px:04X},0x{py:04X}) joy={ctx.joy1:#06x}"
    if maxFr >= 80 and maxCs >= 60: break
  echo "FINAL max_frank=", maxFr, " max_cs=", maxCs
  echo "OK probe_frank_from_buzz"
main()
