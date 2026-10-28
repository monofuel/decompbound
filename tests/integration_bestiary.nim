import
  std/[os, sets, strformat, tables],
  pixie,
  decompbound/[bestiary, bestiary_browser, bestiary_scene, enemy_sprites, music_player],
  ./bestiary/pixel_oracle,
  ./bestiary/original_oracle

proc word(rom: openArray[uint8], offset: int): int =
  ## Independently read a little-endian table word for catalog range checks.
  rom[offset].int or (rom[offset + 1].int shl 8)

proc main() =
  ## Sweep every supported record and asset, then execute original game-code oracles.
  let
    path = if paramCount() > 0: paramStr(1) else: getEnv("DECOMPBOUND_ROM", "bin/Earthbound (U) [!].smc")
    library = loadBestiaryLibrary(path)
    browser = newBestiaryBrowser(library)
    scene = newBestiaryScene()
    rom = library.catalog.rom
  doAssert library.enemies.len == 230
  var
    standard, absent = 0
    assets, palettes, dimensions: HashSet[int]
    cached: Table[(int, int), Image]
  for index, enemy in library.enemies:
    let base = 0x159589 + enemy.id * 0x5E
    doAssert enemy.id == index + 1
    doAssert enemy.name == library.catalog.enemies[index].name
    doAssert enemy.name.len > 0
    doAssert enemy.hp == word(rom, base + 0x21)
    doAssert enemy.pp == word(rom, base + 0x23)
    doAssert enemy.exp == (word(rom, base + 0x25) or (word(rom, base + 0x27) shl 16))
    doAssert enemy.money == word(rom, base + 0x29)
    doAssert enemy.musicId == rom[base + 0x37].int
    let portrait = library.portrait(enemy.id)
    doAssert portrait.enemyId == enemy.id
    if portrait.kind == NoStandardPortrait:
      inc absent
      doAssert word(rom, base + 0x1C) == 0 and portrait.image == nil
    else:
      inc standard
      doAssert portrait.spriteIndex == word(rom, base + 0x1C) - 1
      doAssert portrait.paletteIndex == rom[base + 0x35].int
      doAssert portrait.image.width == portrait.widthPx and portrait.image.height == portrait.heightPx
      doAssert portrait.tiles.len == portrait.widthPx * portrait.heightPx div 2
      for color in portrait.image.data: doAssert color.a in [0'u8, 255'u8]
      assets.incl portrait.spriteIndex
      palettes.incl portrait.paletteIndex
      dimensions.incl portrait.dim
      let key = (portrait.spriteIndex, portrait.paletteIndex)
      if key in cached: doAssert cached[key] == portrait.image
      else: cached[key] = portrait.image
    browser.selectEnemy(index)
    for frame in [0, 30]:
      browser.frame = frame
      let image = scene.render(browser)
      doAssert image.width == 256 and image.height == 224
    if enemy.musicId == 0 or enemy.musicId notin library.music.trackIds:
      doAssert browser.playableSong == 0
    else: doAssert browser.playableSong == enemy.musicId
  doAssert standard == 213 and absent == 17
  doAssert assets.len == 110 and palettes.len == 32 and dimensions.len == 6
  verifyEnemyGraphics(rom)
  verifyPortraitPixels(library)
  echo &"Bestiary: 230 records, {standard} portraits, {absent} explicit absences, 110 assets, 32 palettes and all six dimensions passed."

when isMainModule: main()
