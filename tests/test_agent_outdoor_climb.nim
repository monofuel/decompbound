## Free outdoor pokey climb from onett_start: AgentOutdoorPolicy + goToMeteor
## must reach site (pokey 80+) without campaign loads or trail-only body.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/onett_start.state"
  MaxFrames = 8000

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene() for intent skills.
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring)
  1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind landmarkTarget for goToward / goToMeteor fallbacks.
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc main() =
  ## Product outdoor body must climb pokey 10 → 80+ from house door.
  doAssert fileExists(Rom)
  doAssert fileExists(Outdoor), "need onett_start fixture"
  doAssert "followRoute(" notin AgentOutdoorPolicy,
    "AgentOutdoorPolicy body must not call followRoute (use goToMeteor skill)"
  doAssert "goToMeteor" in AgentOutdoorPolicy,
    "AgentOutdoorPolicy should call goToMeteor intent skill"

  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, cpu)
  let startP = pokeyPercent(snes)
  echo "START pokey=", startP, " POLICY=AgentOutdoorPolicy"
  doAssert startP < 50, "onett_start should be near door (pokey low)"

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua)
  L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua)
  L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "skills")
  doAssert "function goToMeteor" in IntentNavSkillLua & NamedRoutesLua or
    "function goToMeteor" in IntentNavSkillLua,
    "goToMeteor must exist in skill library"
  loadChunk(L, AgentOutdoorPolicy, "outdoor")

  var maxP = startP
  for f in 1 .. MaxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let p = pokeyPercent(snes)
    if p > maxP:
      maxP = p
    if maxP >= 100:
      break
    if maxP >= 80 and f >= 2500:
      break

  echo "FINAL max_pokey=", maxP, " frames=", ctx.frameCount
  doAssert maxP >= 80,
    "outdoor free climb must hit meteor site (pokey 80+); got " & $maxP
  echo "OK test_agent_outdoor_climb: onett_start pokey ", startP, "->", maxP

when isMainModule:
  main()
