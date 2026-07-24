## Dump candidate endgame WRAM from late llm fixtures for Magicant/Giygas RE.
import
  std/[os, strformat, strutils, algorithm],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc dump(path: string) =
  if not fileExists(path): return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  let i = PlayerSlot * SlotIndexStride
  echo "=== ", extractFilename(path), " ==="
  echo fmt"  pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) money={readU16(snes,0x9831)}"
  echo fmt"  party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X},{readU8(snes,0x988D):02X},{readU8(snes,0x988E):02X}"
  echo fmt"  $9881={readU8(snes,0x9881):02X} $9887={readU8(snes,0x9887):02X} $99F2={readU8(snes,0x99F2):02X}"
  echo "  ", checkpointSpineLine(snes)
  # Dump $98A0..$9920 (stats/inventory-ish) non-zero
  var line = "  inv-ish:"
  for off in 0x98A0 .. 0x9920:
    let v = readU8(snes, off)
    if v != 0: line.add fmt" ${off:04X}={v:02X}"
  echo line
  # Event flag window $9A00..$9B80 non-zero sample
  line = "  flags:"
  var n = 0
  for off in 0x9A00 .. 0x9BFF:
    let v = readU8(snes, off)
    if v != 0 and v != 0xFF:
      if n < 30: line.add fmt" ${off:04X}={v:02X}"
      n.inc
  echo line, " (nonzero_nonff=", n, ")"
  # Sector / map
  echo fmt"  $89CA={readU16(snes,0x89CA):04X} $5E06={readU8(snes,0x5E06):02X}"

proc main() =
  for p in [
    "bin/states/llm/midgame_approach.state",
    "bin/states/llm/poo_joined.state",
    "bin/states/llm/poo_deep_south.state",
    "bin/states/llm/poo_very_deep.state",
    "bin/states/llm/poo_free_outdoor.state",
    "bin/states/llm/poo_solo.state",
    "bin/states/llm/fourside_deep_prepoo.state"
  ]:
    dump(p)

when isMainModule: main()
