## Enemy battle-sprite decode: enemy id → 4bpp tiles + BGR555 palette + RGBA image.
##
## The enemy configuration record does **not** hold far graphics pointers.
## `+0x1C` is a 1-based u16 index into the 110 × 5-byte table at SNES `$CE62EE`
## / file `0x0E62EE`; `+0x35` is a u8 row index into the 32-byte BGR555 palette
## rows at `$CE6514` / file `0x0E6514`. Direct-pointer claims in older graphics
## notes are wrong.
##
## Original consumers (native 16-bit A/X, bank `$C2`):
## - Sprite index: `$C2F0E9` `LDY #$005E` / `JSL $C08FF7` / `ADC #$001C` /
##   `LDA $D59589,X`, then `$C2F007` `DEC A` / `ASL ASL ADC` (*5) /
##   `LDA $CE62EE,X` after four `INX` (dimension byte). Twin site `$C2EF3F`.
## - Palette: `$C2EF59` `ADC #$0035` / `LDA [$06]` / `AND #$00FF` / five `ASL`
##   (*32) / `LDA #$6514` / `LDA #$00CE` / `LDX #$0020` / `JSL $C08ED2`.
## - Gfx pointer: `$C2EE0B` `LDA #$62EE` / `LDA #$00CE`, index already 0-based
##   in `$28`, *5, `LDA [$0A]` + `LDA [$0A],Y` with `Y=2`, `JSL $C41A9E`
##   (`gfx_lz` at `$C41AC1`) staging toward `$7F8000`.
## - Size: `$C2EFFD` width and `$C2F04E` height CMP-chains, dim 1..6 only.
## - 32×32 OBJ assembly: `$C2EBDF` `LDA $CE62EE,X` dim dispatch; dim 6 at
##   `$C2ECAE` `LDY #$0004` / `STA $02` / `STA $22` (4×4 of 32×32 OBJ = 128×128).
##
## `BattlePaletteCount` is the supported referenced-row window 0..31 on gold,
## not a proof that the file contains only 32 rows. The 1..230 enemy window is
## a named-record bound, not an in-engine `CMP` clamp.

import
  std/strformat,
  pixie,
  ./[gfx_lz, ppu]

type
  PortraitKind* = enum
    ## How an enemy row's battle portrait should be treated.
    StandardPortrait
    NoStandardPortrait

  EnemySprite* = object
    ## One decoded enemy battle sprite, or an explicit no-standard-sprite row.
    kind*: PortraitKind
    enemyId*, spriteIndex*, paletteIndex*, dim*, widthPx*, heightPx*: int
    tiles*: seq[uint8]
    palette*: array[16, uint16]
    image*: Image

const
  EnemyTableFileBase = 0x159589
  EnemyRecordSize = 0x5E
  ## Battle sprite index, u16 LE. Consumer `$C2F0F1` `ADC #$001C`.
  EnemyBattleSpriteOff = 0x1C
  ## Battle palette row, u8. Consumer `$C2EF59` `ADC #$0035`.
  EnemyBattlePaletteOff = 0x35
  EnemyMinId = 1
  EnemyMaxId = 230
  ## Pointer table SNES `$CE62EE`. Indexed `(idx-1)*5` after `DEC A` at `$C2F007`.
  BattleSpriteTableFileBase* = 0x0E62EE
  BattleSpriteEntrySize = 5
  BattleSpriteCount* = 110
  ## Palette rows SNES `$CE6514`. Far base `$C2EF74` / `$C2EF79`.
  BattlePaletteTableFileBase* = 0x0E6514
  BattlePaletteSize = 32
  ## Supported referenced rows 0..31 (gold enemy `+0x35` inventory), not a
  ## blanket claim about bytes after the last referenced row.
  BattlePaletteCount* = 32
  BattlePaletteColors = 16
  GfxDecodeWindow = 0x10000
  BytesPerTile4bpp = 32
  FileOffsetMask = 0x3FFFFF
  ## Width in 8×8 tiles. `$C2F01A` CMP 1/3 → 4, 2/4 → 8, 5/6 → 16.
  DimWidthTiles*: array[1..6, int] = [4, 8, 4, 8, 16, 16]
  ## Height in 8×8 tiles. `$C2F06B` CMP 1/2 → 4, 3/4/5 → 8, 6 → 16.
  DimHeightTiles*: array[1..6, int] = [4, 4, 8, 8, 8, 16]
  ## 32×32 OBJ block is 4×4 tiles. Dim 6 consumer `$C2ECAE` uses count 4.
  BlockTiles = 4

proc readU16(rom: openArray[uint8], off: int): int =
  ## Little-endian u16 at `off`, or `ValueError` if it would run past the ROM.
  if off < 0 or off + 1 >= rom.len:
    raise newException(ValueError, &"u16 read at 0x{off:06X} is outside the ROM")
  result = rom[off].int or (rom[off + 1].int shl 8)

