import
  std/math,
  paddy, windy

type
  MapAction* = enum
    PanLeft, PanRight, PanUp, PanDown, ZoomOut, ZoomIn, PreviousRegion,
    NextRegion, InspectCenter, CenterSelection, FitWorld, ToggleGrid,
    ToggleFullscreen, QuitAtlas, ToggleWorldPanel, ShowInspectPanel, ShowWorldPanel,
    WorldPreviousFlag, WorldNextFlag, ToggleWorldFlag, ResetWorldFlags
  MapPanel* = enum
    InspectPanel, WorldPanel
  WorldMapBrowser* = ref object
    width*, height*, regionWidth*, regionHeight*, regionCount*: int
    viewportWidth*, viewportHeight*: int
    centerX*, centerY*, zoom*, minimumZoom*: float64
    selectedX*, selectedY*: int
    hasSelection*, grid*: bool
    revision*: int
    panel*: MapPanel
    worldRow*, worldScroll*, worldFlagCount*, worldVisibleRows*: int
  MapInput* = object
    previous: set[MapAction]
    suppressed: set[MapAction]
    confirmationHeld: bool
    repeatAt: array[MapAction, int64]
  MapDrag* = object
    active*, moved*: bool
    startX, startY, previousX, previousY: float64

const
  MaximumZoom* = 8.0
  PanPixelsPerSecond* = 420.0
  InitialRepeatMs = 350'i64
  RepeatMs = 100'i64
  StickThreshold = 0.35'f32
  DragThreshold = 4.0
  ZoomTolerance = 0.000001
  MaximumPanSeconds = 0.1

proc markChanged(browser: WorldMapBrowser) =
  ## Invalidate the cached view after an observable model change.
  inc browser.revision

proc clampCamera(browser: WorldMapBrowser) =
  ## Keep the camera inside the atlas or center smaller maps in the viewport.
  let
    halfWidth = browser.viewportWidth.float64 / (2 * browser.zoom)
    halfHeight = browser.viewportHeight.float64 / (2 * browser.zoom)
  browser.centerX = if halfWidth * 2 >= browser.width.float64:
      browser.width.float64 / 2
    else: clamp(browser.centerX, halfWidth, browser.width.float64 - halfWidth)
  browser.centerY = if halfHeight * 2 >= browser.height.float64:
      browser.height.float64 / 2
    else: clamp(browser.centerY, halfHeight, browser.height.float64 - halfHeight)

proc fitZoom*(width, height, viewportWidth, viewportHeight: int): float64 =
  ## Choose a power-of-two scale that fits the entire atlas in the viewport.
  if min(min(width, height), min(viewportWidth, viewportHeight)) <= 0:
    raise newException(ValueError, "Map and viewport dimensions must be positive.")
  result = MaximumZoom
  let limit = min(viewportWidth.float64 / width.float64,
    viewportHeight.float64 / height.float64)
  while result > limit: result /= 2

proc newWorldMapBrowser*(width, height, regionWidth, regionHeight,
    regionCount, viewportWidth, viewportHeight: int): WorldMapBrowser =
  ## Create a fitted, unselected camera for validated atlas metadata.
  if min(min(width, height), min(regionWidth, regionHeight)) <= 0 or regionCount <= 0:
    raise newException(ValueError, "Map dimensions and region count must be positive.")
  if regionCount != ((width + regionWidth - 1) div regionWidth) *
      ((height + regionHeight - 1) div regionHeight):
    raise newException(ValueError, "Region count must match the rectangular atlas grid.")
  let minimumZoom = fitZoom(width, height, viewportWidth, viewportHeight)
  WorldMapBrowser(width: width, height: height, regionWidth: regionWidth,
    regionHeight: regionHeight, regionCount: regionCount,
    viewportWidth: viewportWidth, viewportHeight: viewportHeight,
    centerX: width.float64 / 2, centerY: height.float64 / 2,
    zoom: minimumZoom, minimumZoom: minimumZoom, revision: 1)

