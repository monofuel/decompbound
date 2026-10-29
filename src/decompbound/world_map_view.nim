import
  std/[math, strformat, unicode],
  pixie,
  ./[companion_style, world_map, world_map_browser]

type
  AtlasLayout* = object
    width*, height*: int
    viewport*: Rect
  MapInspector* = object
    valid*: bool
    worldX*, worldY*, regionIndex*, regionX*, regionY*: int
    tileId*, tilesetId*, paletteId*, arrangementId*: int
    flags*: uint16
  WorldMapView* = ref object
    image*: Image
    layout*: AtlasLayout
    frame: seq[ColorRGBX]
    context: Context
    font: Font

const
  AtlasWidth* = 1200
  AtlasHeight* = 800
  MinimumAtlasWidth = 800
  MaximumCanvasDimension = 8192
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
    (ToggleFullscreen, rect(38, 710, 240, 34)),
    (ShowInspectPanel, rect(38, 374, 116, 28)),
    (ShowWorldPanel, rect(162, 374, 116, 28))]
  GridMinimumSpacing = 8.0
  SelectionRadius = 7
  WorldListTop = 414
  WorldRowHeight = 44
  WorldListBottomInset = 156
  WorldListLeft = 38
  WorldListWidth = 240

proc contains*(area: Rect, point: Vec2): bool =
  ## Test half-open logical UI bounds for pointer routing.
  point.x >= area.x and point.y >= area.y and
    point.x < area.x + area.w and point.y < area.y + area.h

proc atlasLayout*(width, height: int): AtlasLayout =
  ## Fill the window with a flexible map and scale controls only in small windows.
  if width <= 0 or height <= 0:
    raise newException(ValueError, "Atlas window dimensions must be positive.")
  let scale = min(1'f64, min(width.float64 / MinimumAtlasWidth.float64,
    height.float64 / AtlasHeight.float64))
  # Limit virtual canvas growth when a window becomes extremely thin or narrow.
  result.width = min(MaximumCanvasDimension,
    max(MinimumAtlasWidth, round(width.float64 / scale).int))
  result.height = min(MaximumCanvasDimension,
    max(AtlasHeight, round(height.float64 / scale).int))
  result.viewport = rect(MapViewport.x, MapViewport.y,
    (result.width - AtlasWidth).float32 + MapViewport.w,
    (result.height - AtlasHeight).float32 + MapViewport.h)

proc atlasPoint*(point: Vec2, width, height: int): Vec2 =
  ## Match pointer coordinates to the responsive texture's fitted GL viewport.
  if width <= 0 or height <= 0: return vec2(-1, -1)
  let
    layout = atlasLayout(width, height)
    ratio = min(width.float64 / layout.width.float64, height.float64 / layout.height.float64)
    scale = if ratio >= 1: floor(ratio) else: ratio
    fittedW = max(1, int(layout.width.float64 * scale))
    fittedH = max(1, int(layout.height.float64 * scale))
    origin = vec2(((width - fittedW) div 2).float32, ((height - fittedH) div 2).float32)
  (point - origin) / vec2(fittedW.float32 / layout.width.float32,
    fittedH.float32 / layout.height.float32)

proc canvasPoint*(point: Vec2): Vec2 =
  ## Convert a logical UI point to coordinates relative to the map canvas.
  point - vec2(MapViewport.x, MapViewport.y)

proc buttonArea(action: MapAction, area: Rect, height: int): Rect =
  ## Keep the final sidebar controls aligned with the bottom of the window.
  result = area
  if action in {InspectCenter, ToggleFullscreen}:
    result.y += (height - AtlasHeight).float32

proc mouseActions*(point: Vec2, height = AtlasHeight, panel = InspectPanel): set[MapAction] =
  ## Resolve sidebar controls independently from atlas selection and dragging.
  for (action, area) in MapButtons:
    if buttonArea(action, area, height).contains(point):
      result.incl(if action == InspectCenter and panel == WorldPanel:
        ResetWorldFlags else: action)

proc worldListRows*(height: int): int =
  ## Count complete catalog rows above the pinned sidebar controls.
  max(1, (height - WorldListTop - WorldListBottomInset) div WorldRowHeight)

proc worldPanelContains*(point: Vec2, height: int): bool =
  ## Route wheel gestures over the World sidebar independently of map zoom.
  rect(29, 103, 262, (height - 146).float32).contains(point)

proc worldFlagRow*(point: Vec2, browser: WorldMapBrowser, height: int): int =
  ## Resolve visible catalog rows without accepting gaps or controls as flags.
  result = -1
  if browser.panel != WorldPanel: return
  let rows = worldListRows(height)
  if rect(WorldListLeft.float32, WorldListTop.float32, WorldListWidth.float32,
      (rows * WorldRowHeight).float32).contains(point):
    let index = browser.worldScroll + (point.y.int - WorldListTop) div WorldRowHeight
    if index < browser.worldFlagCount: result = index

