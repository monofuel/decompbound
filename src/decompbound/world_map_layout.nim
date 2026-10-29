## ROM-backed map arrangement identities and sector resource selectors.
## C0A156 reads 10-bit arrangement IDs; C00AC5/C00BDC bound the grid.
## Their input coordinates count eight-pixel characters and divide by four,
## establishing 32-pixel placements and a 256-by-320 placement atlas.
## C00B24/C00C35 select D7A800 sectors spanning eight by four placements.

import
  std/strformat,
  ./common

const
  MapCellPixels* = 32
  MapColumns* = 256
  MapRows* = 320
  WorldWidth* = MapColumns * MapCellPixels
  WorldHeight* = MapRows * MapCellPixels
  RegionCellColumns* = 8
  RegionCellRows* = 4
  RegionWidth* = RegionCellColumns * MapCellPixels
  RegionHeight* = RegionCellRows * MapCellPixels
  RegionColumns* = MapColumns div RegionCellColumns
  RegionRows* = MapRows div RegionCellRows
  RegionCount* = RegionColumns * RegionRows
  MapRowPointerFile* = 0x042F64
  MapHighBitsFirstFile* = 0x175000
  MapHighBitsSecondFile* = 0x178000
  RegionResourceFile* = 0x17A800
  RegionAttributeFile* = 0x17B200
  MapTilesetDrawingFile* = 0x2F101B
  MapTilesetCount* = 32
  DrawingTilesetCount* = 20
  InterleavedRows = 8
  HighBitsRows = 4
  PointerStride = 4
  PaletteBits = 3
  PaletteMask = (1 shl PaletteBits) - 1
  HighBitsPerPlacement = 2
  HighBitsMask = (1 shl HighBitsPerPlacement) - 1
  HiRomFileMask = 0x3FFFFF

type
  WorldMapRegion* = object
    ## One 256-by-128-pixel sector's original resource selection.
    index*, column*, row*, x*, y*: int
    mapTilesetId*, drawingTilesetId*, paletteId*: int
    resourceFileOffset*, attributeFileOffset*: int
    attributes*: uint16
  WorldMapCell* = object
    ## One 32-by-32-pixel map placement and its source coordinates.
    column*, row*, x*, y*, arrangementId*: int
    lowByteFileOffset*, highBitsFileOffset*, highBitsShift*: int
    region*: WorldMapRegion
  WorldMapLayout* = ref object
    ## Immutable decoded placement IDs and selectors owned by a single ROM.
    arrangements*: seq[uint16]
    regions*: seq[WorldMapRegion]
    rowPointerFiles*: array[InterleavedRows, int]

proc readWord(rom: openArray[uint8], fileOffset: int): int =
  ## Read a checked little-endian ROM word.
  if fileOffset < 0 or fileOffset > rom.len - 2:
    raise newException(ValueError, &"Map word outside ROM at {fileOffset:06X}.")
  rom[fileOffset].int or (rom[fileOffset + 1].int shl 8)

proc rowFileOffset*(rowPointers: array[InterleavedRows, int], column, row: int): int =
  ## Reproduce C0A185..C0A1A9's row-group index for the low arrangement byte.
  if column notin 0 ..< MapColumns or row notin 0 ..< MapRows:
    raise newException(ValueError, "Map cell is outside the atlas.")
  rowPointers[row mod InterleavedRows] + (row div InterleavedRows) * MapColumns + column

proc highBitsFileOffset*(column, row: int): int =
  ## Locate C0A192..C0A19F's packed two-bit arrangement extension.
  if column notin 0 ..< MapColumns or row notin 0 ..< MapRows:
    raise newException(ValueError, "Map cell is outside the atlas.")
  let base = if (row and HighBitsRows) == 0: MapHighBitsFirstFile else: MapHighBitsSecondFile
  base + (row div InterleavedRows) * MapColumns + column

proc regionIndex*(x, y: int): int =
  ## Convert native world pixels to the row-major sector index used by loaders.
  if x notin 0 ..< WorldWidth or y notin 0 ..< WorldHeight:
    raise newException(ValueError, "World position is outside the atlas.")
  (y div RegionHeight) * RegionColumns + x div RegionWidth

proc newWorldMapLayout*(rom: openArray[uint8]): WorldMapLayout =
  ## Decode every map placement and sector selector from an unheadered US ROM.
  if rom.len != EarthboundRomSize:
    raise newException(ValueError, "World map needs an unheadered 3 MiB US ROM.")
  result = WorldMapLayout(arrangements: newSeq[uint16](MapColumns * MapRows),
    regions: newSeq[WorldMapRegion](RegionCount))
  for row in 0 ..< result.rowPointerFiles.len:
    let
      offset = MapRowPointerFile + row * PointerStride
      pointer = readWord(rom, offset) or (rom[offset + 2].int shl 16)
      fileOffset = pointer and HiRomFileMask
    if pointer < 0xC00000 or fileOffset > rom.len - MapColumns * (MapRows div InterleavedRows):
      raise newException(ValueError, &"Invalid map row pointer {pointer:06X}.")
    result.rowPointerFiles[row] = fileOffset
  for row in 0 ..< MapRows:
    for column in 0 ..< MapColumns:
      let
        lowOffset = rowFileOffset(result.rowPointerFiles, column, row)
        highOffset = highBitsFileOffset(column, row)
        high = (rom[highOffset].int shr ((row mod HighBitsRows) * HighBitsPerPlacement)) and HighBitsMask
      result.arrangements[row * MapColumns + column] =
        uint16(rom[lowOffset].int or (high shl 8))
  for index in 0 ..< RegionCount:
    let
      resource = rom[RegionResourceFile + index].int
      mapTileset = resource shr PaletteBits
      drawingTileset = readWord(rom, MapTilesetDrawingFile + mapTileset * 2)
      column = index mod RegionColumns
      row = index div RegionColumns
    if drawingTileset notin 0 ..< DrawingTilesetCount:
      raise newException(ValueError, &"Invalid map drawing tileset {drawingTileset}.")
    result.regions[index] = WorldMapRegion(index: index, column: column,
      row: row, x: column * RegionWidth, y: row * RegionHeight,
      mapTilesetId: mapTileset, drawingTilesetId: drawingTileset,
      paletteId: resource and PaletteMask, resourceFileOffset: RegionResourceFile + index,
      attributeFileOffset: RegionAttributeFile + index * 2,
      attributes: uint16(readWord(rom, RegionAttributeFile + index * 2)))

proc regionAt*(layout: WorldMapLayout, x, y: int): WorldMapRegion =
  ## Inspect the original resource selector at a world-pixel position.
  layout.regions[regionIndex(x, y)]

proc cellAt*(layout: WorldMapLayout, x, y: int): WorldMapCell =
  ## Inspect a world-pixel position's arrangement identity and source bytes.
  let
    region = layout.regionAt(x, y)
    column = x div MapCellPixels
    row = y div MapCellPixels
  WorldMapCell(column: column, row: row, x: column * MapCellPixels,
    y: row * MapCellPixels, arrangementId: layout.arrangements[row * MapColumns + column].int,
    lowByteFileOffset: rowFileOffset(layout.rowPointerFiles, column, row),
    highBitsFileOffset: highBitsFileOffset(column, row),
    highBitsShift: (row mod HighBitsRows) * HighBitsPerPlacement, region: region)
