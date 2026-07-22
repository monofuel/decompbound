## Hand-curated ROM regions that replace generated scaffolding.
## convert_all.nim carves these byte-ranges OUT of the traced code, so a curated
## module can sit MID-region (not only on a region boundary) and re-generation
## can never clobber it. Generated scaffold and adopted source therefore never
## overlap (tests/test_regions.nim enforces no-overlap + byte-exactness).
## See docs/goal-1.5.md.

import
  ./[sram_piracy, rng]

proc allAdoptedRegions*(): seq[tuple[name: string, offset: int, data: seq[uint8]]] =
  ## Every hand-curated code region, assembled from named source.
  result.add (name: "sramMirrorPiracyCheck",
              offset: SramPiracyCheckOffset,
              data: sramMirrorPiracyCheck())
  result.add (name: "earthboundRandom",
              offset: RngAdvanceOffset,
              data: earthboundRandom())

proc adoptedRanges*(): seq[tuple[start: int, last: int]] =
  ## Inclusive file-offset spans owned by curated modules, derived from the
  ## assembled length of each. convert_all carves these out of the traced code.
  for r in allAdoptedRegions():
    result.add (start: r.offset, last: r.offset + r.data.len - 1)

proc isAdoptedOffset*(offset: int): bool =
  ## True when a file offset is owned by a curated module.
  for r in adoptedRanges():
    if offset >= r.start and offset <= r.last:
      return true
  result = false
