import std/[os, strformat],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]
const Rom = "bin/Earthbound (U) [!].smc"
const P = "bin/states/llm/post_battle_midgame.state"
proc main() =
  if not fileExists(P):
    echo "SKIP no post_battle_midgame"; return
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(P)), snes, c)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) {checkpointSpineLine(snes)}"
  echo "OK"
main()
