## Monotoli / Summers soft referees after Fourside (checkpoints.md).
## fo60_from_paula grades mo50/su40; fo80_from_paula AgentLate holds mo70/su90.

import
  std/[os],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fo60 = "bin/states/llm/fourside60_from_paula.state"
  Fo80 = "bin/states/llm/fourside80_from_paula.state"

proc loadChunk(L: lua53.PState; src, label: string) =
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
  ## Grade seats + short AgentLate hold on fo80.
  doAssert fileExists(Rom)
  doAssert fileExists(Fo60) and fileExists(Fo80)

  var snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo60)), snes, cpu)
  echo "FO60 mo=", monotoliPercent(snes), " su=", summersPercent(snes),
    " fo=", foursidePercent(snes)
  doAssert monotoliPercent(snes) >= 50
  doAssert summersPercent(snes) >= 40
  doAssert monotoliPercent(snes) < 70, "fo60 without Poo is not monotoli 70"

  snes = newSnesBus(policy.readRomFile(Rom))
  cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo80)), snes, cpu)
  let mo0 = monotoliPercent(snes)
  let su0 = summersPercent(snes)
  echo "FO80_START mo=", mo0, " su=", su0, " spine=", checkpointSpineLine(snes)
  doAssert mo0 >= 70 and su0 >= 70

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
  loadChunk(L, AgentLateGamePolicy, "late")
  var maxMo = mo0
  var maxSu = su0
  var maxMa = magicantPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  for f in 1 .. 4000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    applyLaterStoryLeaveSoft(snes)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    let mo = monotoliPercent(snes)
    let su = summersPercent(snes)
    let ma = magicantPercent(snes)
    if mo > maxMo: maxMo = mo
    if su > maxSu: maxSu = su
    if ma > maxMa: maxMa = ma
  let span = (maxX - minX) + (maxY - minY)
  echo "FO80_HOLD max_mo=", maxMo, " max_su=", maxSu, " max_ma=", maxMa, " span=", span
  doAssert maxMo >= 70 and maxSu >= 70
  doAssert span > 16, "fo80 late freeplay mobile"
  echo "OK test_agent_monotoli_summers"

when isMainModule:
  main()
