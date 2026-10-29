import
  std/[algorithm, sets, strformat],
  pixie,
  decompbound/[cpu, rom_pipeline, snesbus, world_map, world_map_assets, world_map_layout],
  ./world_map/original_cpu

const
  OriginalPalette = 0xC007B6'u32
  OriginalReplacements = 0xC006F2'u32
  OriginalDecompressor = 0xC41A9E'u32
  EventBitsWram = 0x9C08
  EventBytes = 0x1000
  PaletteWram = 0x0240
  ArrangementWram = 0x7F8000'u32

proc word(rom: seq[uint8], offset: int): int =
  ## Read the test's source metadata independently of the product cache.
  rom[offset].int or (rom[offset + 1].int shl 8)

proc far(rom: seq[uint8], offset: int): int =
  ## Locate an original HiROM table entry without using native resource selection.
  (rom.word(offset) or (rom[offset + 2].int shl 16)) and 0x3FFFFF

proc paletteFlags(rom: seq[uint8], logical, palette: int): seq[int] =
  ## Collect all conditions along this original palette's alternate chain.
  var
    source = rom.far(WorldPalettePointersFile + logical * 4) + palette * WorldPaletteBytes
    visited: HashSet[int]
    flags: HashSet[int]
  while source notin visited:
    visited.incl(source)
    let condition = rom.word(source)
    if condition == 0: break
    flags.incl(condition and 0x7FFF)
    source = (rom.far(WorldPalettePointersFile) and 0x3F0000) + rom.word(source + 0x20)
  for id in flags: result.add(id)
  result.sort()

proc arrangementFlags(rom: seq[uint8], drawing: int): seq[int] =
  ## Collect each drawing resource's own conditions for exhaustive local truth tables.
  var
    source = 0x100000 + rom.word(WorldArrangementReplacementPointersFile + drawing * 2)
    flags: HashSet[int]
  while rom.word(source) != 0:
    flags.incl(rom.word(source) and 0x7FFF)
    source += 4 + rom.word(source + 2) * 4
  for id in flags: result.add(id)
  result.sort()

proc applyFlags(machine: SnesBus, flags: seq[int], mask: int): WorldMapStoryState =
  ## Set original WRAM event bits independently of the native value-state layout.
  for offset in 0 ..< EventBytes:
    machine.bus.write8(OracleWram + (EventBitsWram + offset).uint32, 0)
  for index, id in flags:
    let enabled = (mask and (1 shl index)) != 0
    result.setStoryFlag(id, enabled)
    if enabled:
      let
        address = OracleWram + (EventBitsWram + ((id - 1) div 8)).uint32
        original = machine.bus.read8(address)
      machine.bus.write8(address, original or uint8(1 shl ((id - 1) mod 8)))

proc verifyPalettes(rom: seq[uint8], machine: SnesBus): int =
  ## Compare every original palette word for all combinations of its dependencies.
  var checked: HashSet[(int, int)]
  for offset in RegionResourceFile ..< RegionResourceFile + RegionCount:
    let
      selector = rom[offset].int
      key = (selector shr 3, selector and 7)
    if key in checked: continue
    checked.incl(key)
    let flags = rom.paletteFlags(key[0], key[1])
    for mask in 0 ..< (1 shl flags.len):
      let
        state = machine.applyFlags(flags, mask)
        assets = newWorldMapAssets(rom, state)
        palette = assets.palette(key[0], key[1])
      discard machine.callOriginal(OriginalPalette, a = key[0], x = key[1], directPage = 0x1A00)
      for color in 0 ..< WorldPaletteBytes div 2:
        doAssert machine.wramWord(PaletteWram + color * 2) == palette.colors[32 + color].int,
          &"Palette {key} flags={flags} mask={mask} color={color}."
      inc result
  doAssert checked.len == 149

proc verifyArrangements(rom: seq[uint8], machine: SnesBus): int =
  ## Compare complete original arrangement buffers under all local flag combinations.
  for drawing in 0 ..< WorldDrawingTilesetCount:
    let
      flags = rom.arrangementFlags(drawing)
      source = rom.far(WorldArrangementPointersFile + drawing * 4)
    for mask in 0 ..< (1 shl flags.len):
      let
        state = machine.applyFlags(flags, mask)
        resource = newWorldMapAssets(rom, state).resource(drawing)
      machine.putWord(0x0E, source and 0xFFFF)
      machine.putWord(0x10, (source shr 16) or 0xC0)
      machine.putWord(0x12, 0x8000)
      machine.putWord(0x14, 0x7F)
      discard machine.callOriginal(OriginalDecompressor, directPage = 0)
      discard machine.callOriginal(OriginalReplacements, a = drawing, directPage = 0x1A00)
      for arrangement, cells in resource.arrangements:
        for index, actual in cells:
          doAssert machine.bus.read16(ArrangementWram +
            ((arrangement * WorldArrangementCells + index) * 2).uint32) == actual,
            &"Arrangement draw={drawing} flags={flags} mask={mask} arrangement={arrangement} tile={index}."
      inc result

