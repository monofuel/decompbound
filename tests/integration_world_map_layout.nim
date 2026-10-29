import
  std/[sets, strformat],
  decompbound/[asm_parse, cpu, rom_pipeline, snesbus, world_map_layout],
  ./world_map/original_cpu

const
  ArrangementReader = 0xC0A152'u32
  AttributeReader = 0xC00AA1'u32
  ResourceLoader = 0xC008C3'u32
  ResourceSelectionEnd = 0x0924'u16
  SelectionStepLimit = 200
  DirectPage = 0x1A00
  CacheColumn = 0x2888
  CacheRow = 0x288A
  CacheResult = 0x288C
  RegionAttributeShadow = 0x438E
  CameraXCharacters = 0x438A
  CameraYCharacters = 0x438C
  CharacterPixels = 8
  PreservedY = 0x1234

proc verifyAssembly(rom: seq[uint8]) =
  ## Require each annotated routine and the corrected dispatch table to match gold.
  for (file, offset, length) in [
      ("asm/readWorldMapTile.asm", 0x00A152, 92),
      ("asm/readWorldMapTileTail.asm", 0x00A1CE, 36),
      ("asm/readWorldMapRegionAttributes.asm", 0x000AA1, 36),
      ("asm/jmpTableA1AE.asm", 0x00A1AE, 32)]:
    let assembled = assembleAsm(readFile(file), offset.uint32)
    doAssert assembled.len == length, file
    for index, value in assembled:
      doAssert value == rom[offset + index], &"{file}: byte {index} differs."

proc verifyResources(machine: SnesBus, region: WorldMapRegion,
    worldX, worldY: int) =
  ## Execute C008C3's resource selector before its first arrangement-pointer read.
  let caller = 0x1E00'u32
  let code = assembleAsm(".a16\n.i16\nJSL $C008C3\n", caller)
  for index, value in code:
    machine.bus.write8(OracleWram + caller + index.uint32, value)
  machine.putWord(CameraXCharacters, worldX div CharacterPixels)
  machine.putWord(CameraYCharacters, worldY div CharacterPixels)
  var
    state = Cpu(pbr: 0x7E, pc: caller.uint16, s: 0x1FFF, d: DirectPage,
      dbr: 0x7E, a: region.column.uint16, x: region.row.uint16)
    steps = 0
  while state.pbr != 0xC0 or state.pc != ResourceSelectionEnd:
    doAssert steps < SelectionStepLimit
    state.step(machine.bus)
    inc steps
  let local = state.d.int
  doAssert machine.wramWord(local + 4) == region.mapTilesetId
  doAssert machine.wramWord(local + 0x16) == region.drawingTilesetId
  doAssert machine.wramWord(local + 0x18) == region.paletteId

proc verifyCoordinateReader(machine: SnesBus, layout: WorldMapLayout) =
  ## Check all 81,920 placements against original code and exercise its cache contract.
  var arrangements = initHashSet[int]()
  for y in 0 ..< MapRows:
    for x in 0 ..< MapColumns:
      machine.putWord(CacheColumn, 0xFFFF)
      let state = machine.callOriginal(ArrangementReader, a = x, x = y,
        directPage = DirectPage)
      let expected = layout.arrangements[y * MapColumns + x].int
      doAssert state.a.int == expected, &"Map {x},{y}: {state.a} != {expected}."
      doAssert state.d == DirectPage and state.dbr == 0x7E and state.s == 0x1FFF
      doAssert machine.wramWord(CacheColumn) == x and machine.wramWord(CacheRow) == y
      doAssert machine.wramWord(CacheResult) == expected
      arrangements.incl(expected)
  for (x, y) in [(0xFFFF, 0), (0, 0xFFFF), (0xFFFF, 0xFFFF)]:
    let state = machine.callOriginal(ArrangementReader, a = x, x = y,
      y = PreservedY, directPage = DirectPage)
    doAssert state.a == 0xFFFF and state.x == y.uint16 and state.y == PreservedY
    doAssert state.d == DirectPage and state.dbr == 0x7E and state.s == 0x1FFF
  let
    x = 17
    y = 29
    authoredCacheValue = (layout.arrangements[y * MapColumns + x].int + 1) and 0x3FF
  machine.putWord(CacheColumn, x)
  machine.putWord(CacheRow, y)
  machine.putWord(CacheResult, authoredCacheValue)
  let hit = machine.callOriginal(ArrangementReader, a = x, x = y,
    y = PreservedY, directPage = DirectPage)
  doAssert hit.a.int == authoredCacheValue and hit.x.int == y and hit.y == PreservedY
  doAssert hit.d == DirectPage and hit.dbr == 0x7E and hit.s == 0x1FFF
  doAssert (hit.p and 0x30) == 0
  echo "Original C0A152 matched all ", MapColumns * MapRows,
    " placements (", arrangements.len, " distinct IDs); cache and registers matched."

proc verifyRegions(machine: SnesBus, layout: WorldMapLayout) =
  ## Check every sector corner against original attribute and resource selectors.
  for region in layout.regions:
    for delta in [(0, 0), (RegionWidth - 1, 0), (0, RegionHeight - 1),
        (RegionWidth - 1, RegionHeight - 1)]:
      let
        worldX = region.x + delta[0]
        worldY = region.y + delta[1]
        state = machine.callOriginal(AttributeReader, a = worldX, x = worldY,
          y = PreservedY, directPage = DirectPage)
      doAssert state.a == region.attributes
      doAssert machine.wramWord(RegionAttributeShadow) == region.attributes.int
      doAssert state.d == DirectPage and state.dbr == 0x7E and state.s == 0x1FFF
      doAssert state.y == PreservedY and (state.p and 0x30) == 0
      machine.verifyResources(region, worldX, worldY)
  echo "Original C00AA1/C008C3 matched all ", RegionCount,
    " sector attributes and graphics/palette selectors at all four corners."

proc main() =
  ## Verify the complete ROM-backed atlas layout and its adopted original routines.
  let
    rom = readGoldBaserom()
    layout = newWorldMapLayout(rom)
    machine = newSnesBus(rom)
  defer: machine.releaseOriginal()
  verifyAssembly(rom)
  machine.verifyCoordinateReader(layout)
  machine.verifyRegions(layout)
  echo "World dimensions: ", WorldWidth, "x", WorldHeight, "; sectors ",
    RegionColumns, "x", RegionRows, "; each ", RegionWidth, "x", RegionHeight

main()
