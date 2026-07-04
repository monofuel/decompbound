## Tests for the region registry: structural invariants that hold without
## the gold ROM, and per-region byte verification against gold when present.

import
  std/[algorithm, os],
  decompbound/regions

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  RomSize = 3 * 1024 * 1024

block structuralInvariants:
  var all = allRegions()
  doAssert all.len > 200, "registry suspiciously small: " & $all.len

  var names: seq[string]
  for region in all:
    names.add region.name
    doAssert region.data.len > 0, region.name & " generated no bytes"
    doAssert region.offset >= 0
    doAssert region.offset + region.data.len <= RomSize,
      region.name & " exceeds ROM bounds"
  doAssert "header" in names
  doAssert "resetVectors" in names

  # No two regions may overlap: sort by offset, check adjacency.
  all.sort(proc(a, b: RomRegion): int = cmp(a.offset, b.offset))
  for i in 1..<all.len:
    doAssert all[i - 1].offset + all[i - 1].data.len <= all[i].offset,
      "overlap between regions at 0x" & $all[i - 1].offset &
      " and 0x" & $all[i].offset

block perRegionGoldMatch:
  # Every region must match the gold ROM byte-for-byte, individually.
  # Stronger than compare.nim's aggregate stats: a failure names the region.
  # Only runs locally where the (gitignored, copyrighted) ROM exists.
  if fileExists(GoldMasterRom):
    let gold = readFile(GoldMasterRom)
    doAssert gold.len == RomSize
    for region in allRegions():
      for i in 0..<region.data.len:
        doAssert gold[region.offset + i].uint8 == region.data[i],
          region.name & " mismatch at file offset 0x" &
          $(region.offset + i)
