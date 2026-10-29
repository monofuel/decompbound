## ROM-backed overworld CHR, arrangements, and base palette selection.
## Original resource loader: $C008C3..$C00AA0. Palette loader: $C007B6.
## $C009AD decodes CHR; $C009CB/$C009D1 request its first $7000 bytes for upload. Original
## streams contain one extra decoded byte, independently verified but unused
## by that upload. $C00ED6 duplicates tile IDs below $180 onto BG2 using its
## separate CHR base at byte $4000. Base palettes and arrangement substitutions
## use clear event flags, matching $C007B6 and $C006F2 respectively.

import
  std/[sets, strformat, tables],
  ./gfx_lz

type
  WorldMapResource* = ref object
    id*, graphicsFile*, arrangementsFile*, decodedGraphicsLength*: int
    baseReplacementCount*: int
    graphics*: seq[uint8]
    arrangements*: seq[array[16, uint16]]
  WorldMapPalette* = object
    colors*: array[128, uint16]
    sourceFile*, resolvedFile*, storyFlag*, objPaletteSource*: int
    redirected*: bool
  WorldMapAssets* = ref object
    rom: seq[uint8]
    resources: array[20, WorldMapResource]
    palettes: Table[(int, int), WorldMapPalette]

const
  WorldDrawingTilesetCount* = 20
  WorldLogicalTilesetCount* = 32
  WorldChrBytes* = 0x7000
  WorldChrTileCount* = WorldChrBytes div 32
  WorldArrangementCells* = 16
  WorldBg2TileCount* = 0x180
  WorldBg2ChrTileOffset* = 0x200
  WorldPaletteBytes* = 0xC0
  WorldPaletteFirstColor* = 32
  DrawingMapFile* = 0x2F101B
  WorldChrPointersFile* = 0x2F105B
  WorldArrangementPointersFile* = 0x2F10AB
  WorldPalettePointersFile* = 0x2F10FB
  WorldArrangementReplacementPointersFile* = 0x101598
  HiRomMask = 0x3FFFFF
  FarPointerBytes = 4
  ChrTileBytes = 32
  TileSide = 8
  ArrangementBytes = WorldArrangementCells * 2
  PaletteSelectorCount = 8
  EventFlagInverted = 0x8000
  AlternatePaletteOffset = 0x20
  ObjPaletteSourceOffset = 0x40
  MaximumDecodedBytes = 0x8000
  TileIndexMask = 0x03FF
  LzTerminator = 0xFF
  LzLongMarker = 0xE0
  LzShortLengthMask = 0x1F
  ReplacementBankFile = 0x100000
  ReplacementBankBytes = 0x10000
  ReplacementHeaderBytes = 4
  ReplacementPairBytes = 4

proc requireRange(rom: openArray[uint8], offset, size: int) =
  ## Reject original references whose complete payload is outside the supplied ROM.
  if offset < 0 or size < 0 or offset > rom.len or size > rom.len - offset:
    raise newException(ValueError, &"Map resource range 0x{offset:X}+0x{size:X} exceeds ROM.")

proc readWord(rom: openArray[uint8], offset: int): uint16 =
  ## Read one bounds-checked original little-endian word.
  rom.requireRange(offset, 2)
  uint16(rom[offset]) or (uint16(rom[offset + 1]) shl 8)

proc readFar(rom: openArray[uint8], offset: int): int =
  ## Resolve a four-byte table entry's three-byte HiROM source address.
  rom.requireRange(offset, FarPointerBytes)
  let source = rom.readWord(offset).int or (rom[offset + 2].int shl 16)
  if source shr 16 < 0xC0:
    raise newException(ValueError, &"Invalid map resource HiROM address ${source:06X}.")
  result = source and HiRomMask
  rom.requireRange(result, 1)

