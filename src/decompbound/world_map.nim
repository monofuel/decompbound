import
  std/[hashes, math, strformat],
  pixie,
  ./[ppu, rom_pipeline, world_map_assets, world_map_layout, world_map_story]

export world_map_story

type
  MapCellInfo* = object
    ## Identify the native placement, resource selectors, and inspected SNES tile.
    valid*: bool
    worldX*, worldY*, regionIndex*, regionX*, regionY*: int
    tileId*, tilesetId*, paletteId*, arrangementId*: int
    flags*: uint16
  RegionDrawing = object
    resource: WorldMapResource
    paletteKey: int
    colors: array[128, ColorRGBX]
  WorldMapAtlas* = ref object
    ## Hold the verified atlas and its finite set of ROM-backed drawing resources.
    width*, height*, regionWidth*, regionHeight*, regionCount*: int
    layout*: WorldMapLayout
    assets*: WorldMapAssets
    drawingRevision: int
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
  PlanarTileBytes = 32
  PlanePairBytes = 16
  RegionPaletteCount = 8
  TileWordBits = sizeof(uint16) * 8
  ViewportRowCacheSlots = 4096
    ## Use a power-of-two table capped at 160 KiB of composed rows per render.
  AtlasMargin = rgbx(10, 17, 31, 255)

proc refreshDrawings(atlas: WorldMapAtlas) =
  ## Resolve scenery resources and palettes for the current numbered story flags.
  for region in atlas.layout.regions:
    let
      resource = atlas.assets.resource(region.drawingTilesetId)
      palette = atlas.assets.palette(region.mapTilesetId, region.paletteId)
    atlas.drawings[region.index].resource = resource
    atlas.drawings[region.index].paletteKey =
      region.mapTilesetId * RegionPaletteCount + region.paletteId
    for index, color in palette.colors:
      atlas.drawings[region.index].colors[index] = bgr555ToColor(color).rgbx
  atlas.drawingRevision = atlas.assets.revision

proc stateRevision*(atlas: WorldMapAtlas): int =
  ## Report the authoritative asset-state revision even through the public asset interface.
  if atlas.assets == nil: 0 else: atlas.assets.revision

proc ensureDrawings(atlas: WorldMapAtlas) =
  ## Refresh snapshots if a caller changed flags through either supported public interface.
  if atlas.drawingRevision != atlas.stateRevision:
    atlas.refreshDrawings()

proc newWorldMapAtlas*(rom: seq[uint8],
    state = default(WorldMapStoryState)): WorldMapAtlas =
  ## Validate all placements and prepare original scenery for the selected story flags.
  let
    layout = newWorldMapLayout(rom)
    assets = newWorldMapAssets(rom, state)
  result = WorldMapAtlas(width: WorldWidth, height: WorldHeight,
    regionWidth: RegionWidth, regionHeight: RegionHeight, regionCount: RegionCount,
    layout: layout, assets: assets, drawings: newSeq[RegionDrawing](RegionCount))
  result.refreshDrawings()
  for row in 0 ..< MapRows:
    for column in 0 ..< MapColumns:
      let
        region = layout.regionAt(column * MapCellPixels, row * MapCellPixels)
        arrangement = layout.arrangements[row * MapColumns + column].int
        resource = result.drawings[region.index].resource
      if arrangement >= resource.arrangements.len:
        raise newException(ValueError,
          &"Map cell {column},{row} arrangement {arrangement} exceeds tileset {resource.id}.")

proc loadWorldMapAtlas*(path: string,
    state = default(WorldMapStoryState)): WorldMapAtlas =
  ## Load the user's US ROM and decode the complete base atlas without emulating play.
  newWorldMapAtlas(readGoldBaserom(path), state)

proc flagCatalog*(atlas: WorldMapAtlas): seq[WorldMapFlag] =
  ## List the ROM's supported static scenery flags and their verified descriptions.
  atlas.assets.flagCatalog()

proc flagEnabled*(atlas: WorldMapAtlas, id: int): bool =
  ## Read the selected value of one numbered scenery flag.
  atlas.assets.flagEnabled(id)

proc enabledFlags*(atlas: WorldMapAtlas): seq[int] =
  ## List active flags in stable numeric order for controls and reproduction.
  atlas.assets.enabledFlags()

proc setStoryFlag*(atlas: WorldMapAtlas, id: int, enabled: bool) =
  ## Refresh resolved scenery only after an actual supported story-flag change.
  atlas.assets.setStoryFlag(id, enabled)
  atlas.ensureDrawings()

proc resetStoryFlags*(atlas: WorldMapAtlas) =
  ## Restore the cleared-event baseline without modifying the user's game data.
  atlas.assets.resetStoryFlags()
  atlas.ensureDrawings()

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
  atlas.ensureDrawings()
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
  atlas.ensureDrawings()
  let
    cell = atlas.arrangementWord(x, y)
    drawing = addr atlas.drawings[cell.region]
    color = tileColorIndex(drawing.resource, cell.word, x mod TilePixels, y mod TilePixels)
  drawing.colors[color]

