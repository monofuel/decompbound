## Central registry of implemented ROM regions.
## The ROM builder and the compare harness both derive from this list, so
## coverage claims and generated output can never drift apart.
##
## Code regions live in generated/ — one module per traced code region,
## produced by tools/convert_all.nim from gold ROM disassembly — except
## adopted ranges, which come from hand-curated modules (docs/goal-1.5.md).
## Header and vectors are hand-maintained data declarations.

import
  ./[adopted, common, header, vectors],
  ./generated/registry

type
  RomRegion* = object
    name*: string
    offset*: int
    data*: seq[uint8]

proc allRegions*(): seq[RomRegion] =
  ## Build every implemented region: curated adoptions, generated code
  ## assembled from disassembled mnemonics, plus header and vector data.
  result.add RomRegion(name: "header", offset: HiRomHeaderOffset,
                       data: generateEarthboundHeader())
  result.add RomRegion(name: "resetVectors", offset: ResetVectorOffset,
                       data: generateResetVectors())
  for region in allAdoptedRegions():
    result.add RomRegion(name: region.name, offset: region.offset,
                         data: region.data)
  for (offset, data) in allCodeRegions():
    if isAdoptedOffset(offset):
      continue
    result.add RomRegion(name: "code", offset: offset, data: data)
