## Grade midgame fixtures for next checkpoints.md segments past Onett night.
import
  std/[os, strformat],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc dump(path: string) =
  if not fileExists(path):
    echo "SKIP ", path
    return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  echo fmt"{path}: pos=(0x{px:04X},0x{py:04X}) party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X},{readU8(snes,0x988D):02X}"
  echo fmt"  $99F2={readU8(snes,0x99F2):02X} $9887={readU8(snes,0x9887):02X} money={readU16(snes,0x9831)}"
  echo fmt"  {checkpointSpineLine(snes)}"
  # Sector / map hints if known offsets exist
  echo fmt"  room/tg={touchGrassPercent(snes)} sector_try=$89CA={readU16(snes,0x89CA):04X}"

proc main() =
  for p in ["bin/states/slot1.state", "bin/states/slot85.state",
            "bin/states/battle_menu_healthy.state",
            "bin/states/llm/captain_west.state"]:
    dump(p)

when isMainModule: main()
