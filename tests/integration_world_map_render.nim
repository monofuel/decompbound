import
  std/[algorithm, math, os, sets, strformat, tables],
  pixie,
  decompbound/[cpu, png_state, ppu, rom_pipeline, save_state,
    snesbus, world_map, world_map_assets, world_map_layout],
  ./world_map/original_cpu

type
  PublishedWord = tuple[word, bg2: uint16]
  WordSources = array[WorldDrawingTilesetCount, Table[uint16, int]]

const
  OriginalDecompressor = 0xC41A9E'u32
  OriginalBaseReplacements = 0xC006F2'u32
  OriginalPublisherStart = 0x0EBD'u16
  OriginalPublisherEnd = 0x0EED'u16
  OriginalPalette = 0xC007B6'u32
  GraphicsWram = 0x7F0000'u32
  PublisherDirectPage = 0x1A00
  PublisherBg1 = 0x0400
  PublisherBg2 = 0x0402
  PublisherStepLimit = 40
  BackgroundOneMap = 0x3800
  BackgroundTwoMap = 0x3C00
  BackgroundOneMapRegister = 0x38'u8
  BackgroundTwoMapRegister = 0x3C'u8
  ModeOneBg3Priority = 9'u8
  BackgroundCharacters = 0x20'u8
  TileSide = 8
  TileColumns = ScreenWidth div TileSide
  PaletteStage = 0x0240
  FirstMapColor = 32
  WorldScrollX = 0x0031
  WorldScrollY = 0x0033
  ActiveMapTileset = 0x436E

proc loadOriginalResource(machine: SnesBus, resource: WorldMapResource) =
  ## Execute the ROM decoder and clear-event arrangement substitutions.
  for (source, destination) in [(resource.graphicsFile, 0),
      (resource.arrangementsFile, 0x8000)]:
    machine.putWord(0x0E, source and 0xFFFF)
    machine.putWord(0x10, (source shr 16) or 0xC0)
    machine.putWord(0x12, destination)
    machine.putWord(0x14, 0x7F)
    discard machine.callOriginal(OriginalDecompressor, directPage = 0)
  discard machine.callOriginal(OriginalBaseReplacements, a = resource.id,
    directPage = PublisherDirectPage)
  for word in 0 ..< WorldChrBytes div 2:
    machine.vram[word] = machine.bus.read16(GraphicsWram + (word * 2).uint32)

proc publishOriginal(machine: SnesBus, sourceOffset: int): PublishedWord =
  ## Execute the original BG1/BG2 publisher without reproducing its tile-ID branch.
  machine.putWord(PublisherDirectPage + 0x16, 0)
  machine.putWord(PublisherDirectPage + 0x18, 0)
  machine.putWord(PublisherDirectPage + 0x1C, PublisherBg2)
  machine.putWord(PublisherDirectPage + 0x1E, PublisherBg1)
  var
    state = Cpu(pbr: 0xC0, pc: OriginalPublisherStart, s: 0x1FFF,
      d: PublisherDirectPage, dbr: 0x7E, x: sourceOffset.uint16)
    steps = 0
  while state.pc != OriginalPublisherEnd or state.pbr != 0xC0:
    doAssert steps < PublisherStepLimit, "Original BG publisher did not reach its next tile."
    state.step(machine.bus)
    inc steps
  (machine.wramWord(PublisherBg1).uint16, machine.wramWord(PublisherBg2).uint16)

proc setupPpu(machine: SnesBus) =
  ## Configure the real mode-nine BG1/BG2 geometry with no sprites or screen effects.
  machine.ppuRegs[0] = 15
  machine.ppuRegs[5] = ModeOneBg3Priority
  machine.ppuRegs[7] = BackgroundOneMapRegister
  machine.ppuRegs[8] = BackgroundTwoMapRegister
  machine.ppuRegs[0x0B] = BackgroundCharacters
  machine.ppuRegs[0x2C] = 3
  machine.ppuRegs[0x2D] = 0
  machine.ppuRegs[0x2E] = 0
  machine.ppuRegs[0x2F] = 0
  machine.ppuRegs[0x30] = 0
  machine.ppuRegs[0x31] = 0
  machine.bgScroll = default(array[8, uint16])