proc verifyAtlasChanges(rom: seq[uint8]) =
  ## Exercise resolved resource replacement, palettes, snapshots, and idempotent reset.
  let
    atlas = newWorldMapAtlas(rom)
    baseline = atlas.renderViewport(4896, 1888, 1, 160, 96)
    original = atlas.assets.resource(6)
    baseRevision = atlas.stateRevision
  var originalWords = newSeq[array[WorldArrangementCells, uint16]](original.arrangements.len)
  for index, arrangement in original.arrangements: originalWords[index] = arrangement
  doAssert atlas.flagCatalog().len >= 15
  atlas.setStoryFlag(0x0044, true)
  doAssert atlas.stateRevision == baseRevision + 1
  let changed = atlas.renderViewport(4896, 1888, 1, 160, 96)
  doAssert changed.data != baseline.data, "Peaceful Rest Valley bridge did not change."
  doAssert original.arrangements == originalWords, "An old resource snapshot was mutated."
  atlas.setStoryFlag(0x0044, true)
  doAssert atlas.stateRevision == baseRevision + 1
  atlas.setStoryFlag(0x0047, true)
  doAssert atlas.flagEnabled(0x0044) and atlas.flagEnabled(0x0047)
  atlas.setStoryFlag(0x0044, false)
  doAssert atlas.renderViewport(4896, 1888, 1, 160, 96).data == baseline.data
  atlas.resetStoryFlags()
  doAssert atlas.enabledFlags().len == 0
  doAssert atlas.renderViewport(4896, 1888, 1, 160, 96).data == baseline.data
  let resetRevision = atlas.stateRevision
  atlas.resetStoryFlags()
  doAssert atlas.stateRevision == resetRevision
  let bridgePixel = atlas.pixel(4846, 1856)
  atlas.assets.setStoryFlag(0x0044, true)
  doAssert atlas.stateRevision == resetRevision + 1
  doAssert atlas.pixel(4846, 1856) != bridgePixel,
    "Changing the public asset state left the atlas's drawing snapshots stale."
  atlas.assets.resetStoryFlags()
  doAssert atlas.pixel(4846, 1856) == bridgePixel
  for witness in [(0x000D, 6912, 1536), (0x000E, 5942, 8552),
      (0x0031, 5407, 9552), (0x0044, 4846, 1856), (0x0046, 6144, 3584),
      (0x0047, 516, 7411), (0x0068, 1604, 25), (0x00AE, 3663, 9597),
      (0x011F, 0, 2048), (0x0120, 4640, 6912), (0x0137, 5030, 328),
      (0x0174, 5888, 2048), (0x01A6, 768, 0), (0x0205, 7424, 256),
      (0x022B, 5888, 4992)]:
    let before = atlas.pixel(witness[1], witness[2])
    atlas.setStoryFlag(witness[0], true)
    doAssert atlas.pixel(witness[1], witness[2]) != before,
      &"Catalog flag ${witness[0]:04X} changed no visible pixel at its verified witness."
    atlas.setStoryFlag(witness[0], false)
    doAssert atlas.pixel(witness[1], witness[2]) == before
  for specimen in [(0x01A6, 1600, 320), (0x011F, 256, 4900),
      (0x0047, 5424, 9590), (0x0047, 528, 7424), (0x0120, 4864, 7552)]:
    let before = atlas.renderViewport(specimen[1].float64,
      specimen[2].float64, 1, 160, 128)
    atlas.setStoryFlag(specimen[0], true)
    let after = atlas.renderViewport(specimen[1].float64,
      specimen[2].float64, 1, 160, 128)
    doAssert before.data != after.data,
      &"Named world change ${specimen[0]:04X} did not affect its landmark."
    atlas.setStoryFlag(specimen[0], false)
    doAssert atlas.renderViewport(specimen[1].float64,
      specimen[2].float64, 1, 160, 128).data == before.data,
      &"Named world change ${specimen[0]:04X} retained stale scenery after clearing."
  var rejected = false
  try: atlas.setStoryFlag(0x7FFF, true)
  except ValueError: rejected = true
  doAssert rejected, "An unsupported flag was accepted."

proc main() =
  ## Verify state-aware scenery against the original game rather than native self-comparison.
  let
    rom = readGoldBaserom()
    machine = newSnesBus(rom)
  defer: machine.releaseOriginal()
  let
    palettes = rom.verifyPalettes(machine)
    arrangements = rom.verifyArrangements(machine)
  rom.verifyAtlasChanges()
  echo "Original story-state truth tables passed: ", palettes,
    " palette states, ", arrangements, " complete arrangement states; cache transitions passed."

main()
