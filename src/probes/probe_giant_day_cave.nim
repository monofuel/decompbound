## Giant Step past gs60: day-flag overlays, extent maps, indoor entry hunts.
## checkpoints.md Titanic Ant / Giant Step — cave needs day collision or indoor RE.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
  LeaveNo = "bin/states/llm/leave_day1_noparty.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"
  Arcade = "bin/states/llm/frank_arcade.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc dump(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"GRADE {tag} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"fr={frankPercent(snes)} gs={giantStepPercent(snes)} cs={captainStrongPercent(snes)} " &
    fmt"99F2={readU8(snes,0x99F2):02X} 9887={readU8(snes,0x9887):02X} 9885={readU8(snes,0x9885):02X} " &
    fmt"indoor={readU16(snes,WorldXBase+i) >= OutdoorMaxX}"

proc runExplore(snes: SnesBus; cpu: var Cpu; pol, label: string; frames: int):
    tuple[maxGs, maxFr, maxCs, minX, maxX, minY, maxY, maxIndoor: int] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & WinBattleSkillLua &
    "\n" & AdvanceDialogueSkillLua, "sk")
  loadChunk(L, pol, label)
  let i = PlayerSlot * SlotIndexStride
  result.minX = readU16(snes, WorldXBase+i)
  result.maxX = result.minX
  result.minY = readU16(snes, WorldYBase+i)
  result.maxY = result.minY
  result.maxGs = giantStepPercent(snes)
  result.maxFr = frankPercent(snes)
  result.maxCs = captainStrongPercent(snes)
  result.maxIndoor = 0
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    # hold knock for night ladders when we set it
    if readU8(snes, KnockCompleteOff) == KnockCompleteVal:
      discard
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    if px < result.minX: result.minX = px
    if px > result.maxX: result.maxX = px
    if py < result.minY: result.minY = py
    if py > result.maxY: result.maxY = py
    if px >= OutdoorMaxX: result.maxIndoor = 1
    let gs = giantStepPercent(snes)
    let fr = frankPercent(snes)
    let cs = captainStrongPercent(snes)
    if gs > result.maxGs: result.maxGs = gs
    if fr > result.maxFr: result.maxFr = fr
    if cs > result.maxCs: result.maxCs = cs
    if f mod 2500 == 0:
      echo fmt"  {label} f={f} pos=(0x{px:04X},0x{py:04X}) gs={gs} fr={fr} indoor={px >= OutdoorMaxX}"
  echo fmt"FINAL {label} maxGs={result.maxGs} maxFr={result.maxFr} maxCs={result.maxCs} " &
    fmt"bbox=0x{result.minX:04X}..0x{result.maxX:04X},0x{result.minY:04X}..0x{result.maxY:04X} " &
    fmt"indoor={result.maxIndoor}"

const NorthHunt = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    -- indoor: explore + A
    local f = frame() % 80
    if f < 25 then pad.press("Up")
    elseif f < 50 then pad.press("Right")
    elseif f < 65 then pad.press("A")
    else pad.press("Down") end
    return
  end
  -- Giant Step is N/NE of Onett after Frank; climb north from south commercial.
  if py > 0x0180 then
    pad.press("Up")
    if (frame() % 40) < 12 then pad.press("Right")
    elseif (frame() % 40) >= 30 then pad.press("Left") end
    return
  end
  if py > 0x0100 then
    pad.press("Up")
    if (frame() % 36) < 10 then pad.press("Right") end
    return
  end
  -- near crater band: east for mountain road then A on walls
  if px < 0x0B00 then
    pad.press("Right")
    if (frame() % 20) < 4 then pad.press("A") end
    return
  end
  local f = frame() % 120
  if f < 40 then pad.press("Up")
  elseif f < 70 then pad.press("Right")
  elseif f < 95 then pad.press("A")
  else pad.press("Left") end
end
"""

const EastNorthHunt = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    local f = frame() % 60
    if f < 20 then pad.press("Up") elseif f < 40 then pad.press("A") else pad.press("Left") end
    return
  end
  -- East edge of Onett first (library / exit), then north to hill cave
  if px < 0x0B80 then
    pad.press("Right")
    if py > 0x0200 and (frame() % 30) < 10 then pad.press("Up") end
    return
  end
  if py > 0x0140 then
    pad.press("Up")
    if (frame() % 32) < 10 then pad.press("Right") end
    return
  end
  pad.press("Up")
  if (frame() % 24) < 6 then pad.press("A") end
end
"""