proc requireEnemyId(enemyId: int) =
  ## Reject ids outside the named-record window `1..230`.
  if enemyId < EnemyMinId or enemyId > EnemyMaxId:
    raise newException(
      ValueError,
      &"enemy id {enemyId} is outside {EnemyMinId}..{EnemyMaxId}"
    )

proc enemyRecordBase(enemyId: int): int =
  ## File offset of enemy `enemyId`'s configuration record.
  EnemyTableFileBase + enemyId * EnemyRecordSize

proc requireRecord(rom: openArray[uint8], enemyId: int): int =
  ## Record base for `enemyId`, or `ValueError` if the 0x5E row is truncated.
  requireEnemyId(enemyId)
  result = enemyRecordBase(enemyId)
  if result < 0 or result + EnemyRecordSize > rom.len:
    raise newException(
      ValueError,
      &"enemy {enemyId} record at 0x{result:06X} overruns the ROM"
    )

proc tilePixel4bpp(tiles: openArray[uint8], tile, x, y: int): int =
  ## Palette index of pixel `(x, y)` inside 8×8 tile `tile` of planar 4bpp CHR.
  let base = tile * BytesPerTile4bpp
  if base + BytesPerTile4bpp > tiles.len:
    raise newException(ValueError, &"4bpp tile {tile} overruns decoded CHR")
  let lo01 = tiles[base + y * 2]
  let hi01 = tiles[base + y * 2 + 1]
  let lo23 = tiles[base + 16 + y * 2]
  let hi23 = tiles[base + 16 + y * 2 + 1]
  let bit = 7 - x
  result = ((lo01.int shr bit) and 1) or
    (((hi01.int shr bit) and 1) shl 1) or
    (((lo23.int shr bit) and 1) shl 2) or
    (((hi23.int shr bit) and 1) shl 3)

proc decodedTileOrigin*(dim, tileIndex: int): tuple[x, y: int] =
  ## Pixel origin of decoded-blob tile `tileIndex` inside a dimension-`dim` sprite.
  ## Blob order is 32×32 blocks row-major across the sprite, then 4×4 tiles
  ## row-major inside each block, matching `$C2EBDF` 32×32 OBJ assembly.
  if dim < DimWidthTiles.low or dim > DimWidthTiles.high:
    raise newException(ValueError, &"sprite dimension {dim} is outside 1..6")
  if tileIndex < 0:
    raise newException(ValueError, &"tile index {tileIndex} is negative")
  let blockCols = DimWidthTiles[dim] div BlockTiles
  let b = tileIndex div (BlockTiles * BlockTiles)
  let inner = tileIndex mod (BlockTiles * BlockTiles)
  let bx = b mod blockCols
  let by = b div blockCols
  result.x = (bx * BlockTiles + inner mod BlockTiles) * 8
  result.y = (by * BlockTiles + inner div BlockTiles) * 8

proc battleSpriteEntry*(rom: openArray[uint8], spriteIndex: int):
    tuple[gfxFileOff: int, dim: int] =
  ## Read 0-based table entry `spriteIndex`: HiROM file offset plus dimension.
  if spriteIndex < 0 or spriteIndex >= BattleSpriteCount:
    raise newException(
      ValueError,
      &"battle sprite index {spriteIndex} is outside 0..{BattleSpriteCount - 1}"
    )
  let e = BattleSpriteTableFileBase + spriteIndex * BattleSpriteEntrySize
  if e < 0 or e + BattleSpriteEntrySize > rom.len:
    raise newException(
      ValueError,
      &"battle sprite table entry {spriteIndex} at 0x{e:06X} overruns the ROM"
    )
  let pad = rom[e + 3].int
  if pad != 0:
    raise newException(
      ValueError,
      &"battle sprite {spriteIndex} pointer high byte is ${pad:02X}, expected $00"
    )
  let snes =
    rom[e].int or (rom[e + 1].int shl 8) or (rom[e + 2].int shl 16)
  let dim = rom[e + 4].int
  if dim < DimWidthTiles.low or dim > DimWidthTiles.high:
    raise newException(
      ValueError,
      &"battle sprite {spriteIndex} dimension {dim} is outside 1..6"
    )
  let off = snes and FileOffsetMask
  if snes == 0 or off < 0 or off >= rom.len:
    raise newException(
      ValueError,
      &"battle sprite {spriteIndex} graphics pointer 0x{snes:06X} is outside the ROM"
    )
  result = (off, dim)

proc battlePalette*(rom: openArray[uint8], paletteIndex: int): array[16, uint16] =
  ## 16 BGR555 colors from supported palette row `paletteIndex`.
  if paletteIndex < 0 or paletteIndex >= BattlePaletteCount:
    raise newException(
      ValueError,
      &"battle palette index {paletteIndex} is outside 0..{BattlePaletteCount - 1}"
    )
  let base = BattlePaletteTableFileBase + paletteIndex * BattlePaletteSize
  if base < 0 or base + BattlePaletteSize > rom.len:
    raise newException(
      ValueError,
      &"battle palette row {paletteIndex} at 0x{base:06X} overruns the ROM"
    )
  for i in 0 ..< BattlePaletteColors:
    result[i] = uint16(readU16(rom, base + i * 2))