proc resizeViewport*(browser: WorldMapBrowser, width, height: int) =
  ## Resize the visible map while retaining its selected pixel and native zoom.
  if width <= 0 or height <= 0:
    raise newException(ValueError, "Map viewport dimensions must be positive.")
  if width == browser.viewportWidth and height == browser.viewportHeight: return
  let fitting = browser.zoom == browser.minimumZoom
  browser.viewportWidth = width
  browser.viewportHeight = height
  browser.minimumZoom = fitZoom(browser.width, browser.height, width, height)
  browser.zoom = if fitting: browser.minimumZoom else:
    max(browser.zoom, browser.minimumZoom)
  browser.clampCamera()
  browser.markChanged()

proc configureWorldFlags*(browser: WorldMapBrowser, count, visibleRows: int) =
  ## Keep the current flag and scroll position inside the visible catalog.
  if count < 0 or visibleRows <= 0:
    raise newException(ValueError, "World flag count and visible rows must be valid.")
  if browser.worldFlagCount == count and browser.worldVisibleRows == visibleRows: return
  browser.worldFlagCount = count
  browser.worldVisibleRows = visibleRows
  browser.worldRow = clamp(browser.worldRow, 0, max(0, count - 1))
  browser.worldScroll = clamp(browser.worldScroll, 0, max(0, count - visibleRows))
  browser.worldScroll = clamp(browser.worldScroll,
    max(0, browser.worldRow - visibleRows + 1), browser.worldRow)
  browser.markChanged()

proc showPanel*(browser: WorldMapBrowser, panel: MapPanel) =
  ## Switch sidebar content without changing the camera or selected map pixel.
  if browser.panel != panel:
    browser.panel = panel
    browser.markChanged()

proc focusWorldRow*(browser: WorldMapBrowser, row: int) =
  ## Focus a catalog row and reveal it for keyboard and controller navigation.
  if browser.worldFlagCount == 0: return
  let nextRow = clamp(row, 0, browser.worldFlagCount - 1)
  if nextRow == browser.worldRow: return
  browser.worldRow = nextRow
  browser.worldScroll = clamp(browser.worldScroll,
    max(0, nextRow - browser.worldVisibleRows + 1), nextRow)
  browser.markChanged()

proc navigateWorldFlag*(browser: WorldMapBrowser, direction: int) =
  ## Move through the actual flag catalog without wrapping at either endpoint.
  browser.focusWorldRow(browser.worldRow + direction)

proc scrollWorldFlags*(browser: WorldMapBrowser, direction: int) =
  ## Scroll the flag list while keeping its focused row visible.
  let nextScroll = clamp(browser.worldScroll + direction, 0,
    max(0, browser.worldFlagCount - browser.worldVisibleRows))
  if nextScroll == browser.worldScroll: return
  browser.worldScroll = nextScroll
  browser.worldRow = clamp(browser.worldRow, nextScroll,
    min(browser.worldFlagCount - 1, nextScroll + browser.worldVisibleRows - 1))
  browser.markChanged()

proc worldPoint*(browser: WorldMapBrowser, x, y: float64): tuple[x, y: float64] =
  ## Map a point relative to the viewport into native world coordinates.
  (browser.centerX + (x - browser.viewportWidth.float64 / 2) / browser.zoom,
    browser.centerY + (y - browser.viewportHeight.float64 / 2) / browser.zoom)

proc viewportPoint*(browser: WorldMapBrowser, x, y: float64): tuple[x, y: float64] =
  ## Map native world coordinates into a point relative to the viewport.
  ((x - browser.centerX) * browser.zoom + browser.viewportWidth.float64 / 2,
    (y - browser.centerY) * browser.zoom + browser.viewportHeight.float64 / 2)

proc selectWorld*(browser: WorldMapBrowser, x, y: float64) =
  ## Select a world pixel while ignoring letterbox space outside the atlas.
  if x < 0 or y < 0 or x >= browser.width.float64 or y >= browser.height.float64: return
  let
    selectedX = floor(x).int
    selectedY = floor(y).int
  if not browser.hasSelection or selectedX != browser.selectedX or selectedY != browser.selectedY:
    browser.selectedX = selectedX
    browser.selectedY = selectedY
    browser.hasSelection = true
    browser.markChanged()

