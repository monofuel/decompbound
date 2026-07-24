## Scan WRAM for candidate inventory runs (14-byte non-zero sequences) across fixtures.
import
  std/[os, strformat, sequtils, algorithm, sets],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc itemSet(snes: SnesBus): HashSet[int] =
  result = initHashSet[int]()
  # Broad scan $9900..$9A00 and party name region $99CE for item-like bytes
  for off in 0x9900 .. 0x9A80:
    let v = readU8(snes, off)
    if v > 0 and v < 0xF0: result.incl v
  # Also $98xx character blocks
  for off in 0x98C0 .. 0x99CD:
    let v = readU8(snes, off)
    if v > 0 and v < 0xF0: result.incl v

proc main() =
  var paths = @[
    "bin/states/llm/midgame_approach.state",
    "bin/states/llm/poo_joined.state",
    "bin/states/llm/poo_very_deep.state",
    "bin/states/llm/captain_west.state"
  ]
  var sets: seq[(string, HashSet[int])]
  for p in paths:
    if not fileExists(p): continue
    let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(p)), snes, c)
    let s = itemSet(snes)
    sets.add (extractFilename(p), s)
    echo extractFilename(p), " unique_itemish=", s.len, " ma=", magicantPercent(snes)
  # Items only in very_deep not in midgame
  if sets.len >= 3:
    let mid = sets[0][1]
    let late = sets[2][1]
    var onlyLate: seq[int]
    for x in late:
      if x notin mid: onlyLate.add x
    onlyLate.sort()
    echo "only_in_poo_very_deep_not_midgame: ", onlyLate.mapIt(fmt"0x{it:02X}").join(" ")
  echo "OK inventory scan (candidate IDs only — not names)"

when isMainModule: main()