proc decodeBattleSpriteGfx*(rom: openArray[uint8], spriteIndex: int): seq[uint8] =
  ## Decompress the 4bpp CHR for 0-based table entry `spriteIndex`.
  let (off, dim) = battleSpriteEntry(rom, spriteIndex)
  let hi = min(off + GfxDecodeWindow, rom.len)
  if hi <= off:
    raise newException(
      ValueError,
      &"battle sprite {spriteIndex} graphics stream at 0x{off:06X} is empty"
    )
  let decoded = decodeWithConsumed(rom.toOpenArray(off, hi - 1))
  if not decoded.clean:
    raise newException(
      ValueError,
      &"battle sprite {spriteIndex} graphics stream at 0x{off:06X} is truncated"
    )
  let expected = DimWidthTiles[dim] * DimHeightTiles[dim] * BytesPerTile4bpp
  if decoded.data.len != expected:
    raise newException(
      ValueError,
      &"battle sprite {spriteIndex} decoded {decoded.data.len} bytes, dimension {dim} expects {expected}"
    )
  result = decoded.data

proc assembleImage(sprite: EnemySprite): Image =
  ## Compose `sprite.tiles` into a pixie image using 32×32 block tile order.
  result = newImage(sprite.widthPx, sprite.heightPx)
  let tileCount = sprite.tiles.len div BytesPerTile4bpp
  for tile in 0 ..< tileCount:
    let origin = decodedTileOrigin(sprite.dim, tile)
    for y in 0 ..< 8:
      for x in 0 ..< 8:
        let idx = tilePixel4bpp(sprite.tiles, tile, x, y)
        if idx == 0:
          result[origin.x + x, origin.y + y] = ColorRGBA(r: 0, g: 0, b: 0, a: 0)
        else:
          result[origin.x + x, origin.y + y] = bgr555ToColor(sprite.palette[idx])

proc emptyPortrait(enemyId, paletteIndex: int): EnemySprite =
  ## Explicit absence of a standard battle sprite for `enemyId`.
  result.kind = NoStandardPortrait
  result.enemyId = enemyId
  result.paletteIndex = paletteIndex
  result.image = nil

proc portraitKey*(rom: openArray[uint8], enemyId: int): tuple[spriteIndex, paletteIndex: int] =
  ## Resolve and validate a portrait cache key without decompressing graphics.
  let base = requireRecord(rom, enemyId)
  let spriteId = readU16(rom, base + EnemyBattleSpriteOff)
  result.paletteIndex = rom[base + EnemyBattlePaletteOff].int
  result.spriteIndex = spriteId - 1
  if spriteId > BattleSpriteCount:
    raise newException(ValueError, "Enemy references an unsupported battle sprite.")
  if spriteId > 0 and result.paletteIndex >= BattlePaletteCount:
    raise newException(ValueError, "Enemy references an unsupported battle palette.")

proc decodeEnemySprite*(rom: openArray[uint8], enemyId: int): EnemySprite =
  ## Decode enemy `enemyId`'s standard battle sprite from `rom`.
  ## Sprite index 0 is a legitimate absence (`NoStandardPortrait`, `image == nil`).
  ## Malformed tables, unsupported ids/pointers/palettes/dimensions, and
  ## decompression failures raise `ValueError`.
  let base = requireRecord(rom, enemyId)
  let spriteId = readU16(rom, base + EnemyBattleSpriteOff)
  let paletteIndex = rom[base + EnemyBattlePaletteOff].int
  if spriteId == 0:
    return emptyPortrait(enemyId, paletteIndex)
  if spriteId < 1 or spriteId > BattleSpriteCount:
    raise newException(
      ValueError,
      &"enemy {enemyId} battle sprite index {spriteId} is outside 1..{BattleSpriteCount}"
    )
  if paletteIndex < 0 or paletteIndex >= BattlePaletteCount:
    raise newException(
      ValueError,
      &"enemy {enemyId} battle palette index {paletteIndex} is outside 0..{BattlePaletteCount - 1}"
    )
  result.kind = StandardPortrait
  result.enemyId = enemyId
  result.spriteIndex = spriteId - 1
  result.paletteIndex = paletteIndex
  let entry = battleSpriteEntry(rom, result.spriteIndex)
  result.dim = entry.dim
  result.tiles = decodeBattleSpriteGfx(rom, result.spriteIndex)
  result.palette = battlePalette(rom, paletteIndex)
  result.widthPx = DimWidthTiles[result.dim] * 8
  result.heightPx = DimHeightTiles[result.dim] * 8
  result.image = assembleImage(result)
