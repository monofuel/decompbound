## Central registry of implemented ROM regions.
## The ROM builder and the compare harness both derive from this list, so
## coverage claims and generated output can never drift apart.
##
## Code regions live in generated/ — one module per traced code region,
## produced by tools/convert_all.nim from gold ROM disassembly. Header and
## vectors are hand-maintained data declarations.

import
  ./[common, header, vectors],
  ./generated/registry

type
  RomRegion* = object
    name*: string
    offset*: int
    data*: seq[uint8]

proc allRegions*(): seq[RomRegion] =
  ## Build every implemented region: code assembled from disassembled
  ## mnemonics, plus the header and vector data declarations.
  result.add RomRegion(name: "header", offset: HiRomHeaderOffset,
                       data: generateEarthboundHeader())
  result.add RomRegion(name: "resetVectors", offset: ResetVectorOffset,
                       data: generateResetVectors())
  for (offset, data) in allCodeRegions():
    result.add RomRegion(name: "code", offset: offset, data: data)
