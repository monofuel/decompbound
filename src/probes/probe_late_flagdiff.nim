## Flag-diff late Poo fixtures vs midgame Jeff-only for Magicant/Giygas candidates.
import
  std/[os, strformat, tables],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const FlagLo = 0x9880
const FlagHi = 0x9C00

proc snap(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in FlagLo ..< FlagHi:
    result[off] = readU8(snes, off)

proc load(path: string): (SnesBus, Table[int, int]) =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  (snes, snap(snes))

proc main() =
  let basePath = "bin/states/llm/midgame_approach.state"
  let latePath =
    if fileExists("bin/states/llm/poo_very_deep.state"):
      "bin/states/llm/poo_very_deep.state"
    else:
      "bin/states/llm/poo_joined.state"
  if not fileExists(basePath) or not fileExists(latePath):
    echo "SKIP missing fixtures"
    return
  let (snesA, a) = load(basePath)
  let (snesB, b) = load(latePath)
  echo "BASE ", extractFilename(basePath), " ", checkpointSpineLine(snesA)
  echo "LATE ", extractFilename(latePath), " ", checkpointSpineLine(snesB)
  var n = 0
  for off, va in a:
    let vb = b.getOrDefault(off, va)
    if va != vb:
      if n < 40:
        echo fmt"  ${off:04X}: 0x{va:02X} -> 0x{vb:02X}"
      n.inc
  echo "flagdiffs=", n
  # Also dump party + money
  echo fmt"party mid {readU8(snesA,0x988B):02X},{readU8(snesA,0x988C):02X},{readU8(snesA,0x988D):02X},{readU8(snesA,0x988E):02X}"
  echo fmt"party late {readU8(snesB,0x988B):02X},{readU8(snesB,0x988C):02X},{readU8(snesB,0x988D):02X},{readU8(snesB,0x988E):02X}"
  echo "OK probe_late_flagdiff"

when isMainModule:
  main()
