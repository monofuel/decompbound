## Flag-based paula/winters referees from midgame party bytes (shipped metrics).

import
  std/[os, strutils],
  ../src/decompbound/[cpu, snesbus, save_state, policy],
  ../src/tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Slot1 = "bin/states/slot1.state"
  CaptainWest = "bin/states/llm/captain_west.state"

proc main() =
  ## Midgame party Paula+Jeff must open paula 90 / winters 50; night captain does not.
  doAssert fileExists(Rom)
  if fileExists(Slot1):
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Slot1)), snes, cpu)
    echo "slot1 party=", toHex(readU8(snes, PartySlot0), 2), ",",
      toHex(readU8(snes, PartySlot1), 2), ",", toHex(readU8(snes, PartySlot2), 2)
    echo "  $99F2=", toHex(readU8(snes, KnockCompleteOff), 2)
    echo "  paula=", paulaRescuePercent(snes), " winters=", wintersPercent(snes),
      " captain=", captainStrongPercent(snes)
    echo "  ", checkpointSpineLine(snes)
    doAssert partyHasChar(snes, PartyCharPaula), "slot1 has Paula"
    doAssert partyHasChar(snes, PartyCharJeff), "slot1 has Jeff"
    doAssert paulaRescuePercent(snes) >= 90, "Paula in party + later $99F2 => 90"
    doAssert wintersPercent(snes) >= 50, "Jeff in party + later $99F2 => winters 50"
    doAssert captainStrongPercent(snes) >= 70
    echo "  belch=", belchPercent(snes), " fourside=", foursidePercent(snes)
    doAssert belchPercent(snes) >= 50, "slot1 deep south + Jeff grades belch soft 50"
    doAssert foursidePercent(snes) >= 40, "slot1 py>=0x1600 grades fourside soft 40"
  else:
    echo "SKIP slot1 (no midgame fixture)"

  if fileExists(CaptainWest):
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(CaptainWest)), snes, cpu)
    echo "captain_west paula=", paulaRescuePercent(snes),
      " winters=", wintersPercent(snes)
    doAssert wintersPercent(snes) == 0, "night solo party must not grade winters"
    doAssert belchPercent(snes) == 0, "night must not grade belch"
    doAssert foursidePercent(snes) == 0, "night must not grade fourside"
    doAssert paulaRescuePercent(snes) < 90, "night must not claim Paula join"
    doAssert paulaRescuePercent(snes) >= 20 or captainStrongPercent(snes) >= 40
  echo "OK test_midgame_party_flags: paula90 winters50 belch50 fourside40"

when isMainModule:
  main()