proc resize*(view: WorldMapView, width, height: int) =
  ## Reallocate the UI canvas only when the responsive layout changes size.
  let layout = atlasLayout(width, height)
  if view.image != nil and view.layout.width == layout.width and
      view.layout.height == layout.height: return
  view.layout = layout
  view.image = newImage(layout.width, layout.height)
  view.frame = @[]
  view.context = newContext(view.image)

proc newWorldMapView*(width = AtlasWidth, height = AtlasHeight): WorldMapView =
  ## Allocate the companion-themed canvas and embedded font once.
  result = WorldMapView(font: newFont(parseTtf(FontData)))
  result.resize(width, height)

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

proc shortLabel(view: WorldMapView, text: string, width, size: float32): string =
  ## Fit authored labels on one line without spilling into neighboring rows.
  view.font.size = size
  result = text
  if view.font.layoutBounds(result).x <= width: return
  while result.len > 0 and view.font.layoutBounds(result & "...").x > width:
    result = result.runeSubStr(0, result.runeLen - 1)
  result.add("...")

proc zoomLabel*(zoom: float64): string =
  ## Describe native pixel scale without rounding fractional overviews to zero.
  if zoom >= 1: $zoom.int & "x" else: "1/" & $(round(1 / zoom).int) & "x"

proc mapPixel(view: WorldMapView, x, y: int, color: ColorRGBX) =
  ## Clip map annotations to the interactive canvas.
  let viewport = view.layout.viewport
  if x >= 0 and y >= 0 and x < viewport.w.int and y < viewport.h.int:
    view.image[viewport.x.int + x, viewport.y.int + y] = color

proc drawGrid(view: WorldMapView, browser: WorldMapBrowser) =
  ## Draw region boundaries only at legible screen spacing.
  if not browser.grid: return
  let
    spacingX = browser.regionWidth.float64 * browser.zoom
    spacingY = browser.regionHeight.float64 * browser.zoom
    first = browser.worldPoint(0, 0)
    last = browser.worldPoint(view.layout.viewport.w.float64, view.layout.viewport.h.float64)
    atlasFirst = browser.viewportPoint(0, 0)
    atlasLast = browser.viewportPoint(browser.width.float64, browser.height.float64)
    startX = max(0, floor(atlasFirst.x).int)
    startY = max(0, floor(atlasFirst.y).int)
    endX = min(view.layout.viewport.w.int, ceil(atlasLast.x).int + 1)
    endY = min(view.layout.viewport.h.int, ceil(atlasLast.y).int + 1)
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

proc copyFrameBorder(view: WorldMapView, capture: bool) =
  ## Cache only the static border strips, leaving the map area for its scenery copy.
  let
    width = view.layout.width
    area = view.layout.viewport
    left = area.x.int
    right = (area.x + area.w).int
    top = area.y.int
    bottom = (area.y + area.h).int
  var position = 0
  template span(offset, count: int) =
    if count > 0:
      if capture:
        copyMem(addr view.frame[position], addr view.image.data[offset],
          count * sizeof(ColorRGBX))
      else:
        copyMem(addr view.image.data[offset], addr view.frame[position],
          count * sizeof(ColorRGBX))
      position += count
  span(0, top * width)
  for y in top ..< bottom:
    span(y * width, left)
    span(y * width + right, width - right)
  span(bottom * width, (view.layout.height - bottom) * width)

