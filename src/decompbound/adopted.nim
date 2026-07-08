## Hand-curated ROM regions that replace generated scaffolding.
## convert_all.nim skips these file offsets so re-generation cannot clobber
## adopted modules. See docs/goal-1.5.md.

import
  ./sram_piracy

const
  ## File offsets owned by curated modules (not regenerated).
  AdoptedOffsets* = [SramPiracyCheckOffset]

proc isAdoptedOffset*(offset: int): bool =
  ## True when a file offset is covered by a curated module.
  result = offset in AdoptedOffsets

proc allAdoptedRegions*(): seq[tuple[name: string, offset: int, data: seq[uint8]]] =
  ## Every hand-curated code region, assembled from named source.
  result.add (name: "sramMirrorPiracyCheck",
              offset: SramPiracyCheckOffset,
              data: sramMirrorPiracyCheck())
