import
  std/unittest,
  decompbound/[common, world_map_assets, world_map_story]

proc putWord(rom: var seq[uint8], offset, value: int) =
  ## Write authored little-endian palette fields into a synthetic ROM.
  rom[offset] = uint8(value and 255)
  rom[offset + 1] = uint8((value shr 8) and 255)

suite "Independent world story state":
  test "one-based flags are owned values and boundaries cannot corrupt neighbors":
    var first: WorldMapStoryState
    for id in [1, 8, 9, 0x011F, 0x01A6, LastWorldMapStoryFlag]:
      check not first.flagEnabled(id)
      first.setStoryFlag(id, true)
      check first.flagEnabled(id)
    var second = first
    second.setStoryFlag(1, false)
    second.setStoryFlag(2, true)
    check first.flagEnabled(1) and not first.flagEnabled(2)
    check not second.flagEnabled(1) and second.flagEnabled(2)
    check first.enabledFlags() == @[1, 8, 9, 0x011F, 0x01A6, LastWorldMapStoryFlag]
    expect ValueError: first.setStoryFlag(0, true)
    expect ValueError: discard first.flagEnabled(0x8000)

  test "original exact-8000 palette condition redirects with its wrapped flag clear":
    var rom = newSeq[uint8](EarthboundRomSize)
    rom.putWord(WorldPalettePointersFile, 0x1000)
    rom[WorldPalettePointersFile + 2] = 0xE0
    rom.putWord(0x201000, 0x8000)
    rom.putWord(0x201020, 0x2000)
    rom.putWord(0x201002, 0x1234)
    rom.putWord(0x202002, 0x4567)
    let selected = newWorldMapAssets(rom).palette(0, 0)
    check selected.sourceFile == 0x201000
    check selected.resolvedFile == 0x202000
    check selected.colors[33] == 0x4567
