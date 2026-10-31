## Optional expanded live map and battle scenery around the original 256x224 frame.
## Capture is read-only and must run at the end of the visible frame, before NMI.

import
  std/[options, strformat],
  pixie,
  ./[battle_viewport, cpu, ppu, snesbus, viewport_geometry, world_map, world_map_assets, world_map_layout]

type
  ExpandedViewport* = ref object
    ## Own decoded atlas resources and live map/battle presentation snapshots.
    width*, height*: int
    atlas: WorldMapAtlas
    battle: BattleViewport
    originX, originY: int
    captured: bool
    extended: bool
    reason: string
    cameraX, cameraY, logicalTileset: int
    liveResource: WorldMapResource
    liveColors: array[256, ColorRGBA]
    registers: array[0x100, uint8]
    fixedColor: ColorRGBA
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
  MapModeOne = 1
  MapChrNba = 0x20'u8
    ## BG1 CHR at VRAM $0000, BG2 at byte $4000, matching C00ED6.
  ForceBlankBit = 0x80'u8
  BgModeMask = 0x07'u8
  Bg1Bg2Mask = 0x03'u8
  InidispReg = 0x00
  BgModeReg = 0x05
  MosaicReg = 0x06
  Bg1MapReg = 0x07
  Bg2MapReg = 0x08
  MapBg1 = 0x39'u8
  MapBg2 = 0x59'u8
    ## C00F35/C00F8E publish the map at VRAM word bases $3800/$5800 with 64×32 maps.
  Bg12NbaReg = 0x0B
  W12SelReg = 0x23
  WobjSelReg = 0x25
  Window1LeftReg = 0x26
  Window2LeftReg = 0x28
  WbglogReg = 0x2A
  WobjlogReg = 0x2B
  TmReg = 0x2C
  TsReg = 0x2D
  TmwReg = 0x2E
  TswReg = 0x2F
  CgwselReg = 0x30
  CgadsubReg = 0x31
  TilePixels = 8
  ArrangementColumns = MapCellPixels div TilePixels
  MapBg1WordBase = 0x3800
  MapBg2WordBase = 0x5800
  TileIndexMask = 0x03FF'u16
  PriorityHigh = 0x2000'u16
  TilemapScreenWords = 0x400
  OpaqueBlack = rgbx(0, 0, 0, 255)
  PresentationNone = "padded no-capture"
  PresentationExtended = "extended map"

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

proc newExpandedViewport*(rom: seq[uint8], width, height: int): ExpandedViewport =
  ## Decode reusable atlas resources and bind an output size of at least 256x224.
  discard viewportGeometry(width, height)
  let atlas = newWorldMapAtlas(rom)
  result = ExpandedViewport(width: width, height: height, atlas: atlas,
    battle: newBattleViewport(width, height, rom),
    originX: (width - ScreenWidth) div 2, originY: (height - ScreenHeight) div 2,
    reason: "no-capture", output: newImage(width, height))
  result.output.fill(OpaqueBlack)

proc presentation*(view: ExpandedViewport): string =
  ## Describe the current extended or padded policy for stable log transitions.
  if not view.captured: PresentationNone
  elif view.battle.ready: "extended battle"
  elif view.extended: PresentationExtended
  else: "padded " & view.reason

proc syncStoryFlags(view: ExpandedViewport, snes: SnesBus) =
  ## Copy catalogued map flags from live WRAM $9C08 without touching the machine.
  for flag in view.atlas.flagCatalog():
    view.atlas.setStoryFlag(flag.id, snes.eventFlagEnabled(flag.id))

proc padReason(view: ExpandedViewport, snes: SnesBus, cameraX, cameraY,
    logical: int): string =
  ## Reject unsupported rendering configurations independently of town or indoor status.
  let
    inidisp = snes.ppuRegs[InidispReg]
    mode = snes.ppuRegs[BgModeReg]
  if (inidisp and ForceBlankBit) != 0: return "force-blank"
  if (mode and BgModeMask).int != MapModeOne: return &"bg-mode={mode and BgModeMask}"
  if (mode and 0x30) != 0: return "large-map-tiles"
  if snes.ppuRegs[MosaicReg] != 0: return "mosaic"
  if snes.hdmaen != 0: return "hdma"
  if (snes.ppuRegs[TsReg] and not Bg1Bg2Mask) != 0: return "subscreen-non-map"
  if snes.ppuRegs[Bg12NbaReg] != MapChrNba: return "chr-base"
  if snes.ppuRegs[Bg1MapReg] != MapBg1 or snes.ppuRegs[Bg2MapReg] != MapBg2:
    return "tilemap-base"
  if snes.bgScroll[0] != snes.bgScroll[2] or snes.bgScroll[1] != snes.bgScroll[3]:
    return "independent-bg-scroll"
  if ((snes.ppuRegs[TmReg] or snes.ppuRegs[TsReg]) and Bg1Bg2Mask) == 0:
    return "missing-bg"
  if cameraX notin 0 ..< WorldWidth or cameraY notin 0 ..< WorldHeight:
    return "camera-oob"
  if logical notin 0 ..< WorldLogicalTilesetCount: return &"tileset={logical}"

