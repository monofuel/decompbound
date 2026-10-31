## Optional expanded outdoor scenery around the original 256x224 frame.
## Stage 2 of docs/expanded-viewport.md: Winters outdoor base terrain only.
## Capture is read-only and must run at the end of the visible frame, before NMI.

import
  std/[options, strformat],
  pixie,
  ./[cpu, ppu, snesbus, viewport_geometry, world_map, world_map_assets, world_map_layout]

type
  ExpandedViewport* = ref object
    ## Own decoded atlas resources plus a per-frame live Winters scenery snapshot.
    width*, height*: int
    atlas: WorldMapAtlas
    wintersLogicals: seq[int]
    originX, originY: int
    captured: bool
    extended: bool
    reason: string
    cameraX, cameraY, logicalTileset: int
    liveResource: WorldMapResource
    liveColors: array[256, ColorRGBX]
    output: Image

const
  PublishedCameraX = 0x0041
  PublishedCameraY = 0x0045
    ## C08B26 publishes two scroll lanes; C08278 applies one to the PPU.
  ScrollMask = 0x03FF
    ## The PPU latches ten bits; published words retain the full world coordinate.
  ActiveLogicalTileset = 0x436E
    ## C00B82/C00C92 compare the sector family from D7A800 against this word.
  EventBitsWram = 0x9C08
    ## C21628 numbered event bits, one-based IDs.
  ArrangementWram = 0x7F8000'u32
    ## C41A9E arrangement destination; C0035B indexes 32-byte records here.
  WramBase = 0x7E0000'u32
  WintersLightingFlag = 0x011F
    ## Palette-0 condition for the Winters outdoor logical family.
  MapModeOne = 1
  MapChrNba = 0x20'u8
    ## BG1 CHR at VRAM $0000, BG2 at byte $4000, matching C00ED6.
  FullBrightness = 15
  ForceBlankBit = 0x80'u8
  BrightnessMask = 0x0F'u8
  BgModeMask = 0x07'u8
  Bg1Bg2Mask = 0x03'u8
  InidispReg = 0x00
  BgModeReg = 0x05
  MosaicReg = 0x06
  Bg1MapReg = 0x07
  Bg2MapReg = 0x08
  WintersBg1Map = 0x39'u8
  WintersBg2Map = 0x59'u8
    ## Verified Winters 64×32 tilemaps use VRAM word bases $3800/$5800.
  Bg12NbaReg = 0x0B
  W12SelReg = 0x23
  W34SelReg = 0x24
  WobjSelReg = 0x25
  TmReg = 0x2C
  TsReg = 0x2D
  CgwselReg = 0x30
  CgadsubReg = 0x31
  TilePixels = 8
  ArrangementColumns = MapCellPixels div TilePixels
  OpaqueBlack = rgbx(0, 0, 0, 255)
  PresentationNone = "padded no-capture"
  PresentationExtended = "extended winters-outdoor"

proc wram8(snes: SnesBus, offset: int): uint8 =
  ## Read one WRAM byte at $7E0000+offset.
  snes.bus.read8(WramBase + offset.uint32)

proc wram16(snes: SnesBus, offset: int): int =
  ## Read one little-endian WRAM word at $7E0000+offset.
  snes.bus.read16(WramBase + offset.uint32).int

proc eventFlagEnabled(snes: SnesBus, id: int): bool =
  ## Read a one-based numbered event bit from WRAM $9C08.
  let index = id - FirstWorldMapStoryFlag
  (snes.wram8(EventBitsWram + index div 8) and
    uint8(1 shl (index mod 8))) != 0

proc publishedCamera(snes: SnesBus): Option[tuple[x, y: int]] =
  ## Select the full published camera matching the displayed PPU scroll, rejecting ambiguity.
  for lane in 0 .. 1:
    let camera = (x: snes.wram16(PublishedCameraX + lane * 2),
      y: snes.wram16(PublishedCameraY + lane * 2))
    if (camera.x and ScrollMask) == snes.bgScroll[0].int and
        (camera.y and ScrollMask) == snes.bgScroll[1].int:
      if result.isSome and result.get != camera:
        return none(tuple[x, y: int])
      result = some(camera)

proc worldOrigin*(view: ExpandedViewport): tuple[x, y: int] =
  ## Expose the captured original-screen world origin for scene-comparison tools.
  (view.cameraX, view.cameraY)

