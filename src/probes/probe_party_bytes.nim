import std/[os, strformat]
import ../decompbound/[cpu, snesbus, save_state, policy]
import ../tools/[touch_grass, story_percents]
proc dump(path: string) =
  if not fileExists(path): return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  echo path
  for off in 0x9880 .. 0x9898:
    let v = readU8(snes, off)
    if v != 0: echo fmt"  ${off:04X}=0x{v:02X}"
  echo "  spine ", checkpointSpineLine(snes)
dump("bin/states/slot1.state")
dump("bin/states/battle_menu_healthy.state")
dump("bin/states/llm/captain_west.state")
