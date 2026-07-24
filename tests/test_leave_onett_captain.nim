## Captain leave-Onett soft past 70: later-story + Paula/Jeff party proof.

import
  std/[os, strutils],
  ../src/decompbound/[cpu, snesbus, save_state, policy],
  ../src/tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Night = "bin/states/llm/captain_west.state"
  Mid = "bin/states/llm/midgame_approach.state"
  Fo80 = "bin/states/llm/fourside80_walkable.state"
  Slot1 = "bin/states/slot1.state"

proc grade(path: string): int =
  ## Load fixture and return captain_strong percent.
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  result = captainStrongPercent(snes)
  echo path, " cs=", result, " paula=", paulaRescuePercent(snes),
    " winters=", wintersPercent(snes), " party_paula=",
    partyHasChar(snes, PartyCharPaula), " party_jeff=",
    partyHasChar(snes, PartyCharJeff)

proc main() =
  ## Night stays ≤60; midgame with Paula/Jeff grades ≥80 leave soft.
  doAssert fileExists(Rom)
  if fileExists(Night):
    let cs = grade(Night)
    doAssert cs >= 50 and cs <= 60,
      "night captain_west should be pos ladder 50–60, got " & $cs
  if fileExists(Mid):
    let cs = grade(Mid)
    # d60: later-story + outdoor py≥0x0500 grades captain 100 (day leave map soft).
    doAssert cs >= 100,
      "midgame deep map should grade captain day-leave 100, got " & $cs
  if fileExists(Slot1):
    let cs = grade(Slot1)
    doAssert cs >= 100, "slot1 midgame deep should be captain day-leave 100"
  if fileExists(Fo80):
    let cs = grade(Fo80)
    doAssert cs >= 100,
      "fo80 late deep map grades captain day-leave 100, got " & $cs
  if fileExists("bin/states/llm/leave_day1_map.state"):
    let cs = grade("bin/states/llm/leave_day1_map.state")
    doAssert cs >= 100, "leave_day1_map solo day seat is captain 100"
  if fileExists("bin/states/llm/leave_day1_noparty.state"):
    let cs = grade("bin/states/llm/leave_day1_noparty.state")
    doAssert cs >= 70 and cs < 100,
      "leave_day1_noparty night seat is C4 soft 70 not map 100, got " & $cs
  echo "OK test_leave_onett_captain: day-leave map 100 + C4 soft 70 ladder"

when isMainModule:
  main()
