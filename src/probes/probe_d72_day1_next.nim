## d72: next unfinished soft day-1 segment — Giant cave hunt + Captain leave continuous.
## Intent/scene policies only; metric deltas + indoor/day flag RE under SCRATCH.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  Giant = "bin/states/llm/giant_approach.state"
  LeaveNo = "bin/states/llm/leave_day1_noparty.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"
  Arcade = "bin/states/llm/frank_arcade.state"
  Captain = "bin/states/llm/captain_approach.state"

proc loadChunk(L: lua53.PState; src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc grade(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  echo fmt"GRADE {tag} pos=(0x{px:04X},0x{py:04X}) indoor={px >= OutdoorMaxX} " &
    fmt"fr={frankPercent(snes)} gs={giantStepPercent(snes)} cs={captainStrongPercent(snes)} " &
    fmt"pa={paulaRescuePercent(snes)} kn={pokeyKnockPercent(snes)} " &
    fmt"99F2={readU8(snes,0x99F2):02X} 9885={readU8(snes,0x9885):02X} 9887={readU8(snes,0x9887):02X}"
  echo "  ", checkpointSpineLine(snes)

proc skills(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua & "\n" &
    FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & IntentNavSkillLua

proc runPol(snes: SnesBus; cpu: var Cpu; pol: string; frames: int; label: string):
    tuple[maxFr, maxGs, maxCs, maxPa, minX, maxX, minY, maxY, maxIndoor: int] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, skills(), "sk")
  loadChunk(L, pol, label)
  let i = PlayerSlot * SlotIndexStride
  result.minX = readU16(snes, WorldXBase + i)
  result.maxX = result.minX
  result.minY = readU16(snes, WorldYBase + i)
  result.maxY = result.minY
  result.maxFr = frankPercent(snes)
  result.maxGs = giantStepPercent(snes)
  result.maxCs = captainStrongPercent(snes)
  result.maxPa = paulaRescuePercent(snes)
  result.maxIndoor = 0
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < result.minX: result.minX = px
    if px > result.maxX: result.maxX = px
    if py < result.minY: result.minY = py
    if py > result.maxY: result.maxY = py
    if px >= OutdoorMaxX: result.maxIndoor = 1
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    let cs = captainStrongPercent(snes)
    let pa = paulaRescuePercent(snes)
    if fr > result.maxFr: result.maxFr = fr
    if gs > result.maxGs: result.maxGs = gs
    if cs > result.maxCs: result.maxCs = cs
    if pa > result.maxPa: result.maxPa = pa
    if f mod 3000 == 0:
      echo fmt"  {label} f={f} pos=(0x{px:04X},0x{py:04X}) fr={fr} gs={gs} cs={cs} pa={pa} indoor={px >= OutdoorMaxX}"
  echo fmt"FINAL {label} maxFr={result.maxFr} maxGs={result.maxGs} maxCs={result.maxCs} maxPa={result.maxPa} " &
    fmt"bbox=0x{result.minX:04X}..0x{result.maxX:04X},0x{result.minY:04X}..0x{result.maxY:04X} indoor={result.maxIndoor}"

const NorthCaveHunt = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    local f = frame() % 90
    if f < 30 then pad.press("Up")
    elseif f < 50 then pad.press("Right")
    elseif f < 70 then pad.press("A")
    else pad.press("Left") end
    return
  end
  -- police west then north toward mountain
  if px > 0x08F0 then
    pad.press("Left")
    return
  end
  if py > 0x0180 then
    pad.press("Up")
    if (frame() % 32) < 10 then pad.press("Left") end
    return
  end
  if py > 0x00C0 then
    pad.press("Up")
    if (frame() % 28) < 8 then pad.press("Right") end
    return
  end
  local f = frame() % 100
  if f < 40 then pad.press("Up")
  elseif f < 60 then pad.press("Right")
  elseif f < 80 then pad.press("A")
  else pad.press("Left") end
end
"""

proc loadBase(path: string): (SnesBus, Cpu) =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  (snes, cpu)

proc flagdiff(a, b: string; tag: string) =
  ## Diff event flag region between two fixtures.
  if not fileExists(a) or not fileExists(b): return
  let (sa, ca) = loadBase(a)
  discard ca
  let (sb, cb) = loadBase(b)
  discard cb
  var n = 0
  echo "FLAGDIFF ", tag
  for off in 0x9880 .. 0x9A7F:
    let va = readU8(sa, off)
    let vb = readU8(sb, off)
    if va != vb:
      echo fmt"  ${off:04X}: {va:02X} → {vb:02X}"
      n += 1
      if n > 80:
        echo "  ...truncated"
        break
  echo "  count=", n

proc main() =
  doAssert fileExists(Rom)
  echo "=== d72 day-1 next unfinished segment ==="

  # A) Continuous product outdoor → frank → giant → captain (Agent policies)
  if fileExists(OutdoorPk):
    echo "--- A continuous night spine from post_knock_outdoor ---"
    var (snes, cpu) = loadBase(OutdoorPk)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    grade(snes, "A_start")
    var r = runPol(snes, cpu, AgentFrankPolicy, 9000, "AgentFrank")
    grade(snes, "A_after_frank")
    r = runPol(snes, cpu, AgentGiantStepPolicy, 10000, "AgentGiant")
    grade(snes, "A_after_giant")
    r = runPol(snes, cpu, AgentCaptainStrongPolicy, 10000, "AgentCaptain")
    grade(snes, "A_after_captain")
    echo fmt"A_PEAK maxFr={r.maxFr} maxGs from last legs see FINAL lines"

  # B) Giant cave north hunt from giant_approach (night)
  if fileExists(Giant):
    echo "--- B north cave hunt from giant_approach ---"
    var (snes, cpu) = loadBase(Giant)
    grade(snes, "B_start")
    discard runPol(snes, cpu, NorthCaveHunt, 12000, "NorthCaveHunt")
    grade(snes, "B_end")

  # C) Day-flag overlay: copy leave_day1_map day-ish bytes onto giant, hunt
  if fileExists(Giant) and fileExists(LeaveMap):
    echo "--- C day overlay leave_map flags onto giant seat ---"
    flagdiff(Giant, LeaveMap, "giant→leave_map")
    var (snes, cpu) = loadBase(Giant)
    let (lm, _) = loadBase(LeaveMap)
    # Overlay day-ish story + 9885/9887 and broader event flags that differ
    for off in [0x9885, 0x9887, 0x99F2]:
      snes.bus.mem[0x7E0000 + off] = uint8(readU8(lm, off))
    # Prefer knock $58 for frank/gs ladders + day $9887 from leave map.
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + 0x9887] = uint8(readU8(lm, 0x9887))
    grade(snes, "C_overlay_start")
    discard runPol(snes, cpu, NorthCaveHunt, 10000, "CaveHuntDayOverlay")
    grade(snes, "C_overlay_end")

  # D) leave_day1_noparty AgentCaptain hold + Paula push (night C4 wall)
  if fileExists(LeaveNo):
    echo "--- D leave_noparty captain/paula freeplay ---"
    var (snes, cpu) = loadBase(LeaveNo)
    applyLaterStoryLeaveSoft(snes)
    grade(snes, "D_start")
    discard runPol(snes, cpu, AgentCaptainStrongPolicy, 6000, "CapLeaveNo")
    grade(snes, "D_after_cap")
    discard runPol(snes, cpu, AgentPaulaApproachPolicy, 10000, "PaulaLeaveNo")
    grade(snes, "D_after_paula")

  # E) leave_day1_map freeplay (cs100 product past leave seat)
  if fileExists(LeaveMap):
    echo "--- E leave_map freeplay AgentPaula/Midgame ---"
    var (snes, cpu) = loadBase(LeaveMap)
    applyLaterStoryLeaveSoft(snes)
    grade(snes, "E_start")
    discard runPol(snes, cpu, AgentPaulaApproachPolicy, 8000, "PaulaLeaveMap")
    grade(snes, "E_after_paula")
    discard runPol(snes, cpu, AgentMidgameExplorePolicy, 8000, "MidLeaveMap")
    grade(snes, "E_after_mid")

  # F) frank_arcade door hunt for frank 100 / indoor
  if fileExists(Arcade):
    echo "--- F frank_arcade indoor/door hunt ---"
    var (snes, cpu) = loadBase(Arcade)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    grade(snes, "F_start")
    const DoorHunt = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    local f = frame() % 80
    if f < 25 then pad.press("Up")
    elseif f < 45 then pad.press("A")
    elseif f < 65 then pad.press("Right")
    else pad.press("Down") end
    return
  end
  -- arcade strip: try doors north of commercial
  if py > 0x0180 then
    pad.press("Up")
    if (frame() % 20) < 6 then pad.press("A") end
    return
  end
  local f = frame() % 100
  if f < 30 then pad.press("Left")
  elseif f < 50 then pad.press("A")
  elseif f < 75 then pad.press("Right")
  else pad.press("Up") end
end
"""
    discard runPol(snes, cpu, DoorHunt, 10000, "ArcadeDoorHunt")
    grade(snes, "F_end")

  echo "OK probe_d72_day1_next"

when isMainModule:
  main()