proc render*(view: WorldMapView, browser: WorldMapBrowser, scenery: Image,
    inspector: MapInspector, hover: Vec2, controllerCount: int,
    catalog: openArray[WorldMapFlag] = [], enabledFlags: openArray[int] = []): Image =
  ## Compose a native-size viewport and readable map inspection controls.
  let
    viewport = view.layout.viewport
    width = view.layout.width
    height = view.layout.height
  if scenery == nil or scenery.width != viewport.w.int or scenery.height != viewport.h.int:
    raise newException(ValueError, "Atlas scenery must match the logical map viewport.")
  if view.frame.len == 0:
    view.image.fill(parseHtmlColor(Background))
    view.box(rect(16, 16, (width - 32).float32, (height - 44).float32), Frame, 25)
    view.label("pocket atlas", 34, 29, 32)
    view.label("the whole world, one little adventure", 36, 72, 14, Muted)
    view.box(rect(26, 100, 268, (height - 140).float32), Cream, 18)
    view.box(rect(29, 103, 262, (height - 146).float32), Panel, 15)
    view.box(rect(viewport.x - 6, viewport.y - 6, viewport.w + 12, viewport.h + 12), Cream, 9)
    view.frame = newSeq[ColorRGBX](width * height - scenery.width * scenery.height)
    view.copyFrameBorder(capture = true)
  else:
    view.copyFrameBorder(capture = false)
  view.label(&"{browser.width} x {browser.height} WORLD PIXELS", (width - 366).float32, 45, 14, Muted)
  view.label(&"{browser.regionCount} regions / {controllerCount} pad(s)", (width - 366).float32, 70, 12, Muted)
  for y in 0 ..< scenery.height:
    copyMem(addr view.image.data[(viewport.y.int + y) * width + viewport.x.int],
      unsafeAddr scenery.data[y * scenery.width], scenery.width * sizeof(ColorRGBX))
  view.drawGrid(browser)
  view.drawSelection(browser)
  view.label("REGION ID", 38, 119, 11, Muted)
  view.label(&"{browser.selectedRegion:04d} / {browser.regionCount - 1:04d}", 142, 116, 17, Gold)
  view.label("ZOOM", 38, 196, 11, Muted)
  view.label(zoomLabel(browser.zoom), 88, 225, 20, Gold, 140, true)
  if browser.panel == WorldPanel:
    let rows = worldListRows(height)
    for visible in 0 ..< rows:
      let index = browser.worldScroll + visible
      if index >= catalog.len: break
      let
        flag = catalog[index]
        rowY = WorldListTop + visible * WorldRowHeight
        area = rect(WorldListLeft.float32, rowY.float32, WorldListWidth.float32,
          (WorldRowHeight - 3).float32)
        focused = index == browser.worldRow
        enabled = flag.id in enabledFlags
      if focused or area.contains(hover): view.box(area, ButtonBlue, 7)
      view.box(rect(44, (rowY + 12).float32, 15, 15), Cream, 3)
      if enabled: view.box(rect(47, (rowY + 15).float32, 9, 9), Pink, 1)
      view.label(view.shortLabel(flag.label, 196, 13), 68, (rowY + 4).float32, 13)
      view.label(&"${flag.id:04X}  " & (if enabled: "on" else: "off"),
        68, (rowY + 23).float32, 11, if enabled: Gold else: Muted)
    if catalog.len > rows:
      let
        trackHeight = (rows * WorldRowHeight).float32
        thumbHeight = max(12'f32, trackHeight * rows.float32 / catalog.len.float32)
        thumbY = WorldListTop.float32 + (trackHeight - thumbHeight) *
          browser.worldScroll.float32 / (catalog.len - rows).float32
      view.box(rect(282, WorldListTop.float32, 4, trackHeight), ButtonBlue, 2)
      view.box(rect(282, thumbY, 4, thumbHeight), Mint, 2)
    if catalog.len == 0:
      view.label("No map flags in this ROM.", 38, WorldListTop.float32, 14, Muted)
    elif browser.worldRow in 0 ..< catalog.len:
      view.label(view.shortLabel(catalog[browser.worldRow].description, 240, 10),
        38, (height - 153).float32, 10, Muted)
  elif inspector.valid:
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
  for (action, originalArea) in MapButtons:
    let
      area = buttonArea(action, originalArea, height)
      hovered = area.contains(hover)
      primary = action == FitWorld or
        (action == ShowInspectPanel and browser.panel == InspectPanel) or
        (action == ShowWorldPanel and browser.panel == WorldPanel)
      text = case action
        of PreviousRegion: "< region"
        of NextRegion: "region >"
        of ZoomOut: "-"
        of ZoomIn: "+"
        of FitWorld: "whole world"
        of CenterSelection: "center here"
        of ToggleGrid: (if browser.grid: "region grid: on" else: "region grid: off")
        of InspectCenter: (if browser.panel == WorldPanel: "reset world flags" else: "inspect center")
        of ToggleFullscreen: "fullscreen"
        of ShowInspectPanel: "Inspect"
        of ShowWorldPanel: (if catalog.len > 0: &"World ({catalog.len})" else: "World")
        else: ""
    view.box(area, if hovered: Mint elif primary: Pink else: ButtonBlue, 10)
    view.label(text, area.x, area.y + 7,
      if action in {ZoomOut, ZoomIn}: 20'f32 else: 14'f32,
      if hovered or primary: DarkInk else: Ink, area.w, true)
  view.label(&"Center {browser.centerX.int}, {browser.centerY.int} / {enabledFlags.len} flags on / animation frame 0",
    326, (height - 21).float32, 11, Muted)
  view.label("Mouse / keyboard / Paddy",
    34, (height - 21).float32, 10, Muted)
  view.image
