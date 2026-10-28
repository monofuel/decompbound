import
  std/[strutils, unittest],
  pixie,
  decompbound/[bestiary, enemy_sprites, ppu],
  ./bestiary/fixtures

suite "Bestiary data and portraits without a game ROM":
  test "core fields, large EXP, drop boundaries and header handling":
    var rom = authoredRom()
    let offset = EnemyBase + EnemyStride
    rom.putName(offset + 1, "Aurora Fixture")
    rom.putWord(offset + 0x21, 0xFEDC)
    rom.putWord(offset + 0x23, 0x1234)
    rom.putWord(offset + 0x25, 0x5678)
    rom.putWord(offset + 0x27, 0x1234)
    rom.putWord(offset + 0x29, 0x9876)
    rom[offset + 0x57] = 0
    rom[offset + 0x58] = 1
    rom.putName(0x155000 + 0x27, "Invented Token")
    let record = enemyRecord(rom, 1)
    check record.name == "Aurora Fixture"
    check record.hp == 0xFEDC and record.pp == 0x1234
    check record.exp == 0x12345678 and record.money == 0x9876
    check record.dropItemName == "Invented Token"
    check dropFreqLabel(0) == "1/128"
    check dropFreqLabel(6) == "1/2"
    check dropFreqLabel(7).toLowerAscii == "always"
    check dropFreqLabel(255).toLowerAscii == "always"
    check newBestiaryLibrary(newSeq[uint8](512) & rom).enemies[0].hp == 0xFEDC
    expect ValueError: discard enemyRecord(rom, 0)
    expect ValueError: discard enemyRecord(rom, 231)
    expect ValueError: discard enemyRecord([0'u8], 1)

  test "all six geometries preserve authored block colors and transparent index zero":
    for dim in 1..6:
      let
        rom = authoredRom(dim)
        sprite = decodeEnemySprite(rom, 1)
        width = Widths[dim - 1]
        height = Heights[dim - 1]
      check sprite.kind == StandardPortrait
      check sprite.widthPx == width and sprite.heightPx == height
      check sprite.image[0, 0].a == 0
      for tile in 1 ..< width * height div 64:
        let
          blockIndex = tile div 16
          blockColumns = width div 32
          x = (blockIndex mod blockColumns) * 32 + (tile mod 4) * 8
          y = (blockIndex div blockColumns) * 32 + ((tile mod 16) div 4) * 8
          expected = bgr555ToColor(uint16(tile mod 15 + 1))
        check sprite.image[x, y] == expected
      check sprite.image[width - 1, height - 1].a == 255

  test "portrait cache includes palette and keeps the requested enemy identity":
    let library = newBestiaryLibrary(authoredRom())
    let first = library.portrait(1)
    let second = library.portrait(2)
    check first.enemyId == 1 and second.enemyId == 2
    check first.spriteIndex == second.spriteIndex
    check first.paletteIndex != second.paletteIndex
    check first.image[32, 0] != second.image[32, 0]
    check library.portrait(1).enemyId == 1
    check library.portrait(1).image == first.image
    library.catalog.rom[GraphicsBase] = 0xFF
    expect ValueError: discard decodeEnemySprite(library.catalog.rom, 1)
    check library.portrait(1).image == first.image
    check library.portrait(2).image == second.image
    let absent = library.portrait(3)
    check absent.kind == NoStandardPortrait
    check absent.image == nil and absent.widthPx == 0

  test "item-name caches cannot leak across loaded ROMs":
    var first = authoredRom()
    var second = authoredRom()
    first[EnemyBase + EnemyStride + 0x58] = 1
    second[EnemyBase + EnemyStride + 0x58] = 1
    first.putName(0x155000 + 0x27, "First Token")
    second.putName(0x155000 + 0x27, "Second Token")
    check newBestiaryLibrary(first).enemies[0].dropItemName == "First Token"
    check newBestiaryLibrary(second).enemies[0].dropItemName == "Second Token"

  test "malformed sprite resources differ from a valid absent portrait":
    var rom = authoredRom()
    rom[SpriteTable + 4] = 7
    expect ValueError: discard decodeEnemySprite(rom, 1)
    rom = authoredRom()
    rom[SpriteTable + 2] = 0
    expect ValueError: discard decodeEnemySprite(rom, 1)
    rom = authoredRom()
    rom[EnemyBase + EnemyStride + 0x35] = 32
    expect ValueError: discard decodeEnemySprite(rom, 1)
    rom = authoredRom()
    rom.putWord(EnemyBase + EnemyStride + 0x1C, 111)
    expect ValueError: discard decodeEnemySprite(rom, 1)
    rom = authoredRom()
    rom.putWord(SpriteTable, 0xFFFF)
    rom[SpriteTable + 2] = 0xEF
    expect ValueError: discard decodeEnemySprite(rom, 1)
    expect ValueError: discard decodeEnemySprite([0'u8], 1)
