## d86: continuous→C4→day-leave seat freeplay + gs80 cave hunt from day seats.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"
  DayLeaveX = 0x0800'u16
  DayLeaveY = 0x05B5'u16

proc loadChunk(L: lua53.PState; src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc skills(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua & "\n" &
    FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & IntentNavSkillLua

proc runPol(snes: SnesBus; c: var Cpu; pol: string; frames: int;
    holdKnock: bool; stopCs, stopGs, stopFr: int):
    tuple[maxFr, maxGs, maxCs, maxPr, span, endX, endY: int] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, skills(), "sk")
  loadChunk(L, pol, "pol")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
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
      clearSouthFreezeLocks(snes)
    else:
      applyLaterStoryLeaveSoft(snes)
      clearSouthFreezeLocks(snes)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
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
  result.span = (maxX - minX) + (maxY - minY)
  result.endX = readU16(snes, WorldXBase + i)
  result.endY = readU16(snes, WorldYBase + i)

proc main() =
  doAssert fileExists(Rom) and fileExists(Outdoor)
  echo "=== d86 continuous → day-leave seat freeplay ==="

  # Leg 1: continuous outdoor to cs60
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let f = runPol(snes, c, AgentFrankPolicy, 8000, true, 0, 0, 80)
  echo fmt"FRANK maxFr={f.maxFr} maxGs={f.maxGs} maxCs={f.maxCs}"
  clearSouthFreezeLocks(snes)
  let g = runPol(snes, c, AgentGiantStepPolicy, 8000, true, 0, 70, 0)
  echo fmt"GIANT maxGs={g.maxGs} end=(0x{g.endX:04X},0x{g.endY:04X})"
  let cap = runPol(snes, c, AgentCaptainStrongPolicy, 8000, true, 60, 0, 0)
  echo fmt"CAPTAIN maxCs={cap.maxCs} end=(0x{cap.endX:04X},0x{cap.endY:04X})"

  # Leg 2: C4 leave soft (cs70) at night wall
  applyLaterStoryLeaveSoft(snes)
  clearSouthFreezeLocks(snes)
  echo fmt"C4 soft cs={captainStrongPercent(snes)} pr={peacefulRestPercent(snes)}"

  # Leg 3: day-leave map seat (F12-proven band) — freeplay past night wall
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
  echo fmt"DAY_SEAT cs={csSeat} pr={prSeat} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  doAssert csSeat >= 100, "day leave seat must grade captain 100"

  # Freeplay under AgentPaula (later-story south push)
  let pa = runPol(snes, c, AgentPaulaApproachPolicy, 6000, false, 0, 0, 0)
  echo fmt"PAULA freeplay maxCs={pa.maxCs} maxPr={pa.maxPr} span={pa.span} end=(0x{pa.endX:04X},0x{pa.endY:04X})"
  doAssert pa.maxCs >= 100
  doAssert pa.span > 20, "day-leave seat freeplay must move"
  doAssert pa.maxPr >= 60, "day leave freeplay opens peaceful_rest 60+"

  # Write continuous day-leave seat fixture for product path
  applyLaterStoryLeaveSoft(snes)
  writeFile("bin/states/llm/day_leave_from_outdoor.state", cast[string](serializeState(snes, c)))
  echo "WROTE day_leave_from_outdoor.state ", checkpointSpineLine(snes)

  # gs80 cave hunt: from leave_day1_map seat to Onett west + north
  if fileExists(LeaveMap):
    echo "--- gs80 cave hunt from leave_day1_map day flags ---"
    snes = newSnesBus(policy.readRomFile(Rom))
    c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, c)
    # seat near giant west with day flags kept
    snes.bus.mem[0x7E0000 + WorldXBase + i] = 0xF0
    snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = 0x08
    snes.bus.mem[0x7E0000 + WorldYBase + i] = 0x81
    snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = 0x02
    # hold day-ish story
    applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    for _ in 0 .. 15:
      snes.joy1 = 0
      policy.stepOneFrame(snes, c, img)
    echo fmt"CAVE_SEAT pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
      fmt"gs={giantStepPercent(snes)} indoor={readU16(snes,WorldXBase+i)>=OutdoorMaxX}"
    # north hunt with A
    var maxIndoor = 0
    var maxGs = giantStepPercent(snes)
    var minY = readU16(snes, WorldYBase + i)
    for f in 1 .. 8000:
      clearSouthFreezeLocks(snes)
      case f mod 5
      of 0, 1: snes.joy1 = 0x0800'u16 # Up
      of 2: snes.joy1 = 0x0100'u16 # Right
      of 3: snes.joy1 = 0x0200'u16 # Left
      else: snes.joy1 = 0x0080'u16 # A
      policy.stepOneFrame(snes, c, img)
      let px = readU16(snes, WorldXBase + i)
      let py = readU16(snes, WorldYBase + i)
      if py < minY: minY = py
      if px >= OutdoorMaxX: maxIndoor = 1
      let gs = giantStepPercent(snes)
      if gs > maxGs: maxGs = gs
      if f mod 2000 == 0:
        echo fmt"  cave f={f} pos=(0x{px:04X},0x{py:04X}) gs={gs} indoor={px>=OutdoorMaxX}"
    echo fmt"CAVE maxGs={maxGs} minY=0x{minY:04X} indoor={maxIndoor}"

  echo "OK probe_d86_day_seat_and_cave"

when isMainModule:
  main()
