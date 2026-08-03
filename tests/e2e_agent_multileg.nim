## Multi-leg Agent product seeds (no followRoute outdoor body):
## 1) AgentHouseExitPolicy: bedroom -> tg=100
## 2) AgentHomePolicy: pokey_done (knock=10) -> knock increases
## Drives shipped seeds + skills from touch_grass / llm_mock_policies.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  Bedroom = "bin/states/llm/bedroom.state"
  PokeyDone = "bin/states/llm/pokey_done.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk that defines globals.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene() for intent skills.
  let ctx = policy.getPolicyCtx(L)
  L.pushstring(scene.sceneJson(ctx.snes).cstring)
  1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind landmarkTarget(name) -> x,y like llm_ai.
  let ctx = policy.getPolicyCtx(L)
  let t = scene.landmarkTarget(ctx.snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc runPolicy(snes: SnesBus, cpu: var Cpu, policySrc: string, maxFrames: int): tuple[tg, pokey, knock: int] =
  ## Run a shipped Agent seed for maxFrames; return final percents.
  # Policy body must not be a trail-only script; goHome() may use routes inside the skill.
  doAssert "followRoute(" notin policySrc,
    "Agent product seed body must not call followRoute(...) directly"
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
  # Full skill stack including named routes (goHome may use crater_to_onett engine route).
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "skills")
  loadChunk(L, policySrc, "agent_seed")
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
  result = (
    touchGrassPercent(snes),
    pokeyPercent(snes),
    pokeyKnockPercent(snes))

proc main() =
  ## Prove multi-leg Agent seeds move story metrics without trail-only bodies.
  doAssert fileExists(DefaultRom)
  doAssert fileExists(Bedroom)
  doAssert fileExists(PokeyDone)

  # Leg A: house exit
  block:
    let snes = newSnesBus(policy.readRomFile(DefaultRom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Bedroom)), snes, cpu)
    let startTg = touchGrassPercent(snes)
    doAssert startTg == 25, "bedroom fixture expected tg=25"
    let fin = runPolicy(snes, cpu, AgentHouseExitPolicy, 4000)
    echo "multileg house_exit: start_tg=", startTg, " final_tg=", fin.tg
    doAssert fin.tg >= 100, "AgentHouseExitPolicy must reach outside (tg=100), got " & $fin.tg

  # Leg B: head home from post-Pokey crater
  block:
    let snes = newSnesBus(policy.readRomFile(DefaultRom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(PokeyDone)), snes, cpu)
    let startK = pokeyKnockPercent(snes)
    doAssert startK <= 30, "pokey_done should be early home leg, knock=" & $startK
    let fin = runPolicy(snes, cpu, AgentHomePolicy, 14000)
    echo "multileg head_home: start_knock=", startK, " final_knock=", fin.knock,
      " pokey=", fin.pokey, " tg=", fin.tg
    doAssert fin.knock > startK,
      "AgentHomePolicy must increase pokey_knock_pct (start=" & $startK &
      " final=" & $fin.knock & ")"
    doAssert fin.knock >= 80,
      "AgentHomePolicy must reach bedroom knock>=80 (got " & $fin.knock & ")"

  echo "OK test_agent_multileg: house exit + head home Agent seeds advanced metrics"

when isMainModule:
  main()
