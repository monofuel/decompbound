## Gold-gate the documented RNG routine assembled from asm/earthboundRandom.asm.

import
  std/unittest,
  decompbound/[adopted, rom_pipeline]

const
  RngRoutineStart = RngAdvanceOffset
  RngRoutineLen = 56

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
