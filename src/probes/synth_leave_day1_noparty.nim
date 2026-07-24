## Day-1 leave soft without party synth.
##
## F12 RE 2026-07-24 (earthbound_20260706-210416 and peers): later-story
## `$99F2=0xC4` with Ness-only party grades captain_strong=70 (leave soft).
## Party Paula/Jeff are NOT required for 70 — only for 80/90.
##
## Build free outdoor + minimal later-story byte so campaign can continuous
## post-knock outdoor → night captain → leave soft without cloning midgame party.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  ## Prefer mobile south-commercial captain seat over door-stuck outdoor_pk.
  Bases = [
    "bin/states/llm/captain_approach.state",
    "bin/states/llm/captain_west.state",
    "bin/states/llm/giant_approach.state",
    "bin/states/llm/post_knock_outdoor.state",
  ]
  OutPath = "bin/states/llm/leave_day1_noparty.state"
proc tryBase(path: string): bool =
  ## Apply later-story byte; return true if mobile + cs70 no party.
  if not fileExists(path):
    return false
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  applyLaterStoryLeaveSoft(snes)
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  # Clear post-Pokey soft-lock bit if set (same class as goHome).
  let lock = uint8(readU8(snes, 0x9877))
  if (lock and 1'u8) != 0:
    snes.bus.mem[0x7E0000 + 0x9877] = lock and 0xFE'u8

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. 15:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)

  if partyHasChar(snes, PartyCharPaula) or partyHasChar(snes, PartyCharJeff):
    echo path, ": skip — already has party"
    return false
  let cs = captainStrongPercent(snes)
  if cs < 70 or cs >= 80:
    echo path, ": skip cs=", cs
    return false

  let i = PlayerSlot * SlotIndexStride
  let px0 = int(readU16(snes, WorldXBase + i))
  let py0 = int(readU16(snes, WorldYBase + i))
  var span = 0
  for f in 1 .. 120:
    # Alternate Right/Down so door-hug seats still move.
    snes.joy1 = if (f mod 2) == 0: 0x0100'u16 else: 0x0400'u16
    policy.stepOneFrame(snes, c, img)
  let px1 = int(readU16(snes, WorldXBase + i))
  let py1 = int(readU16(snes, WorldYBase + i))
  span = abs(px1 - px0) + abs(py1 - py0)
  echo fmt"{path}: cs={cs} paula={paulaRescuePercent(snes)} span={span} " &
    fmt"pos=(0x{px0:04X},0x{py0:04X})->(0x{px1:04X},0x{py1:04X})"
  if span <= 4:
    return false

  applyLaterStoryLeaveSoft(snes)
  writeFile(OutPath, cast[string](serializeState(snes, c)))
  echo fmt"WROTE {OutPath} cs={captainStrongPercent(snes)} paula={paulaRescuePercent(snes)} " &
    fmt"from={path} {checkpointSpineLine(snes)}"
  true

proc main() =
  ## Free mobile base + $99F2=C4 → leave soft cs70 without party poke.
  doAssert fileExists(Rom)
  createDir("bin/states/llm")
  var ok = false
  for b in Bases:
    if tryBase(b):
      ok = true
      break
  doAssert ok, "no mobile leave_day1_noparty base (cs70 no party)"

when isMainModule:
  main()