proc deriveWintersLogicals(atlas: WorldMapAtlas): seq[int] =
  ## Collect logical tilesets whose palette 0 is gated by Winters lighting $011F.
  for logical in 0 ..< WorldLogicalTilesetCount:
    let pal = atlas.assets.palette(logical, 0)
    if (pal.storyFlag and 0x7FFF) == WintersLightingFlag:
      result.add(logical)
  if result.len == 0:
    raise newException(ValueError,
      "ROM palette table has no logical tileset gated by Winters lighting $011F.")

proc newExpandedViewport*(rom: seq[uint8], width, height: int): ExpandedViewport =
  ## Decode reusable atlas resources and bind an output size of at least 256x224.
  discard viewportGeometry(width, height)
  let atlas = newWorldMapAtlas(rom)
  result = ExpandedViewport(width: width, height: height, atlas: atlas,
    wintersLogicals: atlas.deriveWintersLogicals(),
    originX: (width - ScreenWidth) div 2, originY: (height - ScreenHeight) div 2,
    reason: "no-capture", output: newImage(width, height))
  result.output.fill(OpaqueBlack)

proc presentation*(view: ExpandedViewport): string =
  ## Describe the current extended or padded policy for stable log transitions.
  if not view.captured: PresentationNone
  elif view.extended: PresentationExtended
  else: "padded " & view.reason

proc syncStoryFlags(view: ExpandedViewport, snes: SnesBus) =
  ## Copy catalogued map flags from live WRAM $9C08 without touching the machine.
  for flag in view.atlas.flagCatalog():
    view.atlas.setStoryFlag(flag.id, snes.eventFlagEnabled(flag.id))

proc padReason(view: ExpandedViewport, snes: SnesBus, cameraX, cameraY,
    logical: int): string =
  ## Return the first conservative reject reason, or empty when Winters outdoor may extend.
  let
    inidisp = snes.ppuRegs[InidispReg]
    mode = snes.ppuRegs[BgModeReg]
  if (inidisp and ForceBlankBit) != 0: return "force-blank"
  if (mode and BgModeMask).int != MapModeOne: return &"bg-mode={mode and BgModeMask}"
  if (inidisp and BrightnessMask).int != FullBrightness:
    return &"brightness={inidisp and BrightnessMask}"
  if snes.ppuRegs[MosaicReg] != 0: return "mosaic"
  if snes.ppuRegs[W12SelReg] != 0 or snes.ppuRegs[W34SelReg] != 0 or
      snes.ppuRegs[WobjSelReg] != 0: return "windows"
  if snes.ppuRegs[CgwselReg] != 0 or snes.ppuRegs[CgadsubReg] != 0: return "color-math"
  if snes.hdmaen != 0: return "hdma"
  if snes.ppuRegs[TsReg] != 0: return "subscreen"
  if snes.ppuRegs[Bg12NbaReg] != MapChrNba: return "chr-base"
  if snes.ppuRegs[Bg1MapReg] != WintersBg1Map or snes.ppuRegs[Bg2MapReg] != WintersBg2Map:
    return "tilemap-base"
  if snes.bgScroll[0] != snes.bgScroll[2] or snes.bgScroll[1] != snes.bgScroll[3]:
    return "independent-bg-scroll"
  if (snes.ppuRegs[TmReg] and Bg1Bg2Mask) != Bg1Bg2Mask: return "missing-bg"
  if cameraX notin 0 ..< WorldWidth or cameraY notin 0 ..< WorldHeight:
    return "camera-oob"
  if logical notin view.wintersLogicals: return &"tileset={logical}"
  let region = view.atlas.layout.regionAt(cameraX, cameraY)
  if region.mapTilesetId != logical: return "tileset-mismatch"

proc ensureLiveResource(view: ExpandedViewport, drawing: int) =
  ## Rebuild the live overlay resource when the drawing family changes.
  let sourceResource = view.atlas.assets.resource(drawing)
  if view.liveResource != nil and view.liveResource.id == drawing and
      view.liveResource.arrangements.len == sourceResource.arrangements.len:
    return
  view.liveResource = WorldMapResource(id: drawing,
    graphicsFile: sourceResource.graphicsFile, arrangementsFile: sourceResource.arrangementsFile,
    decodedGraphicsLength: sourceResource.decodedGraphicsLength,
    graphics: newSeq[uint8](WorldChrBytes),
    arrangements: newSeq[array[WorldArrangementCells, uint16]](sourceResource.arrangements.len))