proc collectWords(atlas: WorldMapAtlas): WordSources =
  ## Locate every distinct actually referenced tile word in original arrangement storage.
  for drawing in 0 ..< WorldDrawingTilesetCount:
    result[drawing] = initTable[uint16, int]()
  for row in 0 ..< MapRows:
    for column in 0 ..< MapColumns:
      let
        region = atlas.layout.regionAt(column * MapCellPixels, row * MapCellPixels)
        drawing = region.drawingTilesetId
        resource = atlas.assets.resource(drawing)
        arrangement = atlas.layout.arrangements[row * MapColumns + column].int
      for tile, word in resource.arrangements[arrangement]:
        result[drawing][word] = arrangement * WorldArrangementCells * 2 + tile * 2

proc verifyTileWords(machine: SnesBus, atlas: WorldMapAtlas): int =
  ## Compare all 64 pixels of each referenced word against original publication and the PPU.
  let sources = atlas.collectWords()
  let image = newImage(ScreenWidth, TileSide)
  machine.setupPpu()
  for color in 0 ..< machine.cgram.len:
    machine.cgram[color] = color.uint16
  for drawing in 0 ..< WorldDrawingTilesetCount:
    let resource = atlas.assets.resource(drawing)
    machine.loadOriginalResource(resource)
    var words: seq[uint16]
    for word in sources[drawing].keys: words.add(word)
    words.sort()
    var first = 0
    while first < words.len:
      let count = min(TileColumns, words.len - first)
      for slot in 0 ..< count:
        let
          word = words[first + slot]
          published = machine.publishOriginal(sources[drawing][word])
        doAssert published.word == word
        machine.vram[BackgroundOneMap + slot] = published.word
        machine.vram[BackgroundTwoMap + slot] = published.bg2
      for y in 0 ..< TileSide:
        machine.renderScanline(image, y)
      for slot in 0 ..< count:
        let word = words[first + slot]
        for y in 0 ..< TileSide:
          for x in 0 ..< TileSide:
            let
              color = resource.tileColorIndex(word, x, y)
              expected = bgr555ToColor(machine.cgram[color]).rgbx
            doAssert expected == image[slot * TileSide + x, y],
              &"Map PPU draw={drawing} word={word:04X} pixel={x},{y}."
      result += count
      first += count

proc verifyPalettePlacements(machine: SnesBus, atlas: WorldMapAtlas): int =
  ## Compare a complete map placement for every used logical-tileset/palette pair.
  var checked = initHashSet[(int, int)]()
  let image = newImage(ScreenWidth, MapCellPixels)
  for region in atlas.layout.regions:
    let key = (region.mapTilesetId, region.paletteId)
    if key in checked: continue
    checked.incl(key)
    let
      resource = atlas.assets.resource(region.drawingTilesetId)
      cell = atlas.layout.cellAt(region.x, region.y)
    machine.setupPpu()
    machine.loadOriginalResource(resource)
    discard machine.callOriginal(OriginalPalette, a = region.mapTilesetId,
      x = region.paletteId, directPage = PublisherDirectPage)
    machine.cgram = default(array[256, uint16])
    for color in 0 ..< WorldPaletteBytes div 2:
      machine.cgram[FirstMapColor + color] = machine.wramWord(PaletteStage + color * 2).uint16
    for y in 0 ..< MapCellPixels div TileSide:
      for x in 0 ..< MapCellPixels div TileSide:
        let
          sourceOffset = cell.arrangementId * WorldArrangementCells * 2 +
            (y * (MapCellPixels div TileSide) + x) * 2
          published = machine.publishOriginal(sourceOffset)
          destination = y * TileColumns + x
        machine.vram[BackgroundOneMap + destination] = published.word
        machine.vram[BackgroundTwoMap + destination] = published.bg2
    for y in 0 ..< MapCellPixels:
      machine.renderScanline(image, y)
    for y in 0 ..< MapCellPixels:
      for x in 0 ..< MapCellPixels:
        doAssert atlas.pixel(region.x + x, region.y + y) == image[x, y],
          &"Map palette placement region={region.index} pixel={x},{y}."
    inc result

