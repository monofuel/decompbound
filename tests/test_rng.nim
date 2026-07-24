## Gold-gate the documented RNG routine: earthboundRandom() (snesAsm) must be
## byte-identical to the gold ROM's advance routine at file 0x8E9A..0x8ED1
## (SNES $C08E9A, 56 bytes: PHP .. RTL).
##
## The gold bytes come from the region registry (every region is byte-exact vs
## the ROM), sliced by file offset — so this stays valid no matter how region
## boundaries shift as more code is traced.

import
  std/unittest,
  ../src/decompbound/snes_src/rng,
  ../src/decompbound/regions

const
  RngRoutineStart = 0x8E9A
  RngRoutineLen = 0x8ED2 - 0x8E9A   # 56 bytes: PHP .. RTL

proc goldRngBytes(): seq[uint8] =
  ## Extract the 56-byte RNG advance routine from whichever implemented region
  ## covers file offset 0x8E9A.
  for region in allRegions():
    if region.offset <= RngRoutineStart and
       RngRoutineStart + RngRoutineLen <= region.offset + region.data.len:
      let lo = RngRoutineStart - region.offset
      return region.data[lo ..< lo + RngRoutineLen]
  return @[]

suite "EarthBound RNG routine":
  test "earthboundRandom() matches the gold ROM bytes byte-for-byte":
    let curated = earthboundRandom()
    let gold = goldRngBytes()
    check gold.len == RngRoutineLen   # region actually covers the routine
    check curated.len == RngRoutineLen
    check curated == gold