proc streamExtent(rom: openArray[uint8], offset: int): int =
  ## Validate original compression references and cap output at its WRAM staging bank half.
  rom.requireRange(offset, 1)
  var
    position = offset
    outputBytes = 0
  while position < rom.len:
    let commandByte = rom[position].int
    inc position
    if commandByte == LzTerminator:
      return position - offset
    var
      command = commandByte shr 5
      length = (commandByte and LzShortLengthMask) + 1
    if (commandByte and LzLongMarker) == LzLongMarker:
      rom.requireRange(position, 1)
      command = (commandByte shr 2) and 7
      length = (((commandByte and 3) shl 8) or rom[position].int) + 1
      inc position
    let
      outputLength = if command == 2: length * 2 else: length
      operandBytes = if command == 0: length elif command in [2, 4, 5, 6, 7]: 2 else: 1
    rom.requireRange(position, operandBytes)
    if outputLength > MaximumDecodedBytes - outputBytes:
      raise newException(ValueError, "Map resource exceeds its 0x8000-byte staging range.")
    if command in [4, 5, 6, 7]:
      let backref = (rom[position].int shl 8) or rom[position + 1].int
      if backref >= outputBytes or (command == 6 and backref < length - 1):
        raise newException(ValueError, "Map resource has an invalid graphics back-reference.")
    outputBytes += outputLength
    position += operandBytes
  raise newException(ValueError, "Map graphics stream is missing its terminator.")

proc decompress(rom: openArray[uint8], offset: int): seq[uint8] =
  ## Decode a bounded, prevalidated original stream and require a clean terminator.
  let
    extent = rom.streamExtent(offset)
    decoded = decodeWithConsumed(rom.toOpenArray(offset, offset + extent - 1))
  if not decoded.clean:
    raise newException(ValueError, &"Malformed map graphics stream at 0x{offset:06X}.")
  decoded.data

proc newWorldMapAssets*(rom: seq[uint8]): WorldMapAssets =
  ## Bind validated resource tables to one caller-owned normalized ROM image.
  rom.requireRange(WorldPalettePointersFile,
    WorldLogicalTilesetCount * FarPointerBytes)
  WorldMapAssets(rom: rom)

proc drawingTileset*(assets: WorldMapAssets, logicalTileset: int): int =
  ## Translate the sector's logical graphics family using original $EF101B.
  if logicalTileset notin 0 ..< WorldLogicalTilesetCount:
    raise newException(ValueError, "Logical map tileset is outside 0..31.")
  result = assets.rom.readWord(DrawingMapFile + logicalTileset * 2).int
  if result notin 0 ..< WorldDrawingTilesetCount:
    raise newException(ValueError, "Logical map tileset references an invalid drawing tileset.")

proc applyBaseReplacements(assets: WorldMapAssets, resource: WorldMapResource) =
  ## Reproduce $C006F2/$C0067E arrangement substitutions with every event flag clear.
  var position = ReplacementBankFile + assets.rom.readWord(
    WorldArrangementReplacementPointersFile + resource.id * 2).int
  while true:
    if position < ReplacementBankFile or position > ReplacementBankFile + ReplacementBankBytes - 2:
      raise newException(ValueError, "Map arrangement replacement list is missing its bank-local terminator.")
    assets.rom.requireRange(position, 2)
    let condition = assets.rom.readWord(position).int
    if condition == 0:
      break
    assets.rom.requireRange(position, ReplacementHeaderBytes)
    let
      count = assets.rom.readWord(position + 2).int
      pairs = position + ReplacementHeaderBytes
      pairBytes = count * ReplacementPairBytes
    if position < ReplacementBankFile or
        pairs > ReplacementBankFile + ReplacementBankBytes or
        pairBytes > ReplacementBankFile + ReplacementBankBytes - pairs:
      raise newException(ValueError, "Map arrangement replacement list leaves its original ROM bank.")
    assets.rom.requireRange(pairs, pairBytes)
    # $C006F2 compares the false flag result with bit 15: clear-bit records
    # apply on the base state, while set-bit records retain the decoded layout.
    if condition < EventFlagInverted:
      for pair in 0 ..< count:
        let
          offset = pairs + pair * ReplacementPairBytes
          destination = assets.rom.readWord(offset).int
          source = assets.rom.readWord(offset + 2).int
        if destination notin 0 ..< resource.arrangements.len or
            source notin 0 ..< resource.arrangements.len:
          raise newException(ValueError, "Map arrangement replacement references an absent arrangement.")
        resource.arrangements[destination] = resource.arrangements[source]
        inc resource.baseReplacementCount
    position = pairs + pairBytes