proc sceneryWord(view: ExpandedViewport, worldX, worldY: int): uint16 =
  ## Reproduce C00B9D/C00CAD's arrangement-zero fill beyond the active logical family.
  var arrangement = 0
  if worldX in 0 ..< WorldWidth and worldY in 0 ..< WorldHeight and
      view.atlas.layout.regionAt(worldX, worldY).mapTilesetId == view.logicalTileset:
    arrangement = view.atlas.layout.arrangements[
      (worldY div MapCellPixels) * MapColumns + worldX div MapCellPixels].int
  if arrangement >= view.liveResource.arrangements.len:
    raise newException(ValueError, "Live map arrangement is outside its loaded resource.")
  let tile = ((worldY and (MapCellPixels - 1)) div TilePixels) * ArrangementColumns +
    ((worldX and (MapCellPixels - 1)) div TilePixels)
  view.liveResource.arrangements[arrangement][tile]

proc publishedMapMatches(view: ExpandedViewport, snes: SnesBus): bool =
  ## Require current map publication to agree before extending streamed or edited scenes.
  let
    left = view.cameraX and not (TilePixels - 1)
    top = view.cameraY and not (TilePixels - 1)
  for y in countup(top, view.cameraY + ScreenHeight - 1, TilePixels):
    for x in countup(left, view.cameraX + ScreenWidth - 1, TilePixels):
      let
        word = view.sceneryWord(x, y)
        offset = ((x div 256) and 1) * TilemapScreenWords +
          ((y div TilePixels) and 31) * 32 + ((x div TilePixels) and 31)
        second = if (word and TileIndexMask).int < WorldBg2TileCount:
            word or PriorityHigh else: 0'u16
      if snes.vram[MapBg1WordBase + offset] != word or
          snes.vram[MapBg2WordBase + offset] != second:
        return false
  true

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
    view.liveColors[index] = bgr555ToColor(color)
  view.registers = snes.ppuRegs
  view.fixedColor = bgr555ToColor(snes.fixedColorR.uint16 or
    (snes.fixedColorG.uint16 shl 5) or (snes.fixedColorB.uint16 shl 10))

proc capture*(view: ExpandedViewport, snes: SnesBus) =
  ## Snapshot pre-NMI camera, flags, and live map resources; never write the machine.
  view.captured = true
  view.extended = false
  view.battle.finishCapture(snes)
  if view.battle.ready: return
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
  if not view.publishedMapMatches(snes):
    view.reason = "map-publication"
    return
  view.extended = true
  view.reason = "map"

proc captureScanline*(view: ExpandedViewport, snes: SnesBus, line: int) =
  ## Record battle background HDMA at the row actually displayed by the PPU.
  view.battle.captureScanline(snes, line)

