import
  std/[math, strformat],
  pixie,
  ./[companion_style, world_map_browser]

type
  MapInspector* = object
    valid*: bool
    worldX*, worldY*, regionIndex*, regionX*, regionY*: int
    tileId*, tilesetId*, paletteId*, arrangementId*: int
    flags*: uint16
  WorldMapView* = ref object
    image*: Image
    context: Context
    font: Font

const
  AtlasWidth* = 1200
  AtlasHeight* = 800
  MapViewport* = rect(314, 108, 862, 652)
  MapButtons = [
    (PreviousRegion, rect(38, 148, 116, 34)),
    (NextRegion, rect(162, 148, 116, 34)),
    (ZoomOut, rect(38, 220, 44, 38)),
    (ZoomIn, rect(234, 220, 44, 38)),
    (FitWorld, rect(38, 276, 116, 34)),
    (CenterSelection, rect(162, 276, 116, 34)),
    (ToggleGrid, rect(38, 326, 240, 34)),
    (InspectCenter, rect(38, 664, 240, 34)),
    (ToggleFullscreen, rect(38, 710, 240, 34))]
  GridMinimumSpacing = 8.0
  SelectionRadius = 7

proc contains*(area: Rect, point: Vec2): bool =
  ## Test half-open logical UI bounds for pointer routing.
  point.x >= area.x and point.y >= area.y and
    point.x < area.x + area.w and point.y < area.y + area.h

proc atlasPoint*(point: Vec2, width, height: int): Vec2 =
  ## Undo the shared blitter's fitted viewport after window resizing.
  if width <= 0 or height <= 0: return vec2(-1, -1)
  let
    ratio = min(width.float32 / AtlasWidth.float32, height.float32 / AtlasHeight.float32)
    scale = if ratio >= 1: floor(ratio) else: ratio
    fittedW = max(1, int(AtlasWidth.float32 * scale))
    fittedH = max(1, int(AtlasHeight.float32 * scale))
    origin = vec2(((width - fittedW) div 2).float32, ((height - fittedH) div 2).float32)
  (point - origin) / vec2(fittedW.float32 / AtlasWidth.float32,
    fittedH.float32 / AtlasHeight.float32)

proc canvasPoint*(point: Vec2): Vec2 =
  ## Convert a logical UI point to coordinates relative to the map canvas.
  point - vec2(MapViewport.x, MapViewport.y)

proc mouseActions*(point: Vec2): set[MapAction] =
  ## Resolve sidebar controls independently from atlas selection and dragging.
  for (action, area) in MapButtons:
    if area.contains(point): result.incl(action)

proc newWorldMapView*(): WorldMapView =
  ## Allocate the companion-themed canvas and embedded font once.
  let image = newImage(AtlasWidth, AtlasHeight)
  WorldMapView(image: image, context: newContext(image), font: newFont(parseTtf(FontData)))

