import
  std/[math, strformat],
  pixie,
  ./[ppu, rom_pipeline, world_map_assets, world_map_layout]

type
  MapCellInfo* = object
    ## Identify the native placement, resource selectors, and inspected SNES tile.
    valid*: bool
    worldX*, worldY*, regionIndex*, regionX*, regionY*: int
    tileId*, tilesetId*, paletteId*, arrangementId*: int
    flags*: uint16
  RegionDrawing = object
    resource: WorldMapResource
    colors: array[128, ColorRGBX]
  WorldMapAtlas* = ref object
    ## Hold the verified atlas and its finite set of ROM-backed drawing resources.
    width*, height*, regionWidth*, regionHeight*, regionCount*: int
    layout*: WorldMapLayout
    assets*: WorldMapAssets
    drawings: seq[RegionDrawing]

const
  TilePixels = 8
  ArrangementColumns = MapCellPixels div TilePixels
  TileIndexMask = 0x03FF
  PaletteShift = 10
  PaletteMask = 7
  ColorsPerPalette = 16
  FlipHorizontal = 0x4000'u16
  FlipVertical = 0x8000'u16
  PriorityHigh = 0x2000'u16
  AtlasMargin = rgbx(10, 17, 31, 255)

proc newWorldMapAtlas*(rom: seq[uint8]): WorldMapAtlas =
  ## Validate all base-map placements and prepare actual per-sector palette colors.
  let
    layout = newWorldMapLayout(rom)
    assets = newWorldMapAssets(rom)
  result = WorldMapAtlas(width: WorldWidth, height: WorldHeight,
    regionWidth: RegionWidth, regionHeight: RegionHeight, regionCount: RegionCount,
    layout: layout, assets: assets, drawings: newSeq[RegionDrawing](RegionCount))
  for region in layout.regions:
    let
      resource = assets.resource(region.drawingTilesetId)
      palette = assets.palette(region.mapTilesetId, region.paletteId)
    result.drawings[region.index].resource = resource
    for index, color in palette.colors:
      result.drawings[region.index].colors[index] = bgr555ToColor(color).rgbx
  for row in 0 ..< MapRows:
    for column in 0 ..< MapColumns:
      let
        region = layout.regionAt(column * MapCellPixels, row * MapCellPixels)
        arrangement = layout.arrangements[row * MapColumns + column].int
        resource = result.drawings[region.index].resource
      if arrangement >= resource.arrangements.len:
        raise newException(ValueError,
          &"Map cell {column},{row} arrangement {arrangement} exceeds tileset {resource.id}.")

proc loadWorldMapAtlas*(path: string): WorldMapAtlas =
  ## Load the user's US ROM and decode the complete base atlas without emulating play.
  newWorldMapAtlas(readGoldBaserom(path))

proc regionOrigin*(atlas: WorldMapAtlas, index: int): tuple[x, y: int] =
  ## Locate one original sector in the continuous atlas.
  if index notin 0 ..< atlas.regionCount:
    raise newException(ValueError, "Map region is outside the atlas.")
  let region = atlas.layout.regions[index]
  (region.x, region.y)

proc arrangementWord(atlas: WorldMapAtlas, x, y: int):
    tuple[region, arrangement: int, word: uint16] =
  ## Select the original 8-pixel tile word inside its 32-pixel map arrangement.
  result.region = regionIndex(x, y)
  result.arrangement = atlas.layout.arrangements[
    (y div MapCellPixels) * MapColumns + x div MapCellPixels].int
  result.word = atlas.drawings[result.region].resource.arrangements[result.arrangement][
    ((y mod MapCellPixels) div TilePixels) * ArrangementColumns +
      (x mod MapCellPixels) div TilePixels]

proc inspect*(atlas: WorldMapAtlas, x, y: int): MapCellInfo =
  ## Inspect valid world pixels while representing canvas margins as unselected.
  if x notin 0 ..< atlas.width or y notin 0 ..< atlas.height: return
  let
    cell = atlas.arrangementWord(x, y)
    region = atlas.layout.regions[cell.region]
  MapCellInfo(valid: true, worldX: x, worldY: y, regionIndex: cell.region,
    regionX: region.column, regionY: region.row,
    tileId: cell.word.int and TileIndexMask, tilesetId: region.mapTilesetId,
    paletteId: region.paletteId, arrangementId: cell.arrangement,
    flags: cell.word and 0xE000'u16)

proc tileColorIndex*(resource: WorldMapResource, word: uint16, x, y: int): int =
  ## Composite C00EBD's BG1/BG2 tile publication with the mode-nine priority ladder.
  if x notin 0 ..< TilePixels or y notin 0 ..< TilePixels:
    raise newException(ValueError, "Map tile coordinates must be inside its eight pixels.")
  let
    tile = word.int and TileIndexMask
    sx = if (word and FlipHorizontal) != 0: TilePixels - 1 - x else: x
    sy = if (word and FlipVertical) != 0: TilePixels - 1 - y else: y
    main = resource.pixelIndex(tile, sx, sy).int
    palette = ((word.int shr PaletteShift) and PaletteMask) * ColorsPerPalette
  if main != 0 and (word and PriorityHigh) != 0: return palette + main
  # Original C00EBD duplicates IDs below384 into BG2 at CHR byte offset$4000.
  if tile < WorldBg2TileCount:
    let overlay = resource.pixelIndex(tile + WorldBg2ChrTileOffset, sx, sy).int
    if overlay != 0: return palette + overlay
  if main != 0: palette + main else: 0

proc pixel*(atlas: WorldMapAtlas, x, y: int): ColorRGBX =
  ## Compose one base scenery pixel from the original placement and resource selectors.
  if x notin 0 ..< atlas.width or y notin 0 ..< atlas.height: return AtlasMargin
  let
    cell = atlas.arrangementWord(x, y)
    drawing = addr atlas.drawings[cell.region]
    color = tileColorIndex(drawing.resource, cell.word, x mod TilePixels, y mod TilePixels)
  drawing.colors[color]

proc renderViewport*(atlas: WorldMapAtlas, centerX, centerY, zoom: float64,
    width, height: int): Image =
  ## Sample only the requested viewport at nearest-neighbor native pixel positions.
  if width <= 0 or height <= 0 or zoom <= 0 or zoom.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "Map viewport dimensions and zoom must be finite and positive.")
  if centerX.classify in {fcNan, fcInf, fcNegInf} or
      centerY.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "Map camera coordinates must be finite.")
  result = newImage(width, height)
  result.fill(AtlasMargin)
  let
    left = centerX - width.float64 / (2 * zoom)
    top = centerY - height.float64 / (2 * zoom)
  for y in 0 ..< height:
    let nativeY = top + y.float64 / zoom
    if not (nativeY >= 0 and nativeY < atlas.height.float64): continue
    let worldY = floor(nativeY).int
    for x in 0 ..< width:
      let nativeX = left + x.float64 / zoom
      if not (nativeX >= 0 and nativeX < atlas.width.float64): continue
      let worldX = floor(nativeX).int
      result[x, y] = atlas.pixel(worldX, worldY)