proc windowAt(view: ExpandedViewport, selector: uint8, shift, combine, x: int): bool =
  ## Evaluate static SNES windows in original-screen coordinates without wrapping new margins.
  let
    oneEnabled = (selector and (2'u8 shl shift)) != 0
    twoEnabled = (selector and (8'u8 shl shift)) != 0
    one = (x >= view.registers[Window1LeftReg].int and
      x <= view.registers[Window1LeftReg + 1].int) xor
      ((selector and (1'u8 shl shift)) != 0)
    two = (x >= view.registers[Window2LeftReg].int and
      x <= view.registers[Window2LeftReg + 1].int) xor
      ((selector and (4'u8 shl shift)) != 0)
  if oneEnabled and twoEnabled:
    case combine
    of 1: one and two
    of 2: one xor two
    of 3: one == two
    else: one or two
  elif oneEnabled: one
  elif twoEnabled: two
  else: false

proc mapSample(view: ExpandedViewport, word: uint16, sx, sy, screenX: int,
    mask, windowMask: uint8, backdrop: ColorRGBA):
    tuple[color: ColorRGBA, source: uint8, drawn: bool] =
  ## Compose the map's two planes with independent layer enables, priority and window masks.
  let
    tile = (word and TileIndexMask).int
    x = if (word and 0x4000) != 0: TilePixels - 1 - sx else: sx
    y = if (word and 0x8000) != 0: TilePixels - 1 - sy else: sy
    palette = ((word.int shr 10) and 7) * 16
    first = view.liveResource.pixelIndex(tile, x, y).int
    secondWord = if tile < WorldBg2TileCount: word or PriorityHigh else: 0'u16
    secondX = if (secondWord and 0x4000) != 0: TilePixels - 1 - sx else: sx
    secondY = if (secondWord and 0x8000) != 0: TilePixels - 1 - sy else: sy
    second = view.liveResource.pixelIndex((secondWord and TileIndexMask).int +
      WorldBg2ChrTileOffset, secondX, secondY).int
    secondPalette = ((secondWord.int shr 10) and 7) * 16
    firstVisible = first != 0 and (mask and 1) != 0 and not
      ((windowMask and 1) != 0 and view.windowAt(view.registers[W12SelReg],
        0, view.registers[WbglogReg].int and 3, screenX))
    secondVisible = second != 0 and (mask and 2) != 0 and not
      ((windowMask and 2) != 0 and view.windowAt(view.registers[W12SelReg],
        4, (view.registers[WbglogReg].int shr 2) and 3, screenX))
  result = (backdrop, 0x20'u8, false)
  if firstVisible and ((word and PriorityHigh) != 0 or
      (secondWord and PriorityHigh) == 0 or not secondVisible):
    result = (view.liveColors[palette + first], 1'u8, true)
  elif secondVisible:
    result = (view.liveColors[secondPalette + second], 2'u8, true)

proc sceneryPixel*(view: ExpandedViewport, worldX, worldY: int): ColorRGBX =
  ## Compose live map planes, static windows, fixed/subscreen color math and master brightness.
  if not view.extended: return OpaqueBlack
  let
    word = view.sceneryWord(worldX, worldY)
    sx = worldX and (TilePixels - 1)
    sy = worldY and (TilePixels - 1)
    screenX = worldX - view.cameraX
    main = view.mapSample(word, sx, sy, screenX, view.registers[TmReg],
      view.registers[TmwReg], view.liveColors[0])
    cgadsub = view.registers[CgadsubReg]
    cgwsel = view.registers[CgwselReg]
    useSubscreen = (cgwsel and 2) != 0
    colorWindow = view.windowAt(view.registers[WobjSelReg], 4,
      (view.registers[WobjlogReg].int shr 2) and 3, screenX)
    black = case (cgwsel.int shr 6) and 3
      of 1: not colorWindow
      of 2: colorWindow
      of 3: true
      else: false
    mathEnabled = case (cgwsel.int shr 4) and 3
      of 1: colorWindow
      of 2: not colorWindow
      of 3: false
      else: true
  if view.registers[TmReg] == 0 and useSubscreen and (cgadsub and 0x3F) != 0 and
      view.registers[TsReg] != 0:
    let sub = view.mapSample(word, sx, sy, screenX, view.registers[TsReg],
      view.registers[TswReg], view.fixedColor)
    return applyMasterBrightness(sub.color, view.registers[InidispReg]).rgbx
  var color = if black: rgba(0, 0, 0, 255) else: main.color
  if (cgadsub and main.source) != 0 and mathEnabled:
    let sub = if useSubscreen:
        view.mapSample(word, sx, sy, screenX, view.registers[TsReg],
          view.registers[TswReg], view.fixedColor)
      else: (color: view.fixedColor, source: 0'u8, drawn: true)
    color = colorMathBlend(color, sub.color, (cgadsub and 0x80) != 0,
      (cgadsub and 0x40) != 0 and sub.drawn)
  applyMasterBrightness(color, view.registers[InidispReg]).rgbx

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
  if view.battle.ready:
    copyMem(addr view.output.data[0], addr view.battle.output.data[0],
      view.output.data.len * sizeof(ColorRGBX))
  elif view.extended:
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
