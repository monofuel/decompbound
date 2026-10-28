import
  decompbound/[common, gfx_lz]

const
  EnemyBase* = 0x159589
  EnemyStride* = 0x5E
  SpriteTable* = 0x0E62EE
  PaletteTable* = 0x0E6514
  GraphicsBase* = 0x200000
  Widths* = [32, 64, 32, 64, 128, 128]
  Heights* = [32, 32, 64, 64, 64, 128]

proc putWord*(bytes: var seq[uint8], offset, value: int) =
  ## Write an authored little-endian fixture word.
  bytes[offset] = uint8(value and 255)
  bytes[offset + 1] = uint8((value shr 8) and 255)

proc putName*(bytes: var seq[uint8], offset: int, name: string) =
  ## Encode an original test label using the ROM text representation.
  for i, c in name: bytes[offset + i] = uint8(c.ord + 0x30)
  bytes[offset + name.len] = 0

proc authoredChr*(dim: int): seq[uint8] =
  ## Give every tile a synthetic planar color identifying its block position.
  let count = Widths[dim - 1] * Heights[dim - 1] div 64
  result = newSeq[uint8](count * 32)
  for tile in 0 ..< count:
    let color = tile mod 15 + 1
    for plane in 0 ..< 4:
      if (color and (1 shl plane)) != 0:
        for row in 0 ..< 8:
          result[tile * 32 + (plane div 2) * 16 + row * 2 + plane mod 2] = 255
  for row in 0 ..< 8:
    for plane in 0 ..< 4: result[(plane div 2) * 16 + row * 2 + plane mod 2] = 0

proc authoredRom*(dim = 4): seq[uint8] =
  ## Create a wholly synthetic ROM body with two shared sprites and distinct palettes.
  result = newSeq[uint8](EarthboundRomSize)
  for group in 0 ..< 484:
    result.putWord(0x10C60D + group * 8, 0xD52D)
    result[0x10C60D + group * 8 + 2] = 0xD0
  result[0x10D52D] = 255
  for index in 0x04F70A ..< 0x04F947: result[index] = 255
  for id in 1..230: result.putName(EnemyBase + id * EnemyStride + 1, "Fixture " & $id)
  result.putWord(SpriteTable, GraphicsBase and 65535)
  result[SpriteTable + 2] = 0xE0
  result[SpriteTable + 4] = uint8(dim)
  for id in [1, 2]: result.putWord(EnemyBase + id * EnemyStride + 0x1C, 1)
  result[EnemyBase + 2 * EnemyStride + 0x35] = 1
  for color in 0 ..< 16:
    result.putWord(PaletteTable + color * 2, color)
    result.putWord(PaletteTable + 32 + color * 2, color shl 5)
  let compressed = encode(authoredChr(dim))
  for index, value in compressed: result[GraphicsBase + index] = value