proc selectViewport*(browser: WorldMapBrowser, x, y: float64) =
  ## Inspect a canvas point without accepting clicks outside its bounds.
  if x < 0 or y < 0 or x >= browser.viewportWidth.float64 or y >= browser.viewportHeight.float64: return
  let point = browser.worldPoint(x, y)
  browser.selectWorld(point.x, point.y)

proc selectedRegion*(browser: WorldMapBrowser): int =
  ## Return the row-major region containing the selected pixel, or the camera center.
  let
    x = if browser.hasSelection: browser.selectedX else: browser.centerX.int
    y = if browser.hasSelection: browser.selectedY else: browser.centerY.int
    columns = (browser.width + browser.regionWidth - 1) div browser.regionWidth
  clamp((y div browser.regionHeight) * columns + x div browser.regionWidth,
    0, browser.regionCount - 1)

proc pan*(browser: WorldMapBrowser, dx, dy: float64) =
  ## Pan by logical viewport pixels with stable speed at every zoom level.
  let
    oldX = browser.centerX
    oldY = browser.centerY
  browser.centerX += dx / browser.zoom
  browser.centerY += dy / browser.zoom
  browser.clampCamera()
  if browser.centerX != oldX or browser.centerY != oldY: browser.markChanged()

proc setZoom*(browser: WorldMapBrowser, zoom: float64, anchorX, anchorY: float64) =
  ## Change scale while preserving the world point underneath a viewport anchor.
  if zoom.classify in {fcNan, fcInf, fcNegInf} or zoom <= 0:
    raise newException(ValueError, "Zoom must be a finite positive power of two.")
  let exponent = log2(zoom)
  if abs(exponent - round(exponent)) > ZoomTolerance:
    raise newException(ValueError, "Zoom must be a power of two.")
  let nextZoom = clamp(zoom, browser.minimumZoom, MaximumZoom)
  if nextZoom == browser.zoom: return
  let anchor = browser.worldPoint(anchorX, anchorY)
  browser.zoom = nextZoom
  browser.centerX = anchor.x - (anchorX - browser.viewportWidth.float64 / 2) / nextZoom
  browser.centerY = anchor.y - (anchorY - browser.viewportHeight.float64 / 2) / nextZoom
  browser.clampCamera()
  browser.markChanged()

proc zoomStep*(browser: WorldMapBrowser, direction: int, anchorX, anchorY: float64) =
  ## Step one power of two in either direction around a viewport anchor.
  if direction == 0: return
  browser.setZoom(browser.zoom * (if direction > 0: 2.0 else: 0.5), anchorX, anchorY)

proc centerAt*(browser: WorldMapBrowser, x, y: float64) =
  ## Move to a supplied native coordinate and preserve the current zoom.
  if x.classify in {fcNan, fcInf, fcNegInf} or y.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "Camera coordinates must be finite.")
  let
    oldX = browser.centerX
    oldY = browser.centerY
  browser.centerX = x
  browser.centerY = y
  browser.clampCamera()
  if browser.centerX != oldX or browser.centerY != oldY: browser.markChanged()

proc navigateRegion*(browser: WorldMapBrowser, direction: int) =
  ## Select and center the neighboring region without wrapping atlas edges.
  let
    index = clamp(browser.selectedRegion + direction, 0, browser.regionCount - 1)
    columns = (browser.width + browser.regionWidth - 1) div browser.regionWidth
    left = (index mod columns) * browser.regionWidth
    top = (index div columns) * browser.regionHeight
    x = (left + min(browser.regionWidth, browser.width - left) div 2).float64
    y = (top + min(browser.regionHeight, browser.height - top) div 2).float64
  browser.selectWorld(x, y)
  browser.centerAt(x, y)