proc copyLiveResources(view: ExpandedViewport, snes: SnesBus, drawing: int) =
  ## Snapshot frame-consistent CHR, arrangements, and CGRAM without mutating atlas caches.
  view.ensureLiveResource(drawing)
  for byte in 0 ..< WorldChrBytes:
    let word = snes.vram[byte div 2]
    view.liveResource.graphics[byte] =
      if byte mod 2 == 0: uint8(word and 0xFF) else: uint8(word shr 8)
  for arrangement in 0 ..< view.liveResource.arrangements.len:
    for tile in 0 ..< WorldArrangementCells:
      view.liveResource.arrangements[arrangement][tile] = snes.bus.read16(
        ArrangementWram + (arrangement * WorldArrangementCells * 2 + tile * 2).uint32)
  for index, color in snes.cgram:
    view.liveColors[index] = bgr555ToColor(color).rgbx

proc capture*(view: ExpandedViewport, snes: SnesBus) =
  ## Snapshot pre-NMI camera, flags, and live map resources; never write the machine.
  view.captured = true
  view.extended = false
  view.syncStoryFlags(snes)
  let camera = snes.publishedCamera()
  if camera.isNone:
    view.reason = "unmatched-published-scroll"
    return
  let
    cameraX = camera.get.x
    cameraY = camera.get.y
    logical = snes.wram16(ActiveLogicalTileset)
  view.cameraX = cameraX
  view.cameraY = cameraY
  view.logicalTileset = logical
  view.reason = view.padReason(snes, cameraX, cameraY, logical)
  if view.reason.len > 0: return
  view.copyLiveResources(snes, view.atlas.assets.drawingTileset(logical))
  view.extended = true
  view.reason = "winters-outdoor"

proc sceneryPixel*(view: ExpandedViewport, worldX, worldY: int): ColorRGBX =
  ## Compose one extra scenery pixel from live CHR/arrangements/CGRAM and C00B82 clipping.
  if not view.extended or worldX notin 0 ..< WorldWidth or worldY notin 0 ..< WorldHeight:
    return OpaqueBlack
  let region = view.atlas.layout.regionAt(worldX, worldY)
  if region.mapTilesetId != view.logicalTileset:
    return OpaqueBlack
  let
    arrangement = view.atlas.layout.arrangements[
      (worldY div MapCellPixels) * MapColumns + worldX div MapCellPixels].int
  if arrangement < 0 or arrangement >= view.liveResource.arrangements.len:
    return OpaqueBlack
  let
    tile = ((worldY mod MapCellPixels) div TilePixels) * ArrangementColumns +
      (worldX mod MapCellPixels) div TilePixels
    word = view.liveResource.arrangements[arrangement][tile]
    index = tileColorIndex(view.liveResource, word,
      worldX mod TilePixels, worldY mod TilePixels)
  view.liveColors[index]

proc blitOriginal(dest, original: Image, originX, originY: int) =
  ## Copy the original 256x224 presentation, including actors and UI, onto the center.
  for y in 0 ..< ScreenHeight:
    copyMem(addr dest.data[(originY + y) * dest.width + originX],
      addr original.data[y * ScreenWidth], ScreenWidth * sizeof(ColorRGBX))

proc compose*(view: ExpandedViewport, original: Image): Image =
  ## Return a reusable W×H opaque image with original 256x224 centered on extra scenery or black.
  if original.width != ScreenWidth or original.height != ScreenHeight:
    raise newException(ValueError,
      &"Expanded compose needs a {ScreenWidth}x{ScreenHeight} original frame.")
  if view.output.width != view.width or view.output.height != view.height:
    view.output = newImage(view.width, view.height)
  view.output.fill(OpaqueBlack)
  if view.extended:
    let
      originX = view.originX
      originY = view.originY
      right = originX + ScreenWidth
      bottom = originY + ScreenHeight
    for y in 0 ..< view.height:
      let worldY = view.cameraY + y - originY
      for x in 0 ..< view.width:
        if x >= originX and x < right and y >= originY and y < bottom: continue
        view.output.data[y * view.width + x] = view.sceneryPixel(
          view.cameraX + x - originX, worldY)
  view.output.blitOriginal(original, view.originX, view.originY)
  view.output
