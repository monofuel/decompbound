import
  std/[monotimes, options, os, parseopt, strformat, strutils, times],
  paddy, pixie, windy,
  ../decompbound/[rom_pipeline, world_map, world_map_browser, world_map_view],
  ./glblit

const
  UiFrameNs = 1_000_000_000'i64 div 30
  PollSleepMs = 2
  Help = """Pocket Atlas - the EarthBound world map from your own US ROM.
Usage: bin/map-browser [ROM] [--rom:PATH] [--x:N] [--y:N] [--zoom:fit|FACTOR]
  --fullscreen  Open fullscreen.
  --frames:N    Exit after N presented UI frames (for bounded smoke checks).
  --trace       Print camera, selection, actions, and viewport render counts.
Mouse: drag the map to pan; click to inspect; wheel up/down zooms around pointer.
Keyboard: arrows/WASD pan; +/- zoom; PageUp/PageDown select neighboring regions.
  Enter inspects center; C centers selection; Home fits world; G toggles grid.
  F11 toggles fullscreen; Escape exits.
Paddy: D-pad/stick pan; L1/R1 zoom; L2/R2 regions; A inspects; X centers;
  Y fits world; B toggles grid; Start fullscreen; Select+Start exits.
Zoom factors are powers of two through 8x; fractional factors show overviews.
Base scenery is static at animation frame zero. No ROM, state, or save is changed.
"""

type
  AtlasApp = object
    atlas: WorldMapAtlas
    browser: WorldMapBrowser
    blit: GlBlit
    quitting, trace: bool

proc traceState(app: AtlasApp, action: string) =
  ## Report testable navigation state without writing game-derived image data.
  if app.trace:
    let browser = app.browser
    echo &"action={action} center={browser.centerX:.3f},{browser.centerY:.3f} zoom={browser.zoom} region={browser.selectedRegion} selected={browser.hasSelection}:{browser.selectedX},{browser.selectedY} grid={browser.grid} viewport={browser.viewportWidth}x{browser.viewportHeight} canvas={app.blit.nativeW}x{app.blit.nativeH}"

proc perform(app: var AtlasApp, action: MapAction) =
  ## Apply window operations or route an input action through the camera model.
  case action
  of QuitAtlas: app.quitting = true
  of ToggleFullscreen: app.blit.window.fullscreen = not app.blit.window.fullscreen
  else: app.browser.perform(action)
  app.traceState($action)

proc inspector(app: AtlasApp): MapInspector =
  ## Copy the independently decoded map cell into the UI-only inspector model.
  if not app.browser.hasSelection: return
  let cell = app.atlas.inspect(app.browser.selectedX, app.browser.selectedY)
  MapInspector(valid: cell.valid, worldX: cell.worldX, worldY: cell.worldY,
    regionIndex: cell.regionIndex, regionX: cell.regionX, regionY: cell.regionY,
    tileId: cell.tileId, tilesetId: cell.tilesetId, paletteId: cell.paletteId,
    arrangementId: cell.arrangementId, flags: cell.flags)

