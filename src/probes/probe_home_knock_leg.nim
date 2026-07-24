## Product home-leg only: AgentHomePolicy from pokey_done must climb knock 10→50+.
## Mirrors tests/test_agent_multileg leg B (same skills, no stuck recovery thrash).

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  PokeyDone = "bin/states/llm/pokey_done.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene() JSON for goHome landmarks.
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring)
  1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind landmarkTarget(name).
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc main() =
  ## Run AgentHomePolicy 8000 frames like the multileg unit test.
  doAssert fileExists(Rom) and fileExists(PokeyDone)
  doAssert "followRoute(" notin AgentHomePolicy,
    "Agent home seed body must not call followRoute directly"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(PokeyDone)), snes, cpu)
  let startK = pokeyKnockPercent(snes)
  let startPokey = pokeyPercent(snes)
  let startTg = touchGrassPercent(snes)
  echo fmt"START knock={startK} pokey={startPokey} tg={startTg} " &
    fmt"POLICY=AgentHomePolicy body_len={AgentHomePolicy.len}"
  doAssert startK <= 30, "pokey_done early home leg expected"

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
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "skills")
  loadChunk(L, AgentHomePolicy, "home")

  var maxK = startK
  var maxPokey = startPokey
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let k = pokeyKnockPercent(snes)
    let p = pokeyPercent(snes)
    if k > maxK: maxK = k
    if p > maxPokey: maxPokey = p
    if f mod 2000 == 0:
      let px = readU16(snes, WorldXBase + i)
      let py = readU16(snes, WorldYBase + i)
      echo fmt"f={f} knock={k} maxK={maxK} pokey={p} pos=(0x{px:04X},0x{py:04X})"
    if maxK >= 80:
      echo fmt"HOME_LEG_ACHIEVED f={f} max_knock={maxK}"
      break

  echo fmt"FINAL max_knock={maxK} knock={pokeyKnockPercent(snes)} " &
    fmt"pokey={pokeyPercent(snes)} tg={touchGrassPercent(snes)}"
  echo "DELTA knock ", startK, "->", maxK
  echo "  ", checkpointSpineLine(snes)
  doAssert maxK >= 80,
    "AgentHomePolicy product path must reach knock>=80 bedroom (got max " & $maxK &
    " start=" & $startK & ")"
  echo "OK probe_home_knock_leg: knock ", startK, "→", maxK

when isMainModule:
  main()