proc loadPath(path: string): tuple[snes: SnesBus, cpu: Cpu] =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  (snes, cpu)

proc main() =
  echo "=== GIANT DAY/CAVE PROBE ==="
  doAssert fileExists(Rom)
  doAssert fileExists(Giant)

  # A) night giant: north hunt extents
  block:
    var (snes, cpu) = loadPath(Giant)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    dump(snes, "A_night_start")
    discard runExplore(snes, cpu, NorthHunt, "A_night_north", 8000)
    dump(snes, "A_night_end")

  # B) night giant + day-ish $9887=02 overlay (leave_day1_map day byte)
  block:
    var (snes, cpu) = loadPath(Giant)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + 0x9887] = 0x02
    dump(snes, "B_daybyte_start")
    discard runExplore(snes, cpu, NorthHunt, "B_daybyte_north", 8000)
    dump(snes, "B_daybyte_end")

  # C) leave_day1_noparty at Onett south with C4: force knock $58 for ladder + day keep
  if fileExists(LeaveNo):
    block:
      var (snes, cpu) = loadPath(LeaveNo)
      # Keep C4 later-story OR dual: try knock for frank/giant ladder
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
      dump(snes, "C_leave_noparty_knock_start")
      discard runExplore(snes, cpu, EastNorthHunt, "C_leave_east_north", 10000)
      dump(snes, "C_leave_end")
      if giantStepPercent(snes) >= 60 or frankPercent(snes) >= 80:
        writeFile("bin/states/llm/giant_day_attempt.state", cast[string](serializeState(snes, cpu)))
        echo "WROTE giant_day_attempt.state"

  # D) leave_day1_map: seat to Onett south commercial + knock for day map collision
  if fileExists(LeaveMap):
    block:
      var (snes, cpu) = loadPath(LeaveMap)
      let i = PlayerSlot * SlotIndexStride
      # seat outdoor Onett south (giant band) keeping day leave flags
      snes.bus.mem[0x7E0000 + WorldXBase + i] = 0x40
      snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = 0x09
      snes.bus.mem[0x7E0000 + WorldYBase + i] = 0x80
      snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = 0x02
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
      dump(snes, "D_daymap_seated_start")
      let r = runExplore(snes, cpu, EastNorthHunt, "D_daymap_east_north", 10000)
      dump(snes, "D_daymap_end")
      # also try pure north from seated
      if r.maxIndoor == 1 or r.maxGs > 60:
        writeFile("bin/states/llm/giant_day_map_seat.state", cast[string](serializeState(snes, cpu)))
        echo "WROTE giant_day_map_seat.state"

  # E) daymap seat + pure pad extent scan (N/E/W/S)
  if fileExists(LeaveMap):
    for (dir, pol) in [
      ("E_day_N", """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  pad.press("Up")
  if (frame()%30)<8 then pad.press("Right") end
end
"""),
      ("E_day_E", """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  pad.press("Right")
  if (frame()%30)<8 then pad.press("Up") end
end
"""),
      ("E_day_W", """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  pad.press("Left")
  if (frame()%30)<8 then pad.press("Up") end
end
"""),
      ("E_day_S", """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  pad.press("Down")
end
"""),
    ]:
      var (snes, cpu) = loadPath(LeaveMap)
      let i = PlayerSlot * SlotIndexStride
      snes.bus.mem[0x7E0000 + WorldXBase + i] = 0x40
      snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = 0x09
      snes.bus.mem[0x7E0000 + WorldYBase + i] = 0x80
      snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = 0x02
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      discard runExplore(snes, cpu, pol, dir, 5000)

  # F) frank_arcade east-north
  if fileExists(Arcade):
    var (snes, cpu) = loadPath(Arcade)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    dump(snes, "F_arcade_start")
    discard runExplore(snes, cpu, EastNorthHunt, "F_arcade_east_north", 8000)
    dump(snes, "F_arcade_end")

  echo "OK probe_giant_day_cave"

when isMainModule:
  main()
