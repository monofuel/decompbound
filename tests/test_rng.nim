## Gold-gate the documented RNG routine: earthboundRandom() must match gold.

import
  std/unittest,
  decompbound/snes_src/rng,
  decompbound/rom_pipeline

const
  RngRoutineStart = 0x8E9A
  RngRoutineLen = 0x8ED2 - 0x8E9A   # 56 bytes: PHP .. RTL

suite "EarthBound RNG routine":
  test "earthboundRandom() matches the gold ROM bytes byte-for-byte":
    let curated = earthboundRandom()
    doAssert curated.len == RngRoutineLen
    if not goldBaseromAvailable():
      echo "[test_rng] skip gold compare (no baserom)"
    else:
      let gold = readGoldBaserom()
      let slice = gold[RngRoutineStart ..< RngRoutineStart + RngRoutineLen]
      check curated == slice

echo "[test_rng] ok"
