import
  pixie,
  decompbound/eb_ui_font

const
  Widths = 0x040000
  Bitmap = 0x040100
  Height = 8

proc putWord(data: var seq[uint8], offset, value: int) =
  ## Store one word in an authored descriptor.
  data[offset] = uint8(value and 255)
  data[offset + 1] = uint8(value shr 8)

proc syntheticRom(): seq[uint8] =
  ## Build a tiny authored font at the public descriptor layout, without game data.
  result = newSeq[uint8](Bitmap + FontGlyphCount * Height)
  result.putWord(FontDescriptorFile + FontWidthPtrOff, 0)
  result[FontDescriptorFile + FontWidthPtrOff + 2] = 0xC4
  result.putWord(FontDescriptorFile + FontBitmapPtrOff, 0x0100)
  result[FontDescriptorFile + FontBitmapPtrOff + 2] = 0xC4
  result.putWord(FontDescriptorFile + FontGlyphStrideOff, Height)
  result.putWord(FontDescriptorFile + FontGlyphHeightOff, Height)
  for index in 0 ..< FontGlyphCount:
    result[Widths + index] = 3
  for index in Bitmap ..< result.len: result[index] = 255
  let glyph = ebGlyphIndex(0x71)
  result[Bitmap + glyph * Height + 1] = 0xBF
  result[Bitmap + glyph * Height + 2] = 0xDF

proc main() =
  ## Check descriptor validation, authored glyph orientation, clipping and spacing.
  let
    font = loadEbUiFont(syntheticRom())
    glyph = ebGlyphIndex(0x71)
    image = newImage(8, 8)
    ink = ColorRGBA(r: 255, a: 255)
    palette: array[4, ColorRGBA] = [ColorRGBA(), ink, ColorRGBA(), ColorRGBA()]
  doAssert font.height == Height and font.cellWidth == 8
  doAssert font.glyphPixel(glyph, 1, 1) == 1
  doAssert font.glyphPixel(glyph, 2, 2) == 1
  doAssert font.glyphPixel(glyph, 0, 1) == 0
  doAssert font.ebTextWidth([0x71'u8, 0x71, 0, 0x71]) == 6
  image.drawEbText(font, [0x71'u8, 0x71], -1, 0, palette)
  doAssert image[0, 1].r == 255 and image[3, 1].r == 255
  doAssert image[1, 2].r == 255 and image[4, 2].r == 255
  image.fill(rgbx(0, 0, 0, 0))
  image.drawEbText(font, [0xB0'u8, 0x71, 0x71], 0, 0, palette, maxWidth = 3)
  doAssert image[1, 1].r == 255 and image[4, 1].r == 0
  var tracked = font
  tracked.extraSpacing = 1
  image.fill(rgbx(0, 0, 0, 0))
  image.drawEbText(tracked, [0x71'u8, 0x71], 0, 0, palette)
  doAssert image[1, 1].r == 255 and image[5, 1].r == 255
  doAssert image[4, 1].r == 0
  var rejected = false
  try:
    discard loadEbUiFont(@[])
  except ValueError:
    rejected = true
  doAssert rejected, "Missing ROM descriptors must fail with a useful error"

main()
