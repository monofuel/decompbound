## Scan party roster + candidate flags on post-knock / frank / giant fixtures.
import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc grade(path: string) =
  if not fileExists(path):
    echo "missing ", path
    return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  if "post_knock" in path or "frank" in path or "giant" in path:
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let i = PlayerSlot * SlotIndexStride
  let pr0 = readU8(snes, 0x988B)
  let pr1 = readU8(snes, 0x988C)
  let pr2 = readU8(snes, 0x988D)
  echo fmt"=== {path} ==="
  echo fmt"  pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  echo fmt"  spine {checkpointSpineLine(snes)}"
  echo fmt"  party_roster $988B..=0x{pr0:02X},0x{pr1:02X},0x{pr2:02X}"
  for off in [0x9876, 0x9877, 0x9878, 0x9885, 0x99F2, 0x9A00, 0x9A10, 0x9C00]:
    echo fmt"  ${off:04X}=0x{readU8(snes, off):02X}"

proc main() =
  grade("bin/states/llm/onett_start.state")
  grade("bin/states/llm/post_knock_outdoor.state")
  grade("bin/states/llm/frank_downtown.state")
  grade("bin/states/llm/giant_approach.state")

when isMainModule: main()
