const
  DescriptorTable = 0x03F054
  WidthTable = 0x048000
  Bitmap = 0x048100
  GlyphCount = 96
  FontCount = 5
  CommonGraphics = 0x200000
  OverlayGraphics = 0x200754
  FlavorTable = 0x201FB9

proc word(data: var seq[uint8], offset, value: int) =
  ## Store an authored little-endian descriptor word.
  data[offset] = uint8(value and 255)
  data[offset + 1] = uint8(value shr 8)

proc fillStream(data: var seq[uint8], offset, length: int) =
  ## Encode an authored all-one graphics buffer using long RLE commands.
  var
    cursor = offset
    remaining = length
  while remaining > 0:
    let count = min(remaining, 1024)
    data[cursor] = uint8(0xE4 or ((count - 1) shr 8))
    data[cursor + 1] = uint8((count - 1) and 255)
    data[cursor + 2] = 255
    cursor += 3
    remaining -= count
  data[cursor] = 255

proc addSyntheticUi*(rom: var seq[uint8]) =
  ## Give an authored ABI-test ROM valid empty fonts and flat UI tiles, without game assets.
  for id in 0 ..< FontCount:
    let
      entry = DescriptorTable + id * 12
      height = if id == 3: 8 else: 16
    rom.word(entry, WidthTable and 0xFFFF)
    rom[entry + 2] = 0xC4
    rom.word(entry + 4, Bitmap and 0xFFFF)
    rom[entry + 6] = 0xC4
    rom.word(entry + 8, height)
    rom.word(entry + 10, height)
  for index in 0 ..< GlyphCount: rom[WidthTable + index] = 6
  for index in 0 ..< GlyphCount * 16: rom[Bitmap + index] = 255
  rom.fillStream(CommonGraphics, 0x1A00)
  rom.fillStream(OverlayGraphics, 0x70)
  for flavor in 0 ..< FontCount:
    rom.word(FlavorTable + flavor * 3, flavor * 64)
    rom[FlavorTable + flavor * 3 + 2] = uint8(if flavor == 0: 1 else: 8)
