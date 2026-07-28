## Headless unit test for the F8 overlay bitmap font.
## Renders a string into a pixie Image and asserts nonzero lit pixels.

import
  pixie,
  ../src/tools/hud_font

proc main() =
  ## Draw a representative HUD line and require visible pixels.
  let img = newImage(160, 16)
  img.fill(rgbx(0, 0, 0, 255))
  drawHudText(img, 1, 1, "RNG 8B00EDC6 +3")
  let lit = countLitPixels(img)
  if lit == 0:
    raise newException(AssertionDefect, "hud font rendered zero lit pixels")
  # At least a few glyphs should light more than a single pixel each.
  if lit < 20:
    raise newException(AssertionDefect, "hud font too sparse: lit=" & $lit)
  # Unknown glyph must still draw something.
  let img2 = newImage(16, 8)
  img2.fill(rgbx(0, 0, 0, 255))
  drawHudChar(img2, 1, 1, '?')
  if countLitPixels(img2) == 0:
    raise newException(AssertionDefect, "unknown glyph is blank")
  # Width helper sanity.
  if hudTextWidth("AB") != HudFontW * 2 + HudFontGap:
    raise newException(AssertionDefect, "hudTextWidth mismatch")

when isMainModule:
  main()
