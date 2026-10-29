## Original EarthBound UI font loader and 1bpp glyph painter.
##
## Descriptors at SNES `$C3F054` / file `0x03F054`, stride 12, five records
## (C44E61 / C44751 / C44FF3). Each record: +0 width farptr, +4 bitmap farptr,
## +8 glyph stride, +10 height. Glyph index `(storage - $50) & $7F` (C44EEC,
## C44751). Printable ASCII storage is `ord + $30` (`text_decode.nim`).
## Bitmaps are 1bpp column-major strips `height` bytes wide (one 8px column);
## stride/height columns per glyph. Source bit 0 is ink, MSB is the left pixel.
## C44B3A writes that plane into a 2bpp window buffer as color 1 against a
## `$FF`-filled plane 0 (color 3 empty). This painter exposes empty=0 ink=1.

import
  std/strformat,
  pixie,
  ./memmap

type
  EbUiFont* = object
    ## One original font record plus its decoded 1bpp metrics.
    fontId*: int
    height*: int
    stride*: int
    cellWidth*: int
    extraSpacing*: int
    widths*: seq[uint8]
    bitmap*: seq[uint8]

const
  FontDescriptorSnes* = 0xC3F054'u32
  FontDescriptorFile* = 0x03F054
  FontDescriptorStride* = 12
  FontDescriptorCount* = 5
  FontWidthPtrOff* = 0
  FontBitmapPtrOff* = 4
  FontGlyphStrideOff* = 8
  FontGlyphHeightOff* = 10
  FontGlyphCount* = 96
  GlyphIndexBias* = 0x50
  GlyphIndexMask* = 0x7F
  EbStorageBias* = 0x30
  EbUiEmptyIndex* = 0
  EbUiInkIndex* = 1
  TextRendererSnes* = 0xC44E61'u32
  WidthWalkerSnes* = 0xC44751'u32
  StringWidthSnes* = 0xC44FF3'u32
  GlyphBlitSnes* = 0xC44B3A'u32
  TrackingWram* = 0x5E6D
  BitsPerColumn* = 8

proc readWord(rom: openArray[uint8], offset: int): int =
  ## Read a little-endian ROM word.
  rom[offset].int or (rom[offset + 1].int shl 8)

proc readFarPtr(rom: openArray[uint8], offset: int): uint32 =
  ## Read a 24-bit far pointer stored in four descriptor bytes (bank at +2).
  rom[offset].uint32 or (rom[offset + 1].uint32 shl 8) or
    (rom[offset + 2].uint32 shl 16)

proc romSlice(rom: openArray[uint8], snesAddr: uint32, length: int): seq[uint8] =
  ## Copy `length` bytes from a SNES far pointer that must land in the ROM.
  let fileOff = snesToFile(snesAddr)
  if fileOff < 0 or length < 0 or fileOff + length > rom.len:
    raise newException(ValueError,
      &"font pointer ${snesAddr:06X} length {length} is outside the ROM")
  result = newSeq[uint8](length)
  for i in 0 ..< length:
    result[i] = rom[fileOff + i]

proc ebGlyphIndex*(storage: uint8): int =
  ## Original glyph index: `(storageByte - $50) & $7F` at C44EEC and C44751.
  (storage.int - GlyphIndexBias) and GlyphIndexMask

proc loadEbUiFont*(rom: openArray[uint8], fontId = 0): EbUiFont =
  ## Load font `fontId` (0..4) from the user's ROM using the `$C3F054` table.
  if fontId < 0 or fontId >= FontDescriptorCount:
    raise newException(ValueError, &"fontId {fontId} is outside 0 ..< {FontDescriptorCount}")
  if rom.len < FontDescriptorFile + FontDescriptorCount * FontDescriptorStride:
    raise newException(ValueError, "ROM is too short for EarthBound font descriptors")
  let
    desc = FontDescriptorFile + fontId * FontDescriptorStride
    widthPtr = readFarPtr(rom, desc + FontWidthPtrOff)
    bitmapPtr = readFarPtr(rom, desc + FontBitmapPtrOff)
    stride = readWord(rom, desc + FontGlyphStrideOff)
    height = readWord(rom, desc + FontGlyphHeightOff)
  if stride <= 0 or height <= 0 or stride mod height != 0:
    raise newException(ValueError,
      &"font {fontId} stride {stride} height {height} is not column-major 1bpp")
  let cellWidth = BitsPerColumn * (stride div height)
  result = EbUiFont(
    fontId: fontId,
    height: height,
    stride: stride,
    cellWidth: cellWidth,
    extraSpacing: 0,
    widths: romSlice(rom, widthPtr, FontGlyphCount),
    bitmap: romSlice(rom, bitmapPtr, FontGlyphCount * stride))

proc glyphWidth*(font: EbUiFont, index: int): int =
  ## Advance in pixels from the original width table, plus `$5E6D` tracking.
  if index < 0 or index >= font.widths.len:
    raise newException(ValueError, &"glyph index {index} is outside the width table")
  font.widths[index].int + font.extraSpacing

proc glyphPixel*(font: EbUiFont, index, x, y: int): int =
  ## Return 0 (empty) or 1 (ink) for one pixel of glyph `index`.
  if index < 0 or index >= FontGlyphCount:
    raise newException(ValueError, &"glyph index {index} is outside 0 ..< {FontGlyphCount}")
  if x < 0 or y < 0 or x >= font.cellWidth or y >= font.height:
    return EbUiEmptyIndex
  let
    column = x div BitsPerColumn
    bit = x mod BitsPerColumn
    rowByte = font.bitmap[index * font.stride + column * font.height + y]
  if ((rowByte shr (7 - bit)) and 1) == 0:
    result = EbUiInkIndex
  else:
    result = EbUiEmptyIndex

proc ebTextWidth*(font: EbUiFont, encoded: openArray[uint8]): int =
  ## Sum original advances for printable encoded bytes, stopping at NUL.
  for storage in encoded:
    if storage == 0:
      break
    let index = ebGlyphIndex(storage)
    if index < FontGlyphCount:
      result += font.glyphWidth(index)

proc drawEbText*(image: Image, font: EbUiFont, encoded: openArray[uint8],
    x, y: int, palette: array[4, ColorRGBA], maxWidth = 0) =
  ## Draw EB-encoded bytes with original 1bpp glyphs. `maxWidth` 0 is unlimited.
  var cursor = x
  let limit = if maxWidth > 0: x + maxWidth else: high(int)
  for storage in encoded:
    if storage == 0:
      break
    let
      index = ebGlyphIndex(storage)
    if index >= FontGlyphCount:
      continue
    let advance = font.glyphWidth(index)
    if cursor + advance > limit:
      break
    let drawnWidth = font.widths[index].int
    for row in 0 ..< font.height:
      let py = y + row
      if py < 0 or py >= image.height:
        continue
      for col in 0 ..< drawnWidth:
        let px = cursor + col
        if px < 0 or px >= image.width:
          continue
        let color = palette[font.glyphPixel(index, col, row)]
        if color.a == 0:
          continue
        image[px, py] = color
    cursor += advance
