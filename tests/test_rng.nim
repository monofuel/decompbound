## Gold-gate the documented RNG routine: earthboundRandom() (snesAsm) must be
## byte-identical to the verified disassembly's first 56 bytes (the advance
## routine, $C08E9A..$C08ED1, before the traced region's later routines).

import
  std/unittest,
  ../src/decompbound/rng,
  ../src/decompbound/generated/code_008E9A

const RngRoutineLen = 0x8ED2 - 0x8E9A   # 56 bytes: PHP .. RTL

suite "EarthBound RNG routine":
  test "earthboundRandom() matches the gold disassembly prefix byte-for-byte":
    let curated = earthboundRandom()
    let gold = generateCode008E9A()
    check curated.len == RngRoutineLen
    check gold.len >= RngRoutineLen
    check curated == gold[0 ..< RngRoutineLen]
