import
  std/[monotimes, strformat, times],
  pixie,
  decompbound/[rom_pipeline, world_map, world_map_browser, world_map_view]

const Repeats = 5

proc main() =
  ## Measure scenery generation separately from composing the real responsive UI.
  let atlas = newWorldMapAtlas(readGoldBaserom())
  for (width, height) in [(1200, 800), (1920, 1080), (3840, 2160)]:
    let view = newWorldMapView()
    view.resize(width, height)
    let browser = newWorldMapBrowser(atlas.width, atlas.height, atlas.regionWidth,
      atlas.regionHeight, atlas.regionCount, view.layout.viewport.w.int,
      view.layout.viewport.h.int)
    browser.configureWorldFlags(atlas.flagCatalog().len, worldListRows(height))
    browser.showPanel(WorldPanel)
    for zoom in [0.125, 1.0, 2.0]:
      var
        sceneryMs, uiMs: float64
        image: Image
      for frame in 0 ..< Repeats:
        let start = getMonoTime()
        image = atlas.renderViewport(4096.0 + frame.float64, 5120, zoom,
          browser.viewportWidth, browser.viewportHeight)
        let middle = getMonoTime()
        discard view.render(browser, image, MapInspector(), vec2(-1, -1), 0,
          atlas.flagCatalog(), atlas.enabledFlags())
        let finish = getMonoTime()
        sceneryMs += (middle - start).inNanoseconds.float64 / 1_000_000
        uiMs += (finish - middle).inNanoseconds.float64 / 1_000_000
      echo &"{width}x{height} zoom={zoom}: scenery={sceneryMs / Repeats:.2f}ms UI={uiMs / Repeats:.2f}ms sample={image.data[image.data.len div 2]}"

main()
