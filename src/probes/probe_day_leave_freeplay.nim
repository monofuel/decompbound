## d86: day-leave freeplay past night south wall (py~0x02A0) → captain 100.
## Compare leave_day1_map (cs100 mobile) vs continuous night cs60 + C4.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  Giant = "bin/states/llm/giant_approach.state"
  Captain = "bin/states/llm/captain_approach.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"
  LeaveNo = "bin/states/llm/leave_day1_noparty.state"
  DayLeaveMinY = 0x0500

proc loadChunk(L: lua53.PState; src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc skills(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua & "\n" &
    FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & IntentNavSkillLua

proc grade(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"GRADE {tag} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"cs={captainStrongPercent(snes)} pr={peacefulRestPercent(snes)} " &
    fmt"fr={frankPercent(snes)} gs={giantStepPercent(snes)} " &
    fmt"99F2={readU8(snes,0x99F2):02X} 9885={readU8(snes,0x9885):02X} 9887={readU8(snes,0x9887):02X} " &
    fmt"10E5={readU8(snes,0x10E5):02X} 10E7={readU8(snes,0x10E7):02X}"

proc pureDown(snes: SnesBus; c: var Cpu; frames: int): tuple[maxY, maxCs, span: int] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  result.maxCs = captainStrongPercent(snes)
  for f in 1 .. frames:
    snes.joy1 = 0x0400'u16
    if (f mod 40) < 10: snes.joy1 = 0x0500'u16 # Down+Right
    if (f mod 40) >= 30: snes.joy1 = 0x0600'u16 # Down+Left
    policy.stepOneFrame(snes, c, img)
    clearSouthFreezeLocks(snes)
    applyLaterStoryLeaveSoft(snes)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if py > maxY: maxY = py
    if py < minY: minY = py
    if px > maxX: maxX = px
    if px < minX: minX = px
    let cs = captainStrongPercent(snes)
    if cs > result.maxCs: result.maxCs = cs
  result.maxY = maxY
  result.span = (maxX - minX) + (maxY - minY)

proc flagdiff(a, b: SnesBus; lo, hi: int; tag: string; maxShow = 40) =
  var n = 0
  echo "FLAGDIFF ", tag, " $", toHex(lo, 4), "..$", toHex(hi, 4)
  for off in lo .. hi:
    let va = readU8(a, off)
    let vb = readU8(b, off)
    if va != vb:
      if n < maxShow:
        echo fmt"  ${off:04X}: night={va:02X} daymap={vb:02X}"
      n += 1
  echo "  count=", n

proc main() =
  doAssert fileExists(Rom)
  echo "=== d86 day-leave freeplay ==="

  # Reference grades
  for path in [Captain, LeaveNo, LeaveMap, Giant]:
    if not fileExists(path): continue
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(path)), snes, c)
    grade(snes, extractFilename(path))

  # A) leave_day1_map pure Down mobility past DayLeaveMinY
  if fileExists(LeaveMap):
    echo "--- A leave_day1_map freewalk ---"
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, c)
    applyLaterStoryLeaveSoft(snes)
    grade(snes, "A_start")
    let r = pureDown(snes, c, 4000)
    grade(snes, "A_end")
    echo fmt"A maxY=0x{r.maxY:04X} maxCs={r.maxCs} span={r.span}"

  # B) captain night + C4 pure Down (expect wall ~0x02A0)
  if fileExists(Captain):
    echo "--- B captain + C4 pure Down (night wall) ---"
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Captain)), snes, c)
    applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    grade(snes, "B_start")
    let r = pureDown(snes, c, 4000)
    grade(snes, "B_end")
    echo fmt"B maxY=0x{r.maxY:04X} maxCs={r.maxCs} span={r.span}"

  # C) Flagdiff night captain+C4 vs leave_day1_map (event + mode + entity)
  if fileExists(Captain) and fileExists(LeaveMap):
    echo "--- C flagdiff night captain+C4 vs leave_day1_map ---"
    let night = newSnesBus(policy.readRomFile(Rom))
    var cn = night.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Captain)), night, cn)
    applyLaterStoryLeaveSoft(night)
    let day = newSnesBus(policy.readRomFile(Rom))
    var cd = day.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LeaveMap)), day, cd)
    applyLaterStoryLeaveSoft(day)
    flagdiff(night, day, 0x9880, 0x9A7F, "event")
    flagdiff(night, day, 0x5D00, 0x5FFF, "mode")
    flagdiff(night, day, 0x1000, 0x10FF, "lock10")
    flagdiff(night, day, 0x0000, 0x00FF, "low")

  # D) Overlay leave_day1_map flags onto captain pos; test Down past wall
  if fileExists(Captain) and fileExists(LeaveMap):
    echo "--- D overlay daymap flags @ captain pos ---"
    let day = newSnesBus(policy.readRomFile(Rom))
    var cd = day.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LeaveMap)), day, cd)
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Captain)), snes, c)
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    # overlay event flags
    for off in 0x9880 .. 0x9A7F:
      snes.bus.mem[0x7E0000 + off] = uint8(readU8(day, off))
    # keep position
    snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(px and 0xFF)
    snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8(px shr 8)
    snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(py and 0xFF)
    snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8(py shr 8)
    applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    grade(snes, "D_overlay_start")
    let r = pureDown(snes, c, 4000)
    grade(snes, "D_overlay_end")
    echo fmt"D maxY=0x{r.maxY:04X} maxCs={r.maxCs} span={r.span}"

  # E) Overlay mode 5D00-5FFF
  if fileExists(Captain) and fileExists(LeaveMap):
    echo "--- E overlay mode region ---"
    let day = newSnesBus(policy.readRomFile(Rom))
    var cd = day.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LeaveMap)), day, cd)
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Captain)), snes, c)
    for off in 0x5D00 .. 0x5FFF:
      snes.bus.mem[0x7E0000 + off] = uint8(readU8(day, off))
    applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    let r = pureDown(snes, c, 4000)
    echo fmt"E mode overlay maxY=0x{r.maxY:04X} maxCs={r.maxCs}"

  # F) Overlay event+mode together
  if fileExists(Captain) and fileExists(LeaveMap):
    echo "--- F event+mode overlay ---"
    let day = newSnesBus(policy.readRomFile(Rom))
    var cd = day.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LeaveMap)), day, cd)
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Captain)), snes, c)
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    for off in 0x5D00 .. 0x5FFF:
      snes.bus.mem[0x7E0000 + off] = uint8(readU8(day, off))
    for off in 0x9880 .. 0x9A7F:
      snes.bus.mem[0x7E0000 + off] = uint8(readU8(day, off))
    snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(px and 0xFF)
    snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8(px shr 8)
    snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(py and 0xFF)
    snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8(py shr 8)
    applyLaterStoryLeaveSoft(snes)
    clearSouthFreezeLocks(snes)
    let r = pureDown(snes, c, 5000)
    grade(snes, "F_end")
    echo fmt"F event+mode maxY=0x{r.maxY:04X} maxCs={r.maxCs} span={r.span}"

  # G) Seat captain at day leave Y with night flags (collision test)
  if fileExists(Captain):
    echo "--- G seat y=0x05B5 night flags ---"
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Captain)), snes, c)
    applyLaterStoryLeaveSoft(snes)
    let i = PlayerSlot * SlotIndexStride
    snes.bus.mem[0x7E0000 + WorldYBase + i] = 0xB5
    snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = 0x05
    snes.bus.mem[0x7E0000 + WorldXBase + i] = 0x00
    snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = 0x08
    clearSouthFreezeLocks(snes)
    grade(snes, "G_seated")
    let r = pureDown(snes, c, 2000)
    grade(snes, "G_end")
    echo fmt"G maxY=0x{r.maxY:04X} maxCs={r.maxCs} span={r.span}"

  # H) 4K band bisect: which free leave_map WRAM opens south wall
  if fileExists(Captain) and fileExists(LeaveMap):
    echo "--- H 4K band bisect leave_map onto captain for maxY ---"
    let day = newSnesBus(policy.readRomFile(Rom))
    var cd = day.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LeaveMap)), day, cd)
    var lo = 0
    while lo < 0x10000:
      let hi = min(lo + 0x0FFF, 0xFFFF)
      let snes = newSnesBus(policy.readRomFile(Rom))
      var c = snes.resetCpu()
      deserializeState(cast[seq[byte]](readFile(Captain)), snes, c)
      let i = PlayerSlot * SlotIndexStride
      let px = readU16(snes, WorldXBase + i)
      let py = readU16(snes, WorldYBase + i)
      for off in lo .. hi:
        snes.bus.mem[0x7E0000 + off] = day.bus.mem[0x7E0000 + off]
      snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(px and 0xFF)
      snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8(px shr 8)
      snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(py and 0xFF)
      snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8(py shr 8)
      applyLaterStoryLeaveSoft(snes)
      clearSouthFreezeLocks(snes)
      let r = pureDown(snes, c, 2500)
      let mark = if r.maxY > 0x02B0: "OPEN" else: "wall"
      if r.maxY > 0x02B0 or lo mod 0x4000 == 0:
        echo fmt"{mark} ${lo:04X}..${hi:04X} maxY=0x{r.maxY:04X} maxCs={r.maxCs}"
      elif r.maxY > 0x02A0:
        echo fmt"edge ${lo:04X}..${hi:04X} maxY=0x{r.maxY:04X}"
      lo += 0x1000

  echo "OK probe_day_leave_freeplay"

when isMainModule:
  main()
