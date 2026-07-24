## Day-1 leave map soft fixture: free control + later-story + day-leave Y seat.
##
## Night Onett with C4 sticks at py~0x02A0 (south commercial wall). F12
## earthbound_20260706-210416 seats solo Ness at (0x0800,0x05B5) with $99F2=C4
## on day map — grades captain_strong=100 after DayLeaveMinY ladder.
##
## Does not synth Paula/Jeff. Campaign path when south wall blocks free-play.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutPath = "bin/states/llm/leave_day1_map.state"
  ## F12 day-leave solo seat (2026-07-06-210416).
  DayLeaveX = 0x0800'u16
  DayLeaveY = 0x05B5'u16
  Bases = [
    "bin/states/slot4.state",
    "bin/states/llm/leave_onett_walkable.state",
    "bin/states/llm/captain_approach.state",
  ]

proc main() =
  ## Free mobile base + C4 + day-leave map seat → captain 100 without party.
  doAssert fileExists(Rom)
  createDir("bin/states/llm")
  var base = ""
  for b in Bases:
    if fileExists(b):
      base = b
      break
  doAssert base.len > 0, "need free outdoor base"

  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(base)), snes, c)

  # Ness-only (no party synth for leave-100 map proof).
  snes.bus.mem[0x7E0000 + PartySlot1] = 0
  snes.bus.mem[0x7E0000 + PartySlot2] = 0
  snes.bus.mem[0x7E0000 + PartySlot3] = 0
  snes.bus.mem[0x7E0000 + PartySizeOffA] = 1
  snes.bus.mem[0x7E0000 + PartySizeOffB] = 1
  applyLaterStoryLeaveSoft(snes)

  let i = PlayerSlot * SlotIndexStride
  snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(DayLeaveX and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8(DayLeaveX shr 8)
  snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(DayLeaveY and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8(DayLeaveY shr 8)
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. 30:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
  applyLaterStoryLeaveSoft(snes)

  let cs = captainStrongPercent(snes)
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  echo fmt"grade pos=(0x{px:04X},0x{py:04X}) cs={cs} " &
    fmt"paulaIn={partyHasChar(snes, PartyCharPaula)} " &
    fmt"jeffIn={partyHasChar(snes, PartyCharJeff)} 99F2=0x{readU8(snes,KnockCompleteOff):02X}"
  doAssert not partyHasChar(snes, PartyCharPaula)
  doAssert not partyHasChar(snes, PartyCharJeff)
  doAssert cs >= 100, "day-leave map seat must grade captain 100, got " & $cs

  let px0 = int(px)
  let py0 = int(py)
  for f in 1 .. 120:
    snes.joy1 = if (f mod 2) == 0: 0x0100'u16 else: 0x0400'u16
    policy.stepOneFrame(snes, c, img)
  applyLaterStoryLeaveSoft(snes)
  let px1 = int(readU16(snes, WorldXBase + i))
  let py1 = int(readU16(snes, WorldYBase + i))
  let span = abs(px1 - px0) + abs(py1 - py0)
  echo fmt"mobility span={span} end=(0x{px1:04X},0x{py1:04X}) cs={captainStrongPercent(snes)}"
  doAssert span > 4, "leave_day1_map must be mobile"
  doAssert captainStrongPercent(snes) >= 100

  applyLaterStoryLeaveSoft(snes)
  writeFile(OutPath, cast[string](serializeState(snes, c)))
  echo fmt"WROTE {OutPath} from={base} {checkpointSpineLine(snes)}"

when isMainModule:
  main()
