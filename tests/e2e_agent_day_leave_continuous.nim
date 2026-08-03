## Continuous outdoor → C4 leave soft → campaign day-leave freeplay.
## Night south wall unreproducible freewalk (probe_day_leave_freeplay).
## Day Y poke (0x0800,0x05B5) grades cs100/pr60 but teleports on night outdoor
## (d87 honest probe: walkSpan~0, tele≥1). Product freeplay is leave_day1_map
## (pr70, walk tele=0). checkpoints.md Captain leave / Peaceful Rest soft.

import
  std/[os],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"
  ## Grade-only band (teleports on night outdoor memory — not freeplay).
  DayLeaveX = 0x0800'u16
  DayLeaveY = 0x05B5'u16

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

proc skillsSrc(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    holdKnock: bool; stopCs, stopGs, stopFr: int):
    tuple[maxFr, maxGs, maxCs, maxPr, span, walkSpan, teleports: int] =
  ## Drive Agent policy; track bbox span + honest walk (no per-frame jumps >32).
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skillsSrc(), "skills")
  loadChunk(L, pol, "pol")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  var lastPx = minX.int
  var lastPy = minY.int
  result.maxFr = frankPercent(snes)
  result.maxGs = giantStepPercent(snes)
  result.maxCs = captainStrongPercent(snes)
  result.maxPr = peacefulRestPercent(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if holdKnock:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    else:
      applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let ddx = abs(px.int - lastPx)
    let ddy = abs(py.int - lastPy)
    if ddx > 32 or ddy > 32:
      inc result.teleports
    else:
      result.walkSpan += ddx + ddy
    lastPx = px.int
    lastPy = py.int
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    let cs = captainStrongPercent(snes)
    let pr = peacefulRestPercent(snes)
    if fr > result.maxFr: result.maxFr = fr
    if gs > result.maxGs: result.maxGs = gs
    if cs > result.maxCs: result.maxCs = cs
    if pr > result.maxPr: result.maxPr = pr
    if stopFr > 0 and result.maxFr >= stopFr and f >= 1500: break
    if stopGs > 0 and result.maxGs >= stopGs and f >= 1500: break
    if stopCs > 0 and result.maxCs >= stopCs and f >= 1500: break
  result.span = (maxX - minX).int + (maxY - minY).int

proc main() =
  ## Night wall closed; day Y grades only; leave_day1_map is honest freeplay.
  doAssert fileExists(Rom) and fileExists(Outdoor) and fileExists(LeaveMap)
  echo "POLICY=AgentFrank+Giant+Captain → C4 → grade seat → leave_map freeplay"
  echo "NOTE day Y poke teleports on night outdoor (d87); freeplay=leave_day1_map"
  echo "SPINE_REF=docs/checkpoints.md"

  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8

  let fr = runPol(snes, c, AgentFrankPolicy, 8000, true, 0, 0, 80)
  echo "FRANK maxFr=", fr.maxFr, " maxGs=", fr.maxGs
  doAssert fr.maxFr >= 80
  clearSouthFreezeLocks(snes)
  let gs = runPol(snes, c, AgentGiantStepPolicy, 8000, true, 0, 70, 0)
  echo "GIANT maxGs=", gs.maxGs
  doAssert gs.maxGs >= 70
  let cap = runPol(snes, c, AgentCaptainStrongPolicy, 8000, true, 60, 0, 0)
  echo "CAPTAIN maxCs=", cap.maxCs
  doAssert cap.maxCs >= 60

  applyLaterStoryLeaveSoft(snes)
  clearSouthFreezeLocks(snes)
  doAssert captainStrongPercent(snes) >= 70
  doAssert peacefulRestPercent(snes) >= 30
  echo "C4 soft cs=", captainStrongPercent(snes), " pr=", peacefulRestPercent(snes)

  # Grade-only day Y seat (teleports if freeplayed — do not claim mobility).
  let i = PlayerSlot * SlotIndexStride
  snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(DayLeaveX and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8(DayLeaveX shr 8)
  snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(DayLeaveY and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8(DayLeaveY shr 8)
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  applyLaterStoryLeaveSoft(snes)
  clearSouthFreezeLocks(snes)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. 20:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)
  let csSeat = captainStrongPercent(snes)
  let prSeat = peacefulRestPercent(snes)
  echo "DAY_SEAT_GRADE cs=", csSeat, " pr=", prSeat, " (grade only; not freeplay)"
  doAssert csSeat >= 100, "day-leave Y seat grades captain 100"
  doAssert prSeat >= 60, "day-leave Y opens peaceful_rest 60 (py>=0x0500)"

  # Honest freeplay: campaign leave_day1_map (F12 day leave map).
  snes = newSnesBus(policy.readRomFile(Rom))
  c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  doAssert peacefulRestPercent(snes) >= 70
  doAssert captainStrongPercent(snes) >= 100
  let pa = runPol(snes, c, AgentPaulaApproachPolicy, 6000, false, 0, 0, 0)
  echo "LEAVE_MAP maxPr=", pa.maxPr, " walk=", pa.walkSpan, " tele=", pa.teleports,
    " span=", pa.span
  doAssert pa.maxPr >= 70, "hold peaceful_rest 70 on leave_day1_map"
  doAssert pa.teleports == 0, "honest freeplay must not teleport"
  doAssert pa.walkSpan > 200, "honest walk mobility on leave map"

  echo "PEAKS outdoor_gs=", gs.maxGs, " night_cs=", cap.maxCs,
    " grade_pr=60 leave_pr=", pa.maxPr, " walk=", pa.walkSpan
  echo "OK test_agent_day_leave_continuous"

when isMainModule:
  main()
