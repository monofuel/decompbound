## Free knock 50→80 (and 10→80): AgentHomePolicy door enter + bedroom without
## campaign loads. Product body must not call followRoute.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  DoorPost = "bin/states/llm/home_door_postmeteor.state"
  Door = "bin/states/llm/home_door.state"
  PokeyDone = "bin/states/llm/pokey_done.state"
  MaxFrames = 14000

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene() for goHome landmarks.
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring)
  1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind landmarkTarget for goToward fallbacks.
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc runHome(path: string; minStart, minFinal: int): int =
  ## Run AgentHomePolicy; return max knock.
  doAssert fileExists(path), "missing " & path
  doAssert "followRoute(" notin AgentHomePolicy,
    "AgentHomePolicy product body must not call followRoute"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let startK = pokeyKnockPercent(snes)
  echo "START path=", path, " knock=", startK
  doAssert startK >= minStart,
    "start knock too low (got " & $startK & " need>=" & $minStart & ")"

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
  loadChunk(L, AgentHomePolicy, "home")

  var maxK = startK
  for f in 1 .. MaxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let k = pokeyKnockPercent(snes)
    if k > maxK:
      maxK = k
    if maxK >= minFinal:
      break

  echo "FINAL path=", path, " max_knock=", maxK, " room=",
    currentRoomLabel(snes), " frames=", ctx.frameCount
  doAssert maxK >= minFinal,
    "AgentHome must reach knock>=" & $minFinal & " (got " & $maxK & ") from " & path
  result = maxK

proc main() =
  ## Door 50→80 and full product pokey_done 10→80.
  doAssert fileExists(Rom)
  if fileExists(DoorPost):
    discard runHome(DoorPost, 40, 80)
  elif fileExists(Door):
    discard runHome(Door, 40, 80)
  else:
    raise newException(IOError, "need home_door_postmeteor or home_door")
  if fileExists(PokeyDone):
    discard runHome(PokeyDone, 0, 80)
  echo "OK test_agent_knock_bed: free knock door→bedroom 80"

when isMainModule:
  main()