proc box(view: WorldMapView, area: Rect, color: string, radius = 12'f32) =
  ## Paint a panel using the established companion-app colors.
  view.context.fillStyle = parseHtmlColor(color)
  view.context.fillRoundedRect(area, radius)

proc label(view: WorldMapView, text: string, x, y, size: float32,
    color = Ink, width = 0'f32, centered = false) =
  ## Draw embedded-font text without depending on system fonts.
  view.font.size = size
  view.font.paint.color = parseHtmlColor(color)
  view.image.fillText(view.font, text, translate(vec2(x, y)), bounds = vec2(width, 0),
    hAlign = if centered: CenterAlign else: LeftAlign)

proc zoomLabel*(zoom: float64): string =
  ## Describe native pixel scale without rounding fractional overviews to zero.
  if zoom >= 1: $zoom.int & "x" else: "1/" & $(round(1 / zoom).int) & "x"

proc mapPixel(view: WorldMapView, x, y: int, color: ColorRGBX) =
  ## Clip map annotations to the interactive canvas.
  if x >= 0 and y >= 0 and x < MapViewport.w.int and y < MapViewport.h.int:
    view.image[MapViewport.x.int + x, MapViewport.y.int + y] = color

proc drawGrid(view: WorldMapView, browser: WorldMapBrowser) =
  ## Draw region boundaries only at legible screen spacing.
  if not browser.grid: return
  let
    spacingX = browser.regionWidth.float64 * browser.zoom
    spacingY = browser.regionHeight.float64 * browser.zoom
    first = browser.worldPoint(0, 0)
    last = browser.worldPoint(MapViewport.w.float64, MapViewport.h.float64)
    atlasFirst = browser.viewportPoint(0, 0)
    atlasLast = browser.viewportPoint(browser.width.float64, browser.height.float64)
    startX = max(0, floor(atlasFirst.x).int)
    startY = max(0, floor(atlasFirst.y).int)
    endX = min(MapViewport.w.int, ceil(atlasLast.x).int + 1)
    endY = min(MapViewport.h.int, ceil(atlasLast.y).int + 1)
    color = parseHtmlColor(Mint).rgbx
  if min(spacingX, spacingY) < GridMinimumSpacing: return
  for regionX in max(0, ceil(first.x / browser.regionWidth.float64).int) ..
      min(browser.width div browser.regionWidth, floor(last.x / browser.regionWidth.float64).int):
    let point = browser.viewportPoint((regionX * browser.regionWidth).float64, 0)
    for y in startY ..< endY:
      if y mod 4 < 2: view.mapPixel(round(point.x).int, y, color)
  for regionY in max(0, ceil(first.y / browser.regionHeight.float64).int) ..
      min(browser.height div browser.regionHeight, floor(last.y / browser.regionHeight.float64).int):
    let point = browser.viewportPoint(0, (regionY * browser.regionHeight).float64)
    for x in startX ..< endX:
      if x mod 4 < 2: view.mapPixel(x, round(point.y).int, color)

proc drawSelection(view: WorldMapView, browser: WorldMapBrowser) =
  ## Mark the selected native pixel with a clipped high-contrast crosshair.
  if not browser.hasSelection: return
  let
    point = browser.viewportPoint(browser.selectedX.float64 + 0.5,
      browser.selectedY.float64 + 0.5)
    x = floor(point.x).int
    y = floor(point.y).int
    shadow = parseHtmlColor(DarkInk).rgbx
    color = parseHtmlColor(Gold).rgbx
  for offset in -SelectionRadius .. SelectionRadius:
    if abs(offset) > 2:
      for edge in -1 .. 1:
        view.mapPixel(x + offset, y + edge, shadow)
        view.mapPixel(x + edge, y + offset, shadow)
      view.mapPixel(x + offset, y, color)
      view.mapPixel(x, y + offset, color)

proc render*(view: WorldMapView, browser: WorldMapBrowser, scenery: Image,
    inspector: MapInspector, hover: Vec2, controllerCount: int): Image =
  ## Compose a native-size viewport and readable map inspection controls.
  if scenery == nil or scenery.width != MapViewport.w.int or scenery.height != MapViewport.h.int:
    raise newException(ValueError, "Atlas scenery must match the logical map viewport.")
  view.image.fill(parseHtmlColor(Background))
  view.box(rect(16, 16, 1168, 756), Frame, 25)
  view.label("pocket atlas", 34, 29, 32)
  view.label("the whole world, one little adventure", 36, 72, 14, Muted)
  view.label(&"{browser.width} x {browser.height} WORLD PIXELS", 834, 45, 14, Muted)
  view.label(&"{browser.regionCount} regions / {controllerCount} pad(s)", 834, 70, 12, Muted)
  view.box(rect(26, 100, 268, 660), Cream, 18)
  view.box(rect(29, 103, 262, 654), Panel, 15)
  view.box(rect(308, 102, 874, 664), Cream, 9)
  for y in 0 ..< scenery.height:
    copyMem(addr view.image.data[(MapViewport.y.int + y) * AtlasWidth + MapViewport.x.int],
      unsafeAddr scenery.data[y * scenery.width], scenery.width * sizeof(ColorRGBX))
  view.drawGrid(browser)
  view.drawSelection(browser)
  view.label("REGION ID", 38, 119, 11, Muted)
  view.label(&"{browser.selectedRegion:04d} / {browser.regionCount - 1:04d}", 142, 116, 17, Gold)
  view.label("ZOOM", 38, 196, 11, Muted)
  view.label(zoomLabel(browser.zoom), 88, 225, 20, Gold, 140, true)
  view.label("SELECTED LOCATION", 38, 382, 11, Gold)
  if inspector.valid:
    view.label(&"X {inspector.worldX}   Y {inspector.worldY}", 38, 408, 17)
    view.label(&"Region {inspector.regionIndex}", 38, 442, 15)
    view.label(&"Grid {inspector.regionX}, {inspector.regionY}", 38, 466, 14, Muted)
    view.label(&"Map tileset {inspector.tilesetId}", 38, 500, 15)
    view.label(&"Palette group {inspector.paletteId}", 38, 526, 15)
    view.label(&"CHR tile {inspector.tileId}", 38, 552, 15)
    view.label(&"Arrangement {inspector.arrangementId}", 38, 578, 15)
    view.label(&"Tile flags ${inspector.flags:04X}", 38, 608, 13, Muted)
  else:
    view.label("Click anywhere on the map", 38, 410, 15)
    view.label("to inspect its scenery.", 38, 438, 15, Muted)
    view.label("Drag to explore.", 38, 492, 15)
    view.label("Wheel to zoom.", 38, 520, 15)
    view.label("Enter inspects the center.", 38, 560, 13, Muted)
  for (action, area) in MapButtons:
    let
      hovered = area.contains(hover)
      primary = action == FitWorld
      text = case action
        of PreviousRegion: "< region"
        of NextRegion: "region >"
        of ZoomOut: "-"
        of ZoomIn: "+"
        of FitWorld: "whole world"
        of CenterSelection: "center here"
        of ToggleGrid: (if browser.grid: "region grid: on" else: "region grid: off")
        of InspectCenter: "inspect center"
        of ToggleFullscreen: "fullscreen"
        else: ""
    view.box(area, if hovered: Mint elif primary: Pink else: ButtonBlue, 10)
    view.label(text, area.x, area.y + 7,
      if action in {ZoomOut, ZoomIn}: 20'f32 else: 14'f32,
      if hovered or primary: DarkInk else: Ink, area.w, true)
  view.label(&"Center {browser.centerX.int}, {browser.centerY.int} / base scenery / animation frame 0",
    326, 779, 11, Muted)
  view.label("Mouse / keyboard / Paddy",
    34, 779, 10, Muted)
  view.image