proc perform*(browser: WorldMapBrowser, action: MapAction) =
  ## Apply discrete actions independently of their mouse, keyboard, or pad source.
  let
    middleX = browser.viewportWidth.float64 / 2
    middleY = browser.viewportHeight.float64 / 2
  case action
  of ZoomOut: browser.zoomStep(-1, middleX, middleY)
  of ZoomIn: browser.zoomStep(1, middleX, middleY)
  of PreviousRegion: browser.navigateRegion(-1)
  of NextRegion: browser.navigateRegion(1)
  of InspectCenter: browser.selectWorld(browser.centerX, browser.centerY)
  of CenterSelection:
    if browser.hasSelection: browser.centerAt(browser.selectedX.float64, browser.selectedY.float64)
  of FitWorld:
    browser.zoom = browser.minimumZoom
    browser.centerX = browser.width.float64 / 2
    browser.centerY = browser.height.float64 / 2
    browser.markChanged()
  of ToggleGrid:
    browser.grid = not browser.grid
    browser.markChanged()
  of ToggleWorldPanel:
    browser.showPanel(if browser.panel == InspectPanel: WorldPanel else: InspectPanel)
  of ShowInspectPanel: browser.showPanel(InspectPanel)
  of ShowWorldPanel: browser.showPanel(WorldPanel)
  of WorldPreviousFlag: browser.navigateWorldFlag(-1)
  of WorldNextFlag: browser.navigateWorldFlag(1)
  of PanLeft, PanRight, PanUp, PanDown, ToggleFullscreen, QuitAtlas,
      ToggleWorldFlag, ResetWorldFlags: discard

proc advancePan*(browser: WorldMapBrowser, actions: set[MapAction], seconds: float64) =
  ## Advance held directions in elapsed time with normalized diagonal motion.
  if seconds <= 0: return
  var
    dx = (if PanRight in actions: 1.0 else: 0.0) - (if PanLeft in actions: 1.0 else: 0.0)
    dy = (if PanDown in actions: 1.0 else: 0.0) - (if PanUp in actions: 1.0 else: 0.0)
  let length = sqrt(dx * dx + dy * dy)
  if length > 0:
    dx /= length
    dy /= length
    browser.pan(dx * PanPixelsPerSecond * min(seconds, MaximumPanSeconds),
      dy * PanPixelsPerSecond * min(seconds, MaximumPanSeconds))

proc keyboardActions*(keys: set[Button], panel = InspectPanel): set[MapAction] =
  ## Translate keyboard controls into shared atlas actions.
  for (key, action) in [
    (KeyA, PanLeft), (KeyD, PanRight), (KeyW, PanUp), (KeyS, PanDown),
    (KeyMinus, ZoomOut), (KeyEqual, ZoomIn), (KeyPageUp, PreviousRegion),
    (KeyPageDown, NextRegion), (KeyC, CenterSelection), (KeyTab, ToggleWorldPanel),
    (KeyHome, FitWorld), (KeyG, ToggleGrid), (KeyF11, ToggleFullscreen)]:
    if key in keys: result.incl(action)
  for (key, action) in [(KeyLeft, PanLeft), (KeyRight, PanRight),
      (KeyUp, PanUp), (KeyDown, PanDown)]:
    if key in keys:
      result.incl(if panel == InspectPanel: action elif action in {PanLeft, PanUp}:
        WorldPreviousFlag else: WorldNextFlag)
  if KeyEnter in keys: result.incl(if panel == WorldPanel: ToggleWorldFlag else: InspectCenter)
  if KeySpace in keys and panel == WorldPanel: result.incl(ToggleWorldFlag)
  if KeyEscape in keys: result.incl(if panel == WorldPanel: ShowInspectPanel else: QuitAtlas)