proc resource*(assets: WorldMapAssets, drawingTileset: int): WorldMapResource =
  ## Decode one graphics family lazily, preserving original 4-by-4 tile order.
  if drawingTileset notin 0 ..< WorldDrawingTilesetCount:
    raise newException(ValueError, "Drawing map tileset is outside 0..19.")
  if assets.resources[drawingTileset] != nil:
    return assets.resources[drawingTileset]
  let
    graphicsFile = assets.rom.readFar(WorldChrPointersFile + drawingTileset * FarPointerBytes)
    arrangementsFile = assets.rom.readFar(WorldArrangementPointersFile + drawingTileset * FarPointerBytes)
    graphics = assets.rom.decompress(graphicsFile)
    arrangements = assets.rom.decompress(arrangementsFile)
  if graphics.len < WorldChrBytes:
    raise newException(ValueError, "Map CHR stream is shorter than the original 0x7000-byte upload.")
  if arrangements.len == 0 or arrangements.len mod ArrangementBytes != 0 or
      arrangements.len > MaximumDecodedBytes:
    raise newException(ValueError, "Map arrangement stream has an invalid extent.")
  result = WorldMapResource(id: drawingTileset, graphicsFile: graphicsFile,
    arrangementsFile: arrangementsFile, decodedGraphicsLength: graphics.len,
    graphics: graphics[0 ..< WorldChrBytes],
    arrangements: newSeq[array[WorldArrangementCells, uint16]](
      arrangements.len div ArrangementBytes))
  for arrangement in 0 ..< result.arrangements.len:
    for tile in 0 ..< WorldArrangementCells:
      let word = arrangements.readWord(arrangement * ArrangementBytes + tile * 2)
      if (word and TileIndexMask).int >= WorldChrTileCount:
        raise newException(ValueError, "Map arrangement references a tile outside the CHR upload.")
      result.arrangements[arrangement][tile] = word
  assets.applyBaseReplacements(result)
  assets.resources[drawingTileset] = result

proc palette*(assets: WorldMapAssets, logicalTileset, paletteId: int): WorldMapPalette =
  ## Resolve original palette redirects with all event flags clear and return BG rows 2..7.
  if logicalTileset notin 0 ..< WorldLogicalTilesetCount or
      paletteId notin 0 ..< PaletteSelectorCount:
    raise newException(ValueError, "Map palette selector is outside its sector encoding.")
  let key = (logicalTileset, paletteId)
  if key in assets.palettes:
    return assets.palettes[key]
  let
    paletteBase = assets.rom.readFar(WorldPalettePointersFile + logicalTileset * FarPointerBytes)
    redirectBankBase = assets.rom.readFar(WorldPalettePointersFile) and 0x3F0000
  var
    source = paletteBase + paletteId * WorldPaletteBytes
    visited: HashSet[int]
  result.sourceFile = source
  assets.rom.requireRange(source, WorldPaletteBytes)
  result.storyFlag = assets.rom.readWord(source).int
  while true:
    assets.rom.requireRange(source, WorldPaletteBytes)
    if source in visited:
      raise newException(ValueError, "Map palette redirect contains a cycle.")
    visited.incl(source)
    let flag = assets.rom.readWord(source).int
    if flag == 0 or flag > EventFlagInverted:
      break
    # $C007B6 redirects when the tested event flag equals the encoded polarity.
    # A zero-initialized event store clears all numbered flags, so positive
    # selectors (and the exact $8000 sentinel) follow the alternate address.
    source = redirectBankBase + assets.rom.readWord(source + AlternatePaletteOffset).int
    result.redirected = true
  result.resolvedFile = source
  result.objPaletteSource = assets.rom.readWord(source + ObjPaletteSourceOffset).int
  for index in 0 ..< WorldPaletteBytes div 2:
    result.colors[WorldPaletteFirstColor + index] = assets.rom.readWord(source + index * 2)
  assets.palettes[key] = result

proc pixelIndex*(resource: WorldMapResource, tile, x, y: int): uint8 =
  ## Read an original planar 4bpp pixel before arrangement flips and palette selection.
  if tile notin 0 ..< WorldChrTileCount or x notin 0 ..< TileSide or y notin 0 ..< TileSide:
    raise newException(ValueError, "Map CHR pixel is outside the original upload.")
  let
    offset = tile * ChrTileBytes + y * 2
    shift = 7 - x
  for plane in 0 ..< 4:
    let byteOffset = offset + (plane div 2) * 16 + plane mod 2
    result = result or (((resource.graphics[byteOffset] shr shift) and 1) shl plane)
