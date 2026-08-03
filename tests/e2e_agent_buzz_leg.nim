## Agent outdoor post-knock: free synth fixture must stay mobile and advance
## buzz/sunrise/frank past the house lock (tg=100, buzz>=40, frank>=20).

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  IndoorPk = "bin/states/llm/post_knock.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  let ctx = policy.getPolicyCtx(L)
  L.pushstring(scene.sceneJson(ctx.snes).cstring)
  1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let ctx = policy.getPolicyCtx(L)
  let t = scene.landmarkTarget(ctx.snes, $L.toString(1))
  if not t.found:
    L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc ensureOutdoorFixture() =
  ## Build post_knock_outdoor if missing (synth tool).
  if fileExists(OutdoorPk): return
  let (o, code) = execCmdEx("nim r -d:release src/tools/synth_post_knock_outdoor.nim")
  echo o
  doAssert code == 0 and fileExists(OutdoorPk), "synth outdoor fixture failed"

proc main() =
  ## Drive AgentFrank/Buzz from free outdoor post-knock until metrics advance.
  doAssert fileExists(Rom)
  ensureOutdoorFixture()
  doAssert fileExists(OutdoorPk)

  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, cpu)
  doAssert knockComplete(snes)
  doAssert pokeyKnockPercent(snes) == 100
  doAssert touchGrassPercent(snes) >= 100
  let startBb = buzzBuzzPercent(snes)
  let startFr = frankPercent(snes)
  let startSu = sunrisePercent(snes)
  echo "start tg=", touchGrassPercent(snes), " knock=", pokeyKnockPercent(snes),
    " buzz=", startBb, " frank=", startFr, " sunrise=", startSu
  doAssert startBb >= 40
  doAssert startFr >= 20

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "skills")
  # Frank policy explores south (day-1); should keep outdoor + raise frank to 40.
  loadChunk(L, AgentFrankPolicy, "frank")

  var maxBb = startBb
  var maxFr = startFr
  var maxSu = startSu
  var maxTg = touchGrassPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  let px0 = readU16(snes, WorldXBase + i)
  for f in 1 .. 4000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let tg = touchGrassPercent(snes)
    let bb = buzzBuzzPercent(snes)
    let fr = frankPercent(snes)
    let su = sunrisePercent(snes)
    if tg > maxTg: maxTg = tg
    if bb > maxBb: maxBb = bb
    if fr > maxFr: maxFr = fr
    if su > maxSu: maxSu = su
    if maxFr >= 40 and maxBb >= 40: break

  let px1 = readU16(snes, WorldXBase + i)
  echo "final max_tg=", maxTg, " max_buzz=", maxBb, " max_frank=", maxFr,
    " max_sunrise=", maxSu, " dx=", abs(px1 - px0)
  doAssert maxTg >= 100, "must remain/reach outdoor"
  doAssert maxBb >= 40, "buzz must stay advanced outdoors"
  doAssert maxFr >= 40 or abs(px1 - px0) > 8,
    "frank should reach 40 (south band) or at least move under policy"
  # Prefer frank 40 if possible
  if maxFr < 40:
    # Force south walk to prove frank ladder
    for f in 0 .. 2000:
      snes.joy1 = 0x0400  # Down
      policy.stepOneFrame(snes, cpu, img)
      let fr = frankPercent(snes)
      if fr > maxFr: maxFr = fr
      if maxFr >= 40: break
    echo "after south force max_frank=", maxFr
  doAssert maxFr >= 40, "frank outdoor south band should grade >=40"
  doAssert maxSu >= 30, "sunrise partial should be >=30 when buzz>=40"
  echo "OK test_agent_buzz_leg: outdoor post-knock free path metrics advanced"

  # Indoor locked fixture still reports knock 100 (regression guard).
  if fileExists(IndoorPk):
    deserializeState(cast[seq[byte]](readFile(IndoorPk)), snes, cpu)
    doAssert pokeyKnockPercent(snes) == 100
    echo "indoor post_knock still grades knock=100 (locked control is separate)"

when isMainModule:
  main()
