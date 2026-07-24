## Flag-based leave-Onett / midgame referee dump.
## Night captain_west uses pos ladder (cs 50); midgame $99F2 grades cs 70.
## Prints the minimal story bytes that distinguish knock-night vs later-story.

import
  std/[os, strformat],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Watch = [
    0x9885, 0x9887, 0x988B, 0x988C, 0x988D, 0x99F2, 0x9831, 0x9A0B
  ]

proc grade(path: string) =
  if not fileExists(path):
    echo "SKIP ", path
    return
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"=== {path} ==="
  echo fmt"  pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  echo fmt"  captain={captainStrongPercent(snes)} paula={paulaRescuePercent(snes)} frank={frankPercent(snes)}"
  echo fmt"  knockComplete={knockComplete(snes)} $99F2=0x{readU8(snes,KnockCompleteOff):02X}"
  for off in Watch:
    echo fmt"  ${off:04X}=0x{readU8(snes,off):02X}"
  echo "  ", checkpointSpineLine(snes)

proc main() =
  ## Document flag-based vs pos-based captain/paula referees.
  grade("bin/states/llm/captain_west.state")
  grade("bin/states/llm/captain_approach.state")
  grade("bin/states/llm/giant_approach.state")
  grade("bin/states/llm/post_knock_outdoor.state")
  if fileExists("bin/states/slot1.state"):
    grade("bin/states/slot1.state")
  echo "FLAG_WIN: $99F2 != 0x58 and != 0 grades captain_strong=70 (midgame leave soft)"
  echo "POS_WIN: px<=0x0890 py>=0x0200 frank>=50 grades captain_strong=50 (night lane)"
  echo "OK probe_leave_onett_flags"

when isMainModule:
  main()
