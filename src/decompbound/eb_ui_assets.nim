import
  pixie,
  ./[eb_ui_font, eb_ui_meters, eb_ui_status, gfx_lz, ppu]

type
  EbUiAssets* = ref object
    fonts*: array[FontDescriptorCount, EbUiFont]
    graphics*: EbMeterAssets
    statuses*: EbUiStatusTables
    palettes*: array[5, array[32, uint16]]
    labels*: array[8, uint8]
    flavorOverlay*: seq[uint8]
    statusIcons*: seq[uint8]

const
  UiFlavorCount* = 5
  UiFlavorWram* = 0x99CD
  UiFrameCounterWram* = 0x0002
  FlavorOffsets = 0x201FB9
  FlavorPalettes = 0x201FC8
  LabelTiles = 0x03E3F8
  FlavorOverlay = 0x200754
  FlavorOverlayFirstTile = 0x10
  FlavorOverlayTiles = 7
  PaletteWords = 32
  PaletteColors = 4
  TileSize = 8
  TileBytes = 16
  MeterVramBase = 0x200
  MeterRelocation = 0x100
  TileIndexMask = 0x03FF
  PaletteShift = 10
  FlipHorizontal = 0x4000'u16
  FlipVertical = 0x8000'u16
  IconSourceTable = 0x045A89
  IconSourceCount = 49
  GeneratedIconFirst = 0x2C0
  GeneratedIconTiles = 32
  IconBottomRow = 16
  EmptyIconSelector = 0x20
  BackgroundTile = 7

proc sourceTileWord(assets: EbUiAssets, tile, row: int): uint16 =
  ## Read the common atlas after the backward copy at original $C47C5F.
  let
    sourceTile = if tile >= MeterVramBase: tile - MeterRelocation else: tile
    offset = sourceTile * TileBytes + row * 2
  if sourceTile < 0 or offset + 1 >= assets.graphics.tiles.len:
    raise newException(ValueError, "EarthBound UI tile is outside the decoded atlas: " & $tile)
  assets.graphics.tiles[offset].uint16 or (assets.graphics.tiles[offset + 1].uint16 shl 8)

proc loadEbUiAssets*(rom: openArray[uint8]): EbUiAssets =
  ## Decode the common UI stream and five flavor palettes used by $C47FCF.
  if rom.len < FlavorPalettes + UiFlavorCount * PaletteWords * 2:
    raise newException(ValueError, "ROM is too short for EarthBound UI palettes")
  result = EbUiAssets(graphics: loadEbMeterAssets(rom), statuses: loadEbUiStatusTables(rom))
  for id in 0 ..< result.fonts.len:
    result.fonts[id] = loadEbUiFont(rom, id)
  for flavor in 0 ..< UiFlavorCount:
    let
      entry = FlavorOffsets + flavor * 3
      offset = rom[entry].int or (rom[entry + 1].int shl 8)
      base = FlavorPalettes + offset
    if base + PaletteWords * 2 > rom.len:
      raise newException(ValueError, "EarthBound UI flavor palette is outside the ROM")
    for index in 0 ..< PaletteWords:
      result.palettes[flavor][index] = rom[base + index * 2].uint16 or
        (rom[base + index * 2 + 1].uint16 shl 8)
  for index in 0 ..< result.labels.len: result.labels[index] = rom[LabelTiles + index]
  let overlay = decodeWithConsumed(rom.toOpenArray(FlavorOverlay, rom.high))
  if not overlay.clean or overlay.data.len != FlavorOverlayTiles * TileBytes:
    raise newException(ValueError, "Invalid EarthBound flavored-window graphics")
  result.flavorOverlay = overlay.data
  # Original $C47EA2 builds the status icons by merging each source with tile 7.
  result.statusIcons = newSeq[uint8](GeneratedIconTiles * TileBytes)
  var column = 0
  for index in 0 ..< IconSourceCount:
    let
      offset = IconSourceTable + index * 2
      selector = rom[offset].int or (rom[offset + 1].int shl 8)
    if selector == 0: break
    if selector == EmptyIconSelector: continue
    if column >= IconBottomRow:
      raise newException(ValueError, "EarthBound status icon table exceeds its tile row")
    let source = selector + (selector and 0xFFF0)
    for half in 0 .. 1:
      for row in 0 ..< TileSize:
        let
          glyph = result.sourceTileWord(source + half * IconBottomRow, row)
          background = result.sourceTileWord(BackgroundTile + half * IconBottomRow, row)
          plane1 = glyph shr 8
          target = (column + half * IconBottomRow) * TileBytes + row * 2
        result.statusIcons[target] = uint8((background and 255) or (plane1 xor 255))
        result.statusIcons[target + 1] = plane1.uint8
    inc column

proc uiColors*(assets: EbUiAssets, flavor: int, flash: bool): array[32, ColorRGBA] =
  ## Reproduce the flavor palette and the palette-five blink at $C3E450.
  if flavor notin 1 .. UiFlavorCount:
    raise newException(ValueError, "Invalid EarthBound window flavor: " & $flavor)
  for index, value in assets.palettes[flavor - 1]:
    result[index] = bgr555ToColor(value)
  result[0] = bgr555ToColor(0)
  if flash:
    for index in 0 ..< PaletteColors:
      result[5 * PaletteColors + index] = result[PaletteColors + index]

proc uiTilePixel*(assets: EbUiAssets, tile, x, y: int, flavor = 1): int =
  ## Read a common 2bpp tile with the original $C0B5AE meter relocation.
  if x < 0 or x >= TileSize or y < 0 or y >= TileSize: return 0
  if tile >= GeneratedIconFirst and tile < GeneratedIconFirst + GeneratedIconTiles:
    let offset = (tile - GeneratedIconFirst) * TileBytes + y * 2
    return int((assets.statusIcons[offset] shr (7 - x)) and 1) or
      (int((assets.statusIcons[offset + 1] shr (7 - x)) and 1) shl 1)
  if flavor > 1 and tile >= FlavorOverlayFirstTile and
      tile < FlavorOverlayFirstTile + FlavorOverlayTiles:
    let offset = (tile - FlavorOverlayFirstTile) * TileBytes + y * 2
    return int((assets.flavorOverlay[offset] shr (7 - x)) and 1) or
      (int((assets.flavorOverlay[offset + 1] shr (7 - x)) and 1) shl 1)
  let word = assets.sourceTileWord(tile, y)
  int((word shr (7 - x)) and 1) or (int((word shr (15 - x)) and 1) shl 1)

proc paintEbTile*(image: Image, assets: EbUiAssets, word: uint16,
    x, y: int, colors: array[32, ColorRGBA], flavor = 1) =
  ## Paint one native tilemap entry, preserving transparent pixels and flips.
  let
    tile = word.int and TileIndexMask
    palette = ((word.int shr PaletteShift) and 7) * PaletteColors
  for row in 0 ..< TileSize:
    let py = y + row
    if py < 0 or py >= image.height: continue
    for column in 0 ..< TileSize:
      let px = x + column
      if px < 0 or px >= image.width: continue
      let
        sx = if (word and FlipHorizontal) != 0: TileSize - column - 1 else: column
        sy = if (word and FlipVertical) != 0: TileSize - row - 1 else: row
        index = assets.uiTilePixel(tile, sx, sy, flavor)
      if index != 0: image[px, py] = colors[palette + index]
