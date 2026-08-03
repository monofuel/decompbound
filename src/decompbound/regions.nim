## Central registry of implemented ROM regions (phase-2).
## Code no longer comes from generated/* banks — those were deleted at M2.5.
## Vanilla whole-ROM rebuild is manifest + extracted/ (rom_pipeline). This
## registry still exposes header, vectors, adopted snes_src, and baserom
## extract claims for tools that need named region bytes without a full ROM.

import
  ./[adopted, baserom_extract, common, header, vectors]

type
  RomRegion* = object
    name*: string
    offset*: int
    data*: seq[uint8]

iterator eachRegion*(): RomRegion =
  ## Stream every still-assembled or extracted named region.
  yield RomRegion(name: "header", offset: HiRomHeaderOffset,
                   data: generateEarthboundHeader())
  yield RomRegion(name: "resetVectors", offset: ResetVectorOffset,
                   data: generateResetVectors())
  for region in allAdoptedRegions():
    yield RomRegion(name: region.name, offset: region.offset,
                    data: region.data)
  for region in allBaseromExtractRegions():
    yield RomRegion(name: region.name, offset: region.offset,
                    data: region.data)

proc allRegions*(): seq[RomRegion] =
  ## Collect every named region (adopted + extracts + header/vectors).
  for region in eachRegion():
    result.add region
