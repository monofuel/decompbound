import
  std/[math, unittest],
  paddy, pixie, windy,
  decompbound/[world_map_browser, world_map_view]

const
  WorldWidth = 8192
  WorldHeight = 10240
  RegionWidth = 256
  RegionHeight = 128
  RegionCount = 2560

proc browser(): WorldMapBrowser =
  ## Build a camera from synthetic atlas geometry without loading game bytes.
  newWorldMapBrowser(WorldWidth, WorldHeight, RegionWidth, RegionHeight,
    RegionCount, MapViewport.w.int, MapViewport.h.int)

proc pad(buttons: set[GamepadButton], x = 0'f32, y = 0'f32): Gamepad =
  ## Build public controller state without probing any physical device.
  for button in buttons: result.buttons = result.buttons or (1'u64 shl button.ord)
  result.axes[GamepadLStickX.ord] = x
  result.axes[GamepadLStickY.ord] = y

suite "World atlas camera and controls":
  test "fit overview contains all four corners at a power-of-two scale":
    let camera = browser()
    check camera.zoom == 1.0 / 16
    for point in [(0.0, 0.0), (WorldWidth.float64, 0.0),
        (0.0, WorldHeight.float64), (WorldWidth.float64, WorldHeight.float64)]:
      let view = camera.viewportPoint(point[0], point[1])
      check view.x >= 0 and view.x <= MapViewport.w.float64
      check view.y >= 0 and view.y <= MapViewport.h.float64
    expect ValueError:
      discard newWorldMapBrowser(WorldWidth, WorldHeight, RegionWidth,
        RegionHeight, RegionCount - 1, 862, 652)
    expect ValueError: discard fitZoom(0, WorldHeight, 862, 652)

  test "world and canvas coordinates invert and pointer anchored zoom stays fixed":
    let camera = browser()
    camera.setZoom(1, 431, 326)
    let
      before = camera.worldPoint(123, 411)
      projected = camera.viewportPoint(before.x, before.y)
    check abs(projected.x - 123) < 0.000001
    check abs(projected.y - 411) < 0.000001
    camera.zoomStep(1, 123, 411)
    let after = camera.worldPoint(123, 411)
    check abs(before.x - after.x) < 0.000001
    check abs(before.y - after.y) < 0.000001
    check camera.zoom == 2
    camera.zoomStep(-1, 123, 411)
    check camera.zoom == 1
    expect ValueError: camera.setZoom(3, 431, 326)
    expect ValueError: camera.setZoom(NaN, 431, 326)

  test "selection excludes letterboxing and map right/bottom boundaries":
    let camera = browser()
    camera.selectViewport(0, 0)
    check not camera.hasSelection
    camera.selectWorld(123.75, 456.25)
    check camera.selectedX == 123 and camera.selectedY == 456
    camera.selectWorld(WorldWidth.float64, 0)
    camera.selectWorld(0, WorldHeight.float64)
    camera.selectViewport(-1, 10)
    check camera.selectedX == 123 and camera.selectedY == 456
    camera.perform(InspectCenter)
    check camera.selectedX == WorldWidth div 2
    check camera.selectedY == WorldHeight div 2

  test "pan clamps edges and diagonal motion has the same speed as axial motion":
    let
      axial = browser()
      diagonal = browser()
    for camera in [axial, diagonal]: camera.setZoom(1, 431, 326)
    axial.advancePan({PanRight}, 0.05)
    diagonal.advancePan({PanRight, PanDown}, 0.05)
    check abs(hypot(diagonal.centerX - WorldWidth.float64 / 2,
      diagonal.centerY - WorldHeight.float64 / 2) -
      (axial.centerX - WorldWidth.float64 / 2)) < 0.000001
    axial.pan(-1_000_000, -1_000_000)
    check axial.centerX == MapViewport.w.float64 / 2
    check axial.centerY == MapViewport.h.float64 / 2
    axial.pan(1_000_000, 1_000_000)
    check axial.centerX == WorldWidth.float64 - MapViewport.w.float64 / 2
    check axial.centerY == WorldHeight.float64 - MapViewport.h.float64 / 2
    let before = axial.revision
    axial.advancePan({PanLeft, PanRight}, 0.05)
    check axial.revision == before
    axial.perform(FitWorld)
    axial.pan(300, 300)
    check axial.centerX == WorldWidth.float64 / 2
    check axial.centerY == WorldHeight.float64 / 2

  test "region navigation follows rows and stops at atlas endpoints":
    let camera = browser()
    camera.selectWorld(0, 0)
    camera.navigateRegion(-1)
    check camera.selectedRegion == 0
    camera.navigateRegion(32)
    check camera.selectedRegion == 32
    check camera.selectedX == RegionWidth div 2
    check camera.selectedY == RegionHeight + RegionHeight div 2
    camera.navigateRegion(100_000)
    check camera.selectedRegion == RegionCount - 1
    check camera.selectedX < WorldWidth and camera.selectedY < WorldHeight
    camera.navigateRegion(1)
    check camera.selectedRegion == RegionCount - 1

  test "click selects while drag pans and never changes the previous selection":
    let camera = browser()
    var drag: MapDrag
    camera.setZoom(1, 431, 326)
    drag.beginDrag(400, 300)
    drag.endDrag(camera, 402, 301)
    check camera.hasSelection
    let
      oldX = camera.selectedX
      oldY = camera.selectedY
      oldCenterX = camera.centerX
    drag.beginDrag(400, 300)
    drag.moveDrag(camera, 420, 300)
    drag.endDrag(camera, 430, 300)
    check camera.centerX == oldCenterX - 30
    check camera.selectedX == oldX and camera.selectedY == oldY
    check not drag.active

  test "keyboard and Paddy agree, repeat is limited, and reset releases held actions":
    check keyboardActions({KeyLeft, KeyEqual, KeyPageDown, KeyEnter, KeyG, KeyHome}) ==
      gamepadActions([pad({GamepadLeft, GamepadR1, GamepadR2, GamepadA, GamepadB, GamepadY})])
    check gamepadActions([pad({}, 0.2, -0.2)]) == {}
    check gamepadActions([pad({}, -0.8, 0.8)]) == {PanLeft, PanDown}
    check gamepadActions([pad({GamepadSelect, GamepadStart})]) == {QuitAtlas}
    var input: MapInput
    check input.update({ZoomIn, ToggleGrid, PanLeft}, 0) == @[ZoomIn, ToggleGrid]
    check input.update({ZoomIn, ToggleGrid, PanLeft}, 349).len == 0
    check input.update({ZoomIn, ToggleGrid, PanLeft}, 350) == @[ZoomIn]
    check input.update({ZoomIn, ToggleGrid, PanLeft}, 450) == @[ZoomIn]
    check input.update({ZoomIn, ZoomOut, PreviousRegion, NextRegion}, 500).len == 0
    input.reset()
    check input.update({ToggleGrid}, 501) == @[ToggleGrid]

  test "resized pointer mapping follows the responsive canvas without fixed-size letterboxing":
    check atlasPoint(vec2(600, 400), 1200, 800) == vec2(600, 400)
    check atlasPoint(vec2(1200, 800), 2400, 1600) == vec2(1200, 800)
    check atlasPoint(vec2(600, 450), 1200, 900) == vec2(600, 450)
    check atlasPoint(vec2(300, 200), 600, 400) == vec2(600, 400)
    check atlasPoint(vec2(0, 0), 0, 0) == vec2(-1, -1)
    check mouseActions(vec2(60, 292)) == {FitWorld}
    check mouseActions(vec2(600, 400)) == {}

  test "world controls navigate flags without moving the map or leaking held return actions":
    let camera = browser()
    camera.configureWorldFlags(15, 5)
    camera.perform(ShowWorldPanel)
    let center = (camera.centerX, camera.centerY)
    check keyboardActions({KeyTab}, WorldPanel) == {ToggleWorldPanel}
    check keyboardActions({KeyDown, KeyEnter}, WorldPanel) ==
      {WorldNextFlag, ToggleWorldFlag}
    check gamepadActions([pad({GamepadDown, GamepadA})], WorldPanel) ==
      {WorldNextFlag, ToggleWorldFlag}
    check keyboardActions({KeyW}, WorldPanel) == {PanUp}
    check gamepadActions([pad({}, 0.8, 0)], WorldPanel) == {PanRight}
    camera.navigateWorldFlag(100)
    check camera.worldRow == 14 and camera.worldScroll == 10
    camera.navigateWorldFlag(1)
    check camera.worldRow == 14
    camera.scrollWorldFlags(-100)
    check camera.worldScroll == 0 and camera.worldRow in 0 .. 4
    check (camera.centerX, camera.centerY) == center
    camera.configureWorldFlags(15, 8)
    camera.focusWorldRow(14)
    check camera.worldScroll == 7
    check mouseActions(vec2(210, 386)) == {ShowWorldPanel}
    check mouseActions(vec2(60, 680), AtlasHeight, WorldPanel) == {ResetWorldFlags}
    check worldFlagRow(vec2(70, 430), camera, AtlasHeight) == 7
    var input: MapInput
    check input.update({ShowInspectPanel}, 0) == @[ShowInspectPanel]
    check input.update({QuitAtlas}, 1).len == 0
    check input.update({QuitAtlas}, 500).len == 0
    discard input.update({}, 501)
    check input.update({QuitAtlas}, 502) == @[QuitAtlas]
    input.reset()
    check input.update({ShowInspectPanel}, 0) == @[ShowInspectPanel]
    check input.update({ToggleGrid}, 1).len == 0
    discard input.update({}, 2)
    check input.update({ToggleGrid}, 3) == @[ToggleGrid]

  test "changing panels cannot turn a held confirmation into another press":
    var input: MapInput
    check input.update({InspectCenter}, 0) == @[InspectCenter]
    check input.update({InspectCenter, ToggleWorldPanel}, 1) == @[ToggleWorldPanel]
    check input.update({ToggleWorldFlag}, 2).len == 0
    check input.update({ToggleWorldFlag}, 500).len == 0
    check input.update({InspectCenter}, 500).len == 0
    check input.update({ToggleWorldFlag}, 500).len == 0
    discard input.update({}, 501)
    check input.update({ToggleWorldFlag}, 502) == @[ToggleWorldFlag]
    check input.update({InspectCenter}, 503).len == 0
    discard input.update({}, 504)
    check input.update({InspectCenter}, 505) == @[InspectCenter]

  test "viewport resize preserves exploration and selection while updating whole-world fit":
    let camera = browser()
    camera.selectWorld(4000, 5000)
    camera.resizeViewport(1662, 1452)
    check camera.zoom == 0.125
    for point in [(0.0, 0.0), (WorldWidth.float64, WorldHeight.float64)]:
      let view = camera.viewportPoint(point[0], point[1])
      check view.x >= 0 and view.x <= 1662
      check view.y >= 0 and view.y <= 1452
    camera.setZoom(1, 831, 726)
    camera.centerAt(4000, 5000)
    camera.resizeViewport(1062, 852)
    check camera.centerX == 4000 and camera.centerY == 5000
    check camera.zoom == 1
    check camera.selectedX == 4000 and camera.selectedY == 5000
    let unchanged = camera.revision
    camera.resizeViewport(1062, 852)
    check camera.revision == unchanged
    camera.perform(FitWorld)
    camera.resizeViewport(462, 652)
    check camera.zoom == 0.03125
    check camera.centerX == WorldWidth.float64 / 2
    check camera.centerY == WorldHeight.float64 / 2
    expect ValueError: camera.resizeViewport(0, 800)

  test "responsive viewport consumes extra space and moves bottom controls":
    let
      normal = atlasLayout(1200, 800)
      large = atlasLayout(1600, 1100)
      small = atlasLayout(600, 400)
    check large.width == 1600 and large.height == 1100
    check large.viewport.w - normal.viewport.w == 400
    check large.viewport.h - normal.viewport.h == 300
    check small.width == 1200 and small.height == 800
    for dimensions in [(1600, 1), (1, 1600)]:
      let extreme = atlasLayout(dimensions[0], dimensions[1])
      check extreme.width <= 8192 and extreme.height <= 8192
      check extreme.viewport.w > 0 and extreme.viewport.h > 0
    check mouseActions(vec2(60, 980), large.height) == {InspectCenter}
    check mouseActions(vec2(60, 1027), large.height) == {ToggleFullscreen}
    check mouseActions(vec2(60, 680), large.height) == {}
    for dimensions in [(1600, 1100), (800, 800), (600, 400)]:
      let
        view = newWorldMapView(dimensions[0], dimensions[1])
        area = view.layout.viewport
        camera = newWorldMapBrowser(WorldWidth, WorldHeight, RegionWidth,
          RegionHeight, RegionCount, area.w.int, area.h.int)
        scenery = newImage(area.w.int, area.h.int)
        color = rgbx(230, 120, 50, 255)
      scenery.fill(color)
      let rendered = view.render(camera, scenery, MapInspector(), vec2(-1, -1), 0)
      check rendered.width == view.layout.width
      check rendered.height == view.layout.height
      check rendered[area.x.int, area.y.int] == color
      check rendered[(area.x + area.w).int - 1, (area.y + area.h).int - 1] == color

  test "view preserves the complete viewport and clips overlays to scenery":
    let
      camera = browser()
      scenery = newImage(MapViewport.w.int, MapViewport.h.int)
      background = rgbx(35, 90, 65, 255)
      corner = rgbx(220, 135, 75, 255)
      view = newWorldMapView()
    scenery.fill(background)
    scenery[0, 0] = corner
    scenery[scenery.width - 1, scenery.height - 1] = corner
    let image = view.render(camera, scenery, MapInspector(), vec2(-1, -1), 0)
    check image.width == AtlasWidth and image.height == AtlasHeight
    check image[MapViewport.x.int, MapViewport.y.int] == corner
    check image[(MapViewport.x + MapViewport.w).int - 1,
      (MapViewport.y + MapViewport.h).int - 1] == corner
    let chrome = image[MapViewport.x.int - 1, MapViewport.y.int]
    camera.selectWorld(0, 0)
    camera.perform(ToggleGrid)
    discard view.render(camera, scenery, MapInspector(), vec2(-1, -1), 1)
    check image[MapViewport.x.int - 1, MapViewport.y.int] == chrome