proc tileRow(resource: WorldMapResource, tile, y: int,
    indices: var array[TilePixels, uint8]) =
  ## Decode a complete four-plane row with one read of each original plane byte.
  if tile notin 0 ..< WorldChrTileCount:
    raise newException(ValueError, "Map CHR tile is outside the original upload.")
  let
    offset = tile * PlanarTileBytes + y * 2
    plane0 = resource.graphics[offset]
    plane1 = resource.graphics[offset + 1]
    plane2 = resource.graphics[offset + PlanePairBytes]
    plane3 = resource.graphics[offset + PlanePairBytes + 1]
  for x in 0 ..< TilePixels:
    let shift = TilePixels - 1 - x
    indices[x] = ((plane0 shr shift) and 1) or
      (((plane1 shr shift) and 1) shl 1) or
      (((plane2 shr shift) and 1) shl 2) or
      (((plane3 shr shift) and 1) shl 3)

proc compositeTileRow(drawing: ptr RegionDrawing, word: uint16, y: int,
    colors: var array[TilePixels, ColorRGBX]) =
  ## Compose both scenery planes once for an eight-pixel arrangement row.
  let
    tile = word.int and TileIndexMask
    sy = if (word and FlipVertical) != 0: TilePixels - 1 - y else: y
    palette = ((word.int shr PaletteShift) and PaletteMask) * ColorsPerPalette
    high = (word and PriorityHigh) != 0
    flip = (word and FlipHorizontal) != 0
    hasOverlay = tile < WorldBg2TileCount
  var main, overlay: array[TilePixels, uint8]
  drawing.resource.tileRow(tile, sy, main)
  if hasOverlay: drawing.resource.tileRow(tile + WorldBg2ChrTileOffset, sy, overlay)
  for x in 0 ..< TilePixels:
    let
      sx = if flip: TilePixels - 1 - x else: x
      foreground = main[sx].int
      background = overlay[sx].int
      index = if foreground != 0 and high: palette + foreground
        elif hasOverlay and background != 0: palette + background
        elif foreground != 0: palette + foreground else: 0
    colors[x] = drawing.colors[index]

type
  ViewportTileRow = object
    ## Cache one logical palette, tile word, and row only within a single render.
    key: uint64
    colors: array[TilePixels, ColorRGBX]

proc renderViewport*(atlas: WorldMapAtlas, centerX, centerY, zoom: float64,
    width, height: int): Image =
  ## Sample visible tile rows at nearest-neighbor positions with a bounded per-call cache.
  if width <= 0 or height <= 0 or zoom <= 0 or zoom.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "Map viewport dimensions and zoom must be finite and positive.")
  if centerX.classify in {fcNan, fcInf, fcNegInf} or
      centerY.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "Map camera coordinates must be finite.")
  result = newImage(width, height)
  let
    left = centerX - width.float64 / (2 * zoom)
    top = centerY - height.float64 / (2 * zoom)
  var
    worldColumns = newSeq[int](width)
    firstColumn = width
    lastColumn = 0
  for x in 0 ..< width:
    let nativeX = left + x.float64 / zoom
    if nativeX >= 0 and nativeX < atlas.width.float64:
      worldColumns[x] = floor(nativeX).int
      firstColumn = min(firstColumn, x)
      lastColumn = x + 1
  if firstColumn >= lastColumn:
    result.fill(AtlasMargin)
    return
  let bottom = top + (height - 1).float64 / zoom
  if firstColumn != 0 or lastColumn != width or
      not (top >= 0 and bottom < atlas.height.float64):
    result.fill(AtlasMargin)
  atlas.ensureDrawings()
  var
    previousWorldY = -1
    # A fresh cache observes story changes and direct public graphics mutations.
    rows = newSeq[ViewportTileRow](ViewportRowCacheSlots)
  for y in 0 ..< height:
    let nativeY = top + y.float64 / zoom
    if not (nativeY >= 0 and nativeY < atlas.height.float64): continue
    let worldY = floor(nativeY).int
    if worldY == previousWorldY:
      copyMem(addr result.data[y * width], addr result.data[(y - 1) * width],
        width * sizeof(ColorRGBX))
      continue
    previousWorldY = worldY
    var x = firstColumn
    while x < lastColumn:
      let
        worldX = worldColumns[x]
        cell = atlas.arrangementWord(worldX, worldY)
        drawing = addr atlas.drawings[cell.region]
        tileStart = (worldX div TilePixels) * TilePixels
        tileEnd = tileStart + TilePixels
        key = (((drawing.paletteKey.uint64 shl TileWordBits) or cell.word.uint64) *
          TilePixels.uint64) + (worldY mod TilePixels).uint64 + 1
        cached = addr rows[hash(key) and (ViewportRowCacheSlots - 1)]
      if cached.key != key:
        drawing.compositeTileRow(cell.word, worldY mod TilePixels, cached.colors)
        cached.key = key
      if zoom == 1:
        let run = min(tileEnd - worldX, lastColumn - x)
        copyMem(addr result.data[y * width + x], addr cached.colors[worldX - tileStart],
          run * sizeof(ColorRGBX))
        x += run
      else:
        while x < lastColumn and worldColumns[x] < tileEnd:
          result.data[y * width + x] = cached.colors[worldColumns[x] - tileStart]
          inc x
