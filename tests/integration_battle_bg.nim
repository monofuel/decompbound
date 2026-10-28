import
  std/[os, strformat],
  pixie,
  decompbound/[battle_bg, battle_bg_catalog, gfx_lz],
  ./backgrounds/[palette_oracle, distortion_oracle]

proc main() =
  ## Sweep every ROM preset and layer, then compare renderer primitives with original CPU code.
  let
    path = if paramCount() > 0: paramStr(1) else: getEnv(RomEnvVar, DefaultRomPath)
    catalog = loadBackgroundCatalog(path)
    image = newImage(ScreenW, ScreenH)
  var
    workspace: BackgroundWorkspace
    mapped, variants = 0
  for enemy in catalog.enemies:
    if enemy.variants.len > 0: inc mapped
    variants += enemy.variants.len
  doAssert catalog.enemies.len == 230 and mapped == 174 and variants == 454
  doAssert catalog.enemies[catalog.enemyIndex(34)].variants.len == 0
  doAssert catalog.enemies[catalog.enemyIndex(83)].variants.len == 0
  doAssert bgCount(catalog.rom) == BattleGroupCount
  for index in 0 ..< GfxCount:
    for table in [GfxPtrTableFile, ArrPtrTableFile]:
      let
        pointer = table + index * 4
        address = (catalog.rom[pointer].int or (catalog.rom[pointer + 1].int shl 8) or
          (catalog.rom[pointer + 2].int shl 16)) and 0x3FFFFF
        decoded = decodeWithConsumed(catalog.rom[address ..< min(address + 65536, catalog.rom.len)])
      doAssert decoded.clean and decoded.consumed > 0
      if table == ArrPtrTableFile: doAssert decoded.data.len == 2048
      doAssert decode(encode(decoded.data)) == decoded.data
  for id in 1 ..< BackgroundLayerCount:
    let layer = decodeLayer(catalog.rom, id)
    doAssert layer.arrangement.len == 1024
    for entry in layer.arrangement:
      doAssert (entry.int and 1023) * layer.bpp * 8 < layer.chr.len
      doAssert (entry.int and 0x1C00) == 0
    let background = BattleBg(layers: @[layer])
    for frame in [0, 1, 15, 30, 180, 1_000_000_001]:
      renderInto(background, frame, image, workspace)
  for group in 0 ..< BattleGroupCount:
    let background = loadBattleBg(catalog.rom, group)
    for frame in [0, 15, 30]: renderInto(background, frame, image, workspace)
    let first = renderFrame(background, 7, 32, 32)
    discard renderFrame(background, 1500, 32, 32)
    doAssert first.data == renderFrame(background, 7, 32, 32).data
  verifyPalette(catalog.rom)
  verifyDistortion(catalog.rom)
  echo &"Backgrounds: {mapped}/230 enemies mapped; {variants} variants, 484 groups and 326 layers swept; original CPU palette/scroll/distortion oracles passed."

when isMainModule: main()
