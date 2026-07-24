## Late spine soft hold: soft98 seat AgentLate holds monotoli/summers/deep_darkness/stonehenge/magicant.
import
  std/[os],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Soft = "bin/states/llm/soft98_from_fo80paula.state"

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
  doAssert fileExists(Rom) and fileExists(Soft)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Soft)), snes, cpu)
  echo "START ", checkpointSpineLine(snes)
  doAssert monotoliPercent(snes) >= 70
  doAssert summersPercent(snes) >= 70
  doAssert deepDarknessPercent(snes) >= 80
  doAssert stonehengePercent(snes) >= 80
  doAssert magicantPercent(snes) >= 98
  doAssert hasAllSanctuarySoft(snes)
  doAssert not hasMagicantDreamFlag(snes)

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentLateGamePolicy, "late")
  var minDd = deepDarknessPercent(snes)
  var minMa = magicantPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase+i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase+i)
  var maxY = minY
  for f in 1 .. 3500:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    applyLaterStoryLeaveSoft(snes)
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    let dd = deepDarknessPercent(snes)
    let ma = magicantPercent(snes)
    if dd < minDd: minDd = dd
    if ma < minMa: minMa = ma
  let span = (maxX-minX)+(maxY-minY)
  echo "HOLD min_dd=", minDd, " min_ma=", minMa, " span=", span
  echo "END ", checkpointSpineLine(snes)
  doAssert minDd >= 60, "late freeplay should not drop deep_darkness below 60"
  doAssert minMa >= 90, "late freeplay should hold magicant soft high"
  doAssert span > 16
  echo "OK test_agent_late_spine_hold"

when isMainModule:
  main()
