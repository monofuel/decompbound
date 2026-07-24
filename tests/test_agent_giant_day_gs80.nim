## d94: giant_step soft 80 = day-open west band ($9887>=02) past night gs70.
## F12 corpus has no Giant Step cave indoor; product campaign seats day flag.
## Continuous night outdoor must stay gs70 (not invent day).

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  Giant = "bin/states/llm/giant_approach.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"

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
    holdKnock: bool; stopGs: int): tuple[maxGs, maxFr, walkSpan, teleports: int] =
  ## Drive AgentGiant; track peaks + honest walk.
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
  var lastPx = readU16(snes, WorldXBase + i).int
  var lastPy = readU16(snes, WorldYBase + i).int
  result.maxGs = giantStepPercent(snes)
  result.maxFr = frankPercent(snes)
  for f in 1 .. frames:
    clearSouthFreezeLocks(snes)
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if holdKnock:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      # $9887 is both knock-story (0x01) and day-open (0x02); do not clobber day.
      if dayStoryOpen(snes):
        applyDayStoryOpen(snes)
      else:
        snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    clearSouthFreezeLocks(snes)
    let px = readU16(snes, WorldXBase + i).int
    let py = readU16(snes, WorldYBase + i).int
    let ddx = abs(px - lastPx)
    let ddy = abs(py - lastPy)
    if ddx > 32 or ddy > 32:
      inc result.teleports
    else:
      result.walkSpan += ddx + ddy
    lastPx = px
    lastPy = py
    let gs = giantStepPercent(snes)
    let fr = frankPercent(snes)
    if gs > result.maxGs: result.maxGs = gs
    if fr > result.maxFr: result.maxFr = fr
    if stopGs > 0 and result.maxGs >= stopGs and f >= 800: break

proc main() =
  ## Night continuous gs70; day flag seats gs80; cave freewalk still open.
  doAssert fileExists(Rom) and fileExists(Giant)
  echo "POLICY=AgentGiantStepPolicy"
  echo "SPINE_REF=docs/checkpoints.md Titanic Ant / Giant Step"
  echo "NOTE gs80 = day-open west band; cave mouth F12 still needed for 100"

  # A: night giant fixture grades 70, not 80
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Giant)), snes, c)
    let gs = giantStepPercent(snes)
    let day = dayStoryOpen(snes)
    echo fmt"A_NIGHT_GIANT gs={gs} dayOpen={day} 9887=0x{readU8(snes,DayStoryByteOff):02X}"
    doAssert gs == 70, "night giant_approach is gs70 soft"
    doAssert not day, "night fixture must not have day-open byte"

  # B: day flag on giant west → gs80 grade
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Giant)), snes, c)
    applyDayStoryOpen(snes)
    let gs = giantStepPercent(snes)
    echo fmt"B_DAY_FLAG gs={gs} dayOpen={dayStoryOpen(snes)}"
    doAssert gs >= 80, "day-open west band grades giant_step 80"
    doAssert dayStoryOpen(snes)

  # C: leave_day1 day byte alone on giant (campaign seat style)
  if fileExists(LeaveMap):
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Giant)), snes, c)
    let day = newSnesBus(policy.readRomFile(Rom))
    var cd = day.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LeaveMap)), day, cd)
    snes.bus.mem[0x7E0000 + DayStoryByteOff] = readU8(day, DayStoryByteOff).uint8
    doAssert readU8(snes, DayStoryByteOff) >= DayStoryOpenVal
    echo fmt"C_LEAVE_DAY_BYTE gs={giantStepPercent(snes)} 9887=0x{readU8(snes,DayStoryByteOff):02X}"
    doAssert giantStepPercent(snes) >= 80

  # D: Agent hold on day-open giant seat (d96: must not collapse gs via Up thrash)
  block:
    var snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Giant)), snes, c)
    applyDayStoryOpen(snes)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    clearSouthFreezeLocks(snes)
    doAssert giantStepPercent(snes) >= 80
    let r = runPol(snes, c, AgentGiantStepPolicy, 4000, true, 0)
    let endGs = giantStepPercent(snes)
    echo fmt"D_AGENT_HOLD maxGs={r.maxGs} endGs={endGs} maxFr={r.maxFr} walk={r.walkSpan} tele={r.teleports}"
    doAssert r.maxGs >= 80, "Agent must hold day-open gs80 on giant seat"
    doAssert endGs >= 80, "d96 day-hold must not end below gs80 (Up thrash collapse)"
    # freewalk does not invent cave 100
    doAssert r.maxGs < 100

  # E: continuous night outdoor still peaks gs70 only (no day invent)
  if fileExists(Outdoor):
    var snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    if KnockStoryFlagOff != 0:
      snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    let fr = runPol(snes, c, AgentFrankPolicy, 6000, true, 0)
    echo fmt"E_FRANK maxFr={fr.maxFr}"
    doAssert fr.maxFr >= 80
    clearSouthFreezeLocks(snes)
    let gs = runPol(snes, c, AgentGiantStepPolicy, 6000, true, 70)
    echo fmt"E_NIGHT_CONT maxGs={gs.maxGs} dayOpen={dayStoryOpen(snes)}"
    doAssert gs.maxGs >= 70
    doAssert gs.maxGs < 80 or not dayStoryOpen(snes),
      "night continuous must not freewalk day-open gs80 without day flag"

  echo "PEAKS night_gs=70 day_gs=80 (cave freewalk RE open)"
  echo "OK test_agent_giant_day_gs80"

when isMainModule:
  main()