proc main() =
  ## Run the ROM-backed atlas browser without starting an emulator or audio device.
  var
    romPath = resolveGoldBaseromPath()
    initialX, initialY: Option[int]
    initialZoom = "fit"
    frameLimit = 0
    fullscreen, trace = false
  for kind, key, value in getopt():
    case kind
    of cmdArgument: romPath = key
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": stdout.write(Help); return
      of "rom":
        if value.len == 0: raise newException(ValueError, "Use --rom:PATH.")
        romPath = value
      of "x": initialX = some(parseInt(value))
      of "y": initialY = some(parseInt(value))
      of "zoom": initialZoom = value
      of "fullscreen": fullscreen = true
      of "trace": trace = true
      of "frames":
        frameLimit = parseInt(value)
        if frameLimit <= 0: raise newException(ValueError, "Frame limit must be positive.")
      else: raise newException(ValueError, "Unknown option: " & key)
    of cmdEnd: discard
  let
    atlas = loadWorldMapAtlas(romPath)
    browser = newWorldMapBrowser(atlas.width, atlas.height, atlas.regionWidth,
      atlas.regionHeight, atlas.regionCount, MapViewport.w.int, MapViewport.h.int)
    view = newWorldMapView()
  if initialZoom != "fit":
    let zoom = parseFloat(initialZoom)
    if zoom < browser.minimumZoom or zoom > MaximumZoom:
      raise newException(ValueError, "Zoom is outside the supported overview-to-8x range.")
    browser.setZoom(zoom, MapViewport.w.float64 / 2, MapViewport.h.float64 / 2)
  if initialX.isSome or initialY.isSome:
    let
      x = initialX.get(atlas.width div 2)
      y = initialY.get(atlas.height div 2)
    if x notin 0 ..< atlas.width or y notin 0 ..< atlas.height:
      raise newException(ValueError, "Initial coordinates are outside the atlas.")
    browser.centerAt(x.float64, y.float64)
    browser.selectWorld(x.float64, y.float64)
  var app = AtlasApp(atlas: atlas, browser: browser, trace: trace,
    blit: initGlBlit("Pocket Atlas", AtlasWidth, AtlasHeight, scale = 1,
      fullscreen = fullscreen, vsync = false))
  defer: app.blit.close()
  initGamepads()
  defer: closeGamepads()
  echo &"Pocket Atlas: {atlas.width}x{atlas.height} pixels; {atlas.regionCount} regions; static base scenery."
  app.traceState("startup")
  var
    input: MapInput
    drag: MapDrag
    scenery: Image
    renderedCenterX, renderedCenterY, renderedZoom: float64
    renderedRevision = -1
    previousControllers = -1
    previousHover: set[MapAction]
    previous = getMonoTime()
    nextUi = previous
    frameCount, viewportRenders = 0
    previousWindowWidth = AtlasWidth
    previousWindowHeight = AtlasHeight
  while not app.quitting:
    pollEvents()
    let window = app.blit.window
    if window.closeRequested: break
    if window.size.x > 0 and window.size.y > 0 and
        (window.size.x.int != previousWindowWidth or window.size.y.int != previousWindowHeight):
      previousWindowWidth = window.size.x.int
      previousWindowHeight = window.size.y.int
      view.resize(previousWindowWidth, previousWindowHeight)
      browser.resizeViewport(view.layout.viewport.w.int, view.layout.viewport.h.int)
      app.blit.resize(view.layout.width, view.layout.height)
      drag = MapDrag()
      app.traceState("resize")
    let
      now = getMonoTime()
      elapsed = (now - previous).inNanoseconds.float64 / 1_000_000_000
      pads = pollGamepads()
      mouse = atlasPoint(vec2(window.mousePos.x.float32, window.mousePos.y.float32),
        window.size.x.int, window.size.y.int)
      canvas = mouse.canvasPoint()
      hover = mouseActions(mouse, view.layout.height)
    previous = now
    if window.focused and not window.minimized:
      var keys: set[Button]
      for key in Button:
        if window.buttonDown[key] or window.buttonPressed[key]: keys.incl(key)
      let held = world_map_browser.keyboardActions(keys) + world_map_browser.gamepadActions(pads)
      browser.advancePan(held, elapsed)
      for action in input.update(held, now.ticks div 1_000_000): app.perform(action)
      if view.layout.viewport.contains(mouse) and window.scrollDelta.y != 0:
        browser.zoomStep(if window.scrollDelta.y < 0: 1 else: -1,
          canvas.x.float64, canvas.y.float64)
        app.traceState("wheel")
      if window.buttonPressed[MouseLeft]:
        if view.layout.viewport.contains(mouse): drag.beginDrag(canvas.x.float64, canvas.y.float64)
        else:
          for action in hover: app.perform(action)
      if drag.active and window.buttonDown[MouseLeft]:
        drag.moveDrag(browser, canvas.x.float64, canvas.y.float64)
      if drag.active and window.buttonReleased[MouseLeft]:
        drag.endDrag(browser, canvas.x.float64, canvas.y.float64)
        app.traceState("pointer")
    else:
      input.reset()
      drag = MapDrag()
    if now >= nextUi and not window.minimized:
      let changed = browser.revision != renderedRevision or
        pads.len != previousControllers or hover != previousHover
      if changed:
        if scenery == nil or scenery.width != browser.viewportWidth or
            scenery.height != browser.viewportHeight or renderedCenterX != browser.centerX or
            renderedCenterY != browser.centerY or renderedZoom != browser.zoom:
          scenery = atlas.renderViewport(browser.centerX, browser.centerY,
            browser.zoom, browser.viewportWidth, browser.viewportHeight)
          renderedCenterX = browser.centerX
          renderedCenterY = browser.centerY
          renderedZoom = browser.zoom
          inc viewportRenders
        app.blit.upload(view.render(browser, scenery, app.inspector(), mouse, pads.len))
        renderedRevision = browser.revision
        previousControllers = pads.len
        previousHover = hover
      app.blit.draw()
      window.swapBuffers()
      inc frameCount
      nextUi = getMonoTime() + initDuration(nanoseconds = UiFrameNs)
      if frameLimit > 0 and frameCount >= frameLimit: break
    sleep(PollSleepMs)
  if trace: echo &"uiFrames={frameCount} viewportRenders={viewportRenders}"

when isMainModule:
  main()