proc verifyPrivateScene(rom: seq[uint8], atlas: WorldMapAtlas, path: string) =
  ## Compare a caller-supplied base-compatible scene and original strip masking.
  let
    machine = newSnesBus(rom)
    bytes = cast[seq[uint8]](readFile(path))
    state = extractStateForRom(bytes, romHashOf(rom))
    image = newImage(ScreenWidth, ScreenHeight)
  defer: machine.releaseOriginal()
  var cpu: Cpu
  deserializeState(state, machine, cpu)
  doAssert (machine.ppuRegs[5] and 7) == 1, "Private map oracle needs a mode-one world scene."
  machine.ppuRegs[0] = 15
  machine.ppuRegs[0x2C] = 3
  machine.ppuRegs[0x2D] = 0
  machine.ppuRegs[0x2E] = 0
  machine.ppuRegs[0x2F] = 0
  machine.ppuRegs[0x30] = 0
  machine.ppuRegs[0x31] = 0
  let
    worldX = machine.wramWord(WorldScrollX)
    worldY = machine.wramWord(WorldScrollY)
    activeMapTileset = machine.wramWord(ActiveMapTileset)
    backdrop = bgr555ToColor(machine.cgram[0]).rgbx
  for y in 0 ..< ScreenHeight:
    machine.renderScanline(image, y)
  var activePixels, maskedPixels: int
  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let
        region = atlas.layout.regionAt(worldX + x, worldY + y)
        active = region.mapTilesetId == activeMapTileset
      # C00B82/C00C92 reject neighboring logical families while filling strips.
      # The atlas displays those areas with their own resources instead.
      if active:
        doAssert atlas.pixel(worldX + x, worldY + y) == image[x, y],
          &"Private scene {path} pixel={x},{y} differs; its palette, animation, or arrangement may use a story variant."
        inc activePixels
      else:
        doAssert image[x, y] == backdrop,
          &"Private scene {path} pixel={x},{y} was not masked by the original strip loader."
        inc maskedPixels
  doAssert activePixels > 0, "Private map oracle needs visible pixels from the loaded logical tileset."
  echo "Private map scene matched ", activePixels, " active-family pixels and ",
    maskedPixels, " original strip-masked pixels: ", path

proc verifyViewport(atlas: WorldMapAtlas, x, y, zoom: float64,
    width, height: int) =
  ## Compare every viewport sample with the separately verified uncached pixel compositor.
  let
    image = atlas.renderViewport(x, y, zoom, width, height)
    left = x - width.float64 / (2 * zoom)
    top = y - height.float64 / (2 * zoom)
  for py in 0 ..< height:
    let worldY = floor(top + py.float64 / zoom).int
    for px in 0 ..< width:
      let worldX = floor(left + px.float64 / zoom).int
      doAssert image[px, py] == atlas.pixel(worldX, worldY),
        &"Viewport {width}x{height} camera={x},{y} zoom={zoom} pixel={px},{py}."

proc verifyViewports(atlas: WorldMapAtlas) =
  ## Exercise large output, repeated caches, subpixel cameras, margins and story invalidation.
  for (x, y, zoom, width, height) in [
      (4096.375, 5120.625, 0.0625, 317, 199),
      (256.125, 128.875, 0.5, 517, 257),
      (4096.375, 5120.625, 1.0, 1920, 1080),
      (6000.25, 7500.5, 2.0, 3840, 2160),
      (32.25, 32.75, 4.0, 129, 137),
      (8192.5, 10239.5, 8.0, 65, 67)]:
    atlas.verifyViewport(x, y, zoom, width, height)
    atlas.verifyViewport(x + 0.5, y - 0.25, zoom, width, height)
  for (flag, x, y) in [(0x0044, 4896.0, 1888.0), (0x011F, 256.0, 4900.0)]:
    atlas.verifyViewport(x, y, 2, 321, 199)
    atlas.assets.setStoryFlag(flag, true)
    atlas.verifyViewport(x, y, 2, 321, 199)
    atlas.assets.resetStoryFlags()
    atlas.verifyViewport(x, y, 2, 321, 199)
  echo "Viewport output matched uncached composition through 4K, repeated pans, margins and story changes."

proc main() =
  ## Verify native map rendering through independently generated original-code PPU state.
  let
    rom = readGoldBaserom()
    atlas = newWorldMapAtlas(rom)
    machine = newSnesBus(rom)
  defer: machine.releaseOriginal()
  let
    words = machine.verifyTileWords(atlas)
    palettes = machine.verifyPalettePlacements(atlas)
  echo "Original BG publisher and PPU matched all ", words,
    " referenced word/resource combinations at all 64 pixels."
  echo "Original palette and PPU matched complete placements for all ", palettes, " used palette selectors."
  atlas.verifyViewports()
  for index in 1 .. paramCount():
    verifyPrivateScene(rom, atlas, paramStr(index))

main()
