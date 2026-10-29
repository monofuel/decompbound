import
  std/[math, unittest],
  decompbound/[common, world_map, world_map_assets, world_map_layout]

const
  PaletteTwo = 0x0800'u16
  HighPriority = 0x2000'u16
  HorizontalFlip = 0x4000'u16
  VerticalFlip = 0x8000'u16

proc authoredResource(): WorldMapResource =
  ## Construct tiny authored pixel patterns in a synthetic SNES tile bank.
  result = WorldMapResource(graphics: newSeq[uint8](WorldChrBytes))
  # Base tile1 has index1 at its upper-left corner and index2 at bottom-right.
  result.graphics[32] = 0x80
  result.graphics[32 + 15] = 1
  # The matching BG2 overlay uses index4 at upper-left and is transparent elsewhere.
  result.graphics[(512 + 1) * 32 + 16] = 0x80
  # Tile384 has no BG2 overlay; its visible pixel uses palette index8.
  result.graphics[384 * 32 + 17] = 0x80

proc putWord(rom: var seq[uint8], offset, value: int) =
  ## Write an authored little-endian fixture field without copying game data.
  rom[offset] = uint8(value and 255)
  rom[offset + 1] = uint8((value shr 8) and 255)

proc authoredLayoutRom(): seq[uint8] =
  ## Build separated row streams and sector selectors in a synthetic ROM image.
  result = newSeq[uint8](EarthboundRomSize)
  for row in 0 ..< 8:
    let source = 0x100000 + row * 0x2800
    result.putWord(MapRowPointerFile + row * 4, source and 65535)
    result[MapRowPointerFile + row * 4 + 2] = uint8((source shr 16) or 0xC0)
  result[0x100000] = 0xA5
  result[MapHighBitsFirstFile] = 3
  result[RegionResourceFile] = uint8((5 shl 3) or 6)
  result.putWord(MapTilesetDrawingFile + 5 * 2, 7)
  result.putWord(RegionAttributeFile, 0xBEEF)

suite "World map composition and checked metadata":
  test "original two-layer threshold, opacity, priority, flips, and palette rows":
    let resource = authoredResource()
    check tileColorIndex(resource, PaletteTwo or 1, 0, 0) == 32 + 4
    check tileColorIndex(resource, PaletteTwo or HighPriority or 1, 0, 0) == 32 + 1
    check tileColorIndex(resource, PaletteTwo or 1, 7, 7) == 32 + 2
    check tileColorIndex(resource, PaletteTwo or 1, 3, 3) == 0
    check tileColorIndex(resource, PaletteTwo or HorizontalFlip or 1, 7, 0) == 32 + 4
    check tileColorIndex(resource, PaletteTwo or VerticalFlip or 1, 0, 7) == 32 + 4
    check tileColorIndex(resource, PaletteTwo or HorizontalFlip or VerticalFlip or 1, 7, 7) == 32 + 4
    check tileColorIndex(resource, PaletteTwo or 384, 0, 0) == 32 + 8
    expect ValueError: discard tileColorIndex(resource, 1, -1, 0)
    expect ValueError: discard tileColorIndex(resource, 1, 0, 8)

  test "interleaved placement bytes and packed high bits are distinct from region metadata":
    let layout = newWorldMapLayout(authoredLayoutRom())
    let cell = layout.cellAt(31, 31)
    check cell.arrangementId == 0x3A5
    check cell.region.mapTilesetId == 5
    check cell.region.drawingTilesetId == 7
    check cell.region.paletteId == 6
    check cell.region.attributes == 0xBEEF
    check layout.regionAt(255, 127).index == 0
    check layout.regionAt(256, 128).index == 33
    check layout.regionAt(WorldWidth - 1, WorldHeight - 1).index == RegionCount - 1
    expect ValueError: discard layout.cellAt(-1, 0)
    expect ValueError: discard layout.cellAt(WorldWidth, WorldHeight)

  test "invalid drawing selectors and row pointers fail without synthetic scenery":
    var rom = authoredLayoutRom()
    rom.putWord(MapTilesetDrawingFile + 5 * 2, DrawingTilesetCount)
    expect ValueError: discard newWorldMapLayout(rom)
    rom = authoredLayoutRom()
    rom[MapRowPointerFile + 2] = 0
    expect ValueError: discard newWorldMapLayout(rom)
    expect ValueError: discard newWorldMapLayout(@[0'u8])

  test "truncated compressed resources and invalid backreferences are rejected":
    var rom = newSeq[uint8](EarthboundRomSize)
    let source = 0x200000
    rom.putWord(WorldChrPointersFile, 0)
    rom[WorldChrPointersFile + 2] = 0xE0
    rom[source] = 0x80
    expect ValueError: discard newWorldMapAssets(rom).resource(0)
    rom[source] = 0xFF
    expect ValueError: discard newWorldMapAssets(rom).resource(0)

  test "palette redirect loops are rejected instead of silently selecting colors":
    var rom = newSeq[uint8](EarthboundRomSize)
    let source = 0x200000
    rom[WorldPalettePointersFile + 2] = 0xE0
    rom.putWord(source, 1)
    rom.putWord(source + 0x20, 0)
    expect ValueError: discard newWorldMapAssets(rom).palette(0, 0)

  test "extreme finite camera coordinates remain margins without float-to-int overflow":
    let atlas = WorldMapAtlas(width: WorldWidth, height: WorldHeight)
    let first = atlas.renderViewport(1e300, 1e300, 0.0625, 2, 2)
    let second = atlas.renderViewport(-1e300, -1e300, 1e-300, 2, 2)
    check first.data == second.data
    expect ValueError: discard atlas.renderViewport(Inf, 0, 1, 2, 2)
    expect ValueError: discard atlas.renderViewport(0, 0, NaN, 2, 2)