proc gamepadActions*(pads: openArray[Gamepad], panel = InspectPanel): set[MapAction] =
  ## Read only Paddy's public controller state and positional button names.
  for pad in pads:
    for (button, action) in [
      (GamepadL1, ZoomOut), (GamepadR1, ZoomIn),
      (GamepadL2, PreviousRegion), (GamepadR2, NextRegion),
      (GamepadX, CenterSelection), (GamepadY, FitWorld),
      (GamepadStart, ToggleFullscreen), (GamepadSelect, ToggleWorldPanel)]:
      if pad.button(button): result.incl(action)
    for (button, action) in [(GamepadLeft, PanLeft), (GamepadRight, PanRight),
        (GamepadUp, PanUp), (GamepadDown, PanDown)]:
      if pad.button(button):
        result.incl(if panel == InspectPanel: action elif action in {PanLeft, PanUp}:
          WorldPreviousFlag else: WorldNextFlag)
    if pad.button(GamepadA): result.incl(if panel == WorldPanel: ToggleWorldFlag else: InspectCenter)
    if pad.button(GamepadB): result.incl(if panel == WorldPanel: ShowInspectPanel else: ToggleGrid)
    if pad.axis(GamepadLStickX) < -StickThreshold: result.incl(PanLeft)
    if pad.axis(GamepadLStickX) > StickThreshold: result.incl(PanRight)
    if pad.axis(GamepadLStickY) < -StickThreshold: result.incl(PanUp)
    if pad.axis(GamepadLStickY) > StickThreshold: result.incl(PanDown)
    if pad.button(GamepadSelect) and pad.button(GamepadStart):
      result.excl(ToggleFullscreen)
      result.excl(ToggleWorldPanel)
      result.incl(QuitAtlas)

proc update*(input: var MapInput, held: set[MapAction], nowMs: int64): seq[MapAction] =
  ## Edge-trigger actions and repeat region navigation, flag selection, and zoom.
  var actions = held - {PanLeft, PanRight, PanUp, PanDown}
  # Enter/A is one gesture even when switching panels remaps its action.
  let confirmation = actions * {InspectCenter, ToggleWorldFlag}
  if input.confirmationHeld: actions = actions - confirmation
  input.confirmationHeld = confirmation.len > 0
  input.suppressed = input.suppressed * actions
  actions = actions - input.suppressed
  for (first, second) in [(ZoomIn, ZoomOut), (PreviousRegion, NextRegion),
      (WorldPreviousFlag, WorldNextFlag)]:
    if first in actions and second in actions:
      actions.excl(first)
      actions.excl(second)
  for action in actions:
    if action notin input.previous:
      result.add(action)
      input.repeatAt[action] = nowMs + InitialRepeatMs
    elif action in {PreviousRegion, NextRegion, ZoomIn, ZoomOut,
        WorldPreviousFlag, WorldNextFlag} and nowMs >= input.repeatAt[action]:
      result.add(action)
      input.repeatAt[action] = nowMs + RepeatMs
  input.previous = actions
  # Returning changes Escape/B's meaning while its physical key may remain held.
  # Retain that gesture until release rather than exiting or toggling the grid.
  if ShowInspectPanel in actions:
    input.suppressed = {QuitAtlas, ToggleGrid}

proc reset*(input: var MapInput) =
  ## Release remembered actions when the window loses focus.
  input = MapInput()

proc beginDrag*(drag: var MapDrag, x, y: float64) =
  ## Begin tracking a primary-button gesture in viewport coordinates.
  drag = MapDrag(active: true, startX: x, startY: y, previousX: x, previousY: y)

proc moveDrag*(drag: var MapDrag, browser: WorldMapBrowser, x, y: float64) =
  ## Pan after a small drag threshold while retaining accurate click detection.
  if not drag.active: return
  if not drag.moved and hypot(x - drag.startX, y - drag.startY) >= DragThreshold:
    drag.moved = true
    browser.pan(drag.startX - x, drag.startY - y)
  elif drag.moved:
    browser.pan(drag.previousX - x, drag.previousY - y)
  drag.previousX = x
  drag.previousY = y

proc endDrag*(drag: var MapDrag, browser: WorldMapBrowser, x, y: float64) =
  ## Inspect a stationary click or finish a drag without changing selection.
  if not drag.active: return
  drag.moveDrag(browser, x, y)
  if not drag.moved: browser.selectViewport(x, y)
  drag = MapDrag()
