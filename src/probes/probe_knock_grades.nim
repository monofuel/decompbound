## Grade knock/pokey on home fixtures.
import std/[os, strformat]
import ../decompbound/[cpu, snesbus, save_state, policy]
import ../tools/[touch_grass, story_percents]
const Rom = "bin/Earthbound (U) [!].smc"
proc main() =
  for p in [
    "bin/states/llm/pokey_done.state",
    "bin/states/llm/home_door.state",
    "bin/states/llm/home_door_postmeteor.state",
    "bin/states/llm/home_natural_entry.state",
    "bin/states/llm/home_downstairs.state",
    "bin/states/llm/home_downstairs_night.state",
    "bin/states/llm/home_indoor.state",
    "bin/states/llm/bedroom.state",
    "bin/states/llm/onett_start.state",
  ]:
    if not fileExists(p): continue
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(p)), snes, c)
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    echo fmt"{p}: knock={pokeyKnockPercent(snes)} pokey={pokeyPercent(snes)} tg={touchGrassPercent(snes)} room={currentRoomLabel(snes)} pos=(0x{px:04X},0x{py:04X})"
main()
