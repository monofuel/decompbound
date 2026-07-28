## Hand-authored 3×5 pixel bitmap font for the F8 debug overlay.
##
## Digits 0-9, uppercase A-Z, and a small punctuation set (`:`, `-`, `+`,
## space, `/`). No game font and no external assets — pure Nim consts so the
## overlay stays copyright-clean and unit-testable headless.

import
  pixie

const
  ## Glyph cell width in pixels (excluding the 1px inter-char gap).
  HudFontW* = 3
  ## Glyph cell height in pixels.
  HudFontH* = 5
  ## Horizontal gap between glyphs when drawing a string.
  HudFontGap* = 1
  ## Advance per character including gap.
  HudFontAdvance* = HudFontW + HudFontGap

  # Each glyph is 5 row-bytes; only the low 3 bits of each row are used
  # (bit2 = leftmost pixel). Hand-packed for hex + A-Z + a few separators.
  GlyphSpace = [0x00'u8, 0x00, 0x00, 0x00, 0x00]
  Glyph0 = [0x07'u8, 0x05, 0x05, 0x05, 0x07]
  Glyph1 = [0x02'u8, 0x06, 0x02, 0x02, 0x07]
  Glyph2 = [0x07'u8, 0x01, 0x07, 0x04, 0x07]
  Glyph3 = [0x07'u8, 0x01, 0x03, 0x01, 0x07]
  Glyph4 = [0x05'u8, 0x05, 0x07, 0x01, 0x01]
  Glyph5 = [0x07'u8, 0x04, 0x07, 0x01, 0x07]
  Glyph6 = [0x07'u8, 0x04, 0x07, 0x05, 0x07]
  Glyph7 = [0x07'u8, 0x01, 0x01, 0x01, 0x01]
  Glyph8 = [0x07'u8, 0x05, 0x07, 0x05, 0x07]
  Glyph9 = [0x07'u8, 0x05, 0x07, 0x01, 0x07]
  GlyphA = [0x07'u8, 0x05, 0x07, 0x05, 0x05]
  GlyphB = [0x06'u8, 0x05, 0x06, 0x05, 0x06]
  GlyphC = [0x07'u8, 0x04, 0x04, 0x04, 0x07]
  GlyphD = [0x06'u8, 0x05, 0x05, 0x05, 0x06]
  GlyphE = [0x07'u8, 0x04, 0x06, 0x04, 0x07]
  GlyphF = [0x07'u8, 0x04, 0x06, 0x04, 0x04]
  GlyphG = [0x07'u8, 0x04, 0x05, 0x05, 0x07]
  GlyphH = [0x05'u8, 0x05, 0x07, 0x05, 0x05]
  GlyphI = [0x07'u8, 0x02, 0x02, 0x02, 0x07]
  GlyphJ = [0x01'u8, 0x01, 0x01, 0x05, 0x07]
  GlyphK = [0x05'u8, 0x06, 0x04, 0x06, 0x05]
  GlyphL = [0x04'u8, 0x04, 0x04, 0x04, 0x07]
  GlyphM = [0x05'u8, 0x07, 0x07, 0x05, 0x05]
  GlyphN = [0x05'u8, 0x07, 0x07, 0x07, 0x05]
  GlyphO = [0x07'u8, 0x05, 0x05, 0x05, 0x07]
  GlyphP = [0x07'u8, 0x05, 0x07, 0x04, 0x04]
  GlyphQ = [0x07'u8, 0x05, 0x05, 0x07, 0x01]
  GlyphR = [0x07'u8, 0x05, 0x06, 0x05, 0x05]
  GlyphS = [0x07'u8, 0x04, 0x07, 0x01, 0x07]
  GlyphT = [0x07'u8, 0x02, 0x02, 0x02, 0x02]
  GlyphU = [0x05'u8, 0x05, 0x05, 0x05, 0x07]
  GlyphV = [0x05'u8, 0x05, 0x05, 0x05, 0x02]
  GlyphW = [0x05'u8, 0x05, 0x07, 0x07, 0x05]
  GlyphX = [0x05'u8, 0x05, 0x02, 0x05, 0x05]
  GlyphY = [0x05'u8, 0x05, 0x07, 0x02, 0x02]
  GlyphZ = [0x07'u8, 0x01, 0x02, 0x04, 0x07]
  GlyphColon = [0x00'u8, 0x02, 0x00, 0x02, 0x00]
  GlyphDash = [0x00'u8, 0x00, 0x07, 0x00, 0x00]
  GlyphPlus = [0x00'u8, 0x02, 0x07, 0x02, 0x00]
  GlyphSlash = [0x01'u8, 0x01, 0x02, 0x04, 0x04]
  GlyphEq = [0x00'u8, 0x07, 0x00, 0x07, 0x00]
  GlyphDot = [0x00'u8, 0x00, 0x00, 0x00, 0x02]
  GlyphLt = [0x01'u8, 0x02, 0x04, 0x02, 0x01]
  GlyphGt = [0x04'u8, 0x02, 0x01, 0x02, 0x04]
  GlyphUnknown = [0x07'u8, 0x05, 0x02, 0x00, 0x02]

type
  GlyphRows = array[HudFontH, uint8]

proc glyphFor*(ch: char): GlyphRows =
  ## Return the 3×5 bitmap rows for `ch` (case-insensitive letters).
  let c =
    if ch >= 'a' and ch <= 'z': char(ord(ch) - 32)
    else: ch
  case c
  of ' ': GlyphSpace
  of '0': Glyph0
  of '1': Glyph1
  of '2': Glyph2
  of '3': Glyph3
  of '4': Glyph4
  of '5': Glyph5
  of '6': Glyph6
  of '7': Glyph7
  of '8': Glyph8
  of '9': Glyph9
  of 'A': GlyphA
  of 'B': GlyphB
  of 'C': GlyphC
  of 'D': GlyphD
  of 'E': GlyphE
  of 'F': GlyphF
  of 'G': GlyphG
  of 'H': GlyphH
  of 'I': GlyphI
  of 'J': GlyphJ
  of 'K': GlyphK
  of 'L': GlyphL
  of 'M': GlyphM
  of 'N': GlyphN
  of 'O': GlyphO
  of 'P': GlyphP
  of 'Q': GlyphQ
  of 'R': GlyphR
  of 'S': GlyphS
  of 'T': GlyphT
  of 'U': GlyphU
  of 'V': GlyphV
  of 'W': GlyphW
  of 'X': GlyphX
  of 'Y': GlyphY
  of 'Z': GlyphZ
  of ':': GlyphColon
  of '-': GlyphDash
  of '+': GlyphPlus
  of '/': GlyphSlash
  of '=': GlyphEq
  of '.': GlyphDot
  of '<': GlyphLt
  of '>': GlyphGt
  else: GlyphUnknown

proc drawHudChar*(
    image: Image; x, y: int; ch: char;
    fg = rgbx(255, 255, 220, 255); bg = rgbx(0, 0, 0, 0)
) =
  ## Plot one glyph at pixel `(x, y)`. Transparent `bg` skips background fill.
  let g = glyphFor(ch)
  for row in 0 ..< HudFontH:
    let bits = g[row]
    for col in 0 ..< HudFontW:
      let px = x + col
      let py = y + row
      if px < 0 or py < 0 or px >= image.width or py >= image.height:
        continue
      # bit2 = left column.
      let on = (bits and (1'u8 shl (HudFontW - 1 - col))) != 0
      if on:
        image[px, py] = fg
      elif bg.a != 0:
        image[px, py] = bg

proc drawHudText*(
    image: Image; x, y: int; text: string;
    fg = rgbx(255, 255, 220, 255); bg = rgbx(0, 0, 0, 0)
) =
  ## Draw `text` left-to-right with a 1px gap between glyphs.
  var cx = x
  for ch in text:
    drawHudChar(image, cx, y, ch, fg, bg)
    cx += HudFontAdvance

proc hudTextWidth*(text: string): int =
  ## Pixel width of `text` including inter-char gaps (no trailing gap).
  if text.len == 0:
    return 0
  text.len * HudFontW + (text.len - 1) * HudFontGap

proc countLitPixels*(image: Image): int =
  ## Count non-transparent, non-black-ish pixels (unit-test helper).
  for i in 0 ..< image.data.len:
    let p = image.data[i]
    if p.a > 0 and (p.r > 0 or p.g > 0 or p.b > 0):
      inc result
