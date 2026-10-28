import
  std/[strformat, tables],
  pixie,
  decompbound/[bestiary, enemy_sprites, ppu],
  ./original_oracle

proc tileColor(bytes: seq[uint8], tile, x, y: int): int =
  ## Independently sample the original painter's shuffled 4bpp tile atlas.
  let offset = tile * 32 + y * 2
  for plane in 0 ..< 4:
    let address = offset + (plane div 2) * 16 + plane mod 2
    doAssert address >= 0 and address < bytes.len
    if (bytes[address].int and (128 shr x)) != 0: result = result or (1 shl plane)

proc verifyPortraitPixels*(library: BestiaryLibrary) =
  ## Reconstruct portraits from original OAM and actual original tile-shuffle output.
  var cache: Table[int, OriginalOamList]
  var checked = 0
  for enemy in library.enemies:
    let portrait = library.portrait(enemy.id)
    if portrait.kind == NoStandardPortrait: continue
    if portrait.spriteIndex notin cache:
      cache[portrait.spriteIndex] = originalComposeOam(library.catalog.rom,
        portrait.spriteIndex, 1, finishUpload = true)
    let original = cache[portrait.spriteIndex]
    var left, top = high(int)
    for i in 0 ..< original.liveCount:
      left = min(left, cast[int8](original.entries[i].x).int)
      top = min(top, cast[int8](original.entries[i].y).int)
    let expected = newImage(portrait.widthPx, portrait.heightPx)
    for i in 0 ..< original.liveCount:
      let entry = original.entries[i]
      doAssert ((entry.attr.int shr 1) and 7) == 1
      let
        originX = cast[int8](entry.x).int - left
        originY = cast[int8](entry.y).int - top
        baseTile = entry.tile.int or ((entry.attr.int and 1) shl 8)
      for y in 0 ..< 32:
        for x in 0 ..< 32:
          let
            sourceX = if (entry.attr and 0x40) != 0: 31 - x else: x
            sourceY = if (entry.attr and 0x80) != 0: 31 - y else: y
            tile = (baseTile and 0x100) or ((baseTile + sourceX div 8 + (sourceY div 8) * 16) and 255)
            index = tileColor(original.uploadedTiles, tile, sourceX mod 8, sourceY mod 8)
          doAssert originX + x < expected.width and originY + y < expected.height,
            &"enemy={enemy.id} sprite={portrait.spriteIndex} dim={portrait.dim} block={i} OAM={entry} origin={originX},{originY} min={left},{top} size={expected.width},{expected.height}"
          if index != 0:
            let
              offset = 0x0E6514 + portrait.paletteIndex * 32 + index * 2
              color = library.catalog.rom[offset].uint16 or (library.catalog.rom[offset + 1].uint16 shl 8)
            expected[originX + x, originY + y] = bgr555ToColor(color)
    doAssert portrait.image.data == expected.data,
      &"Enemy {enemy.id} dim {portrait.dim} differs from original OAM/tile-shuffle pixels."
    inc checked
  doAssert checked == 213 and cache.len == 110
  echo "Portrait pixels: 213 enemy/palette combinations match original OAM and tile shuffle across all 110 assets."
