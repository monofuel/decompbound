## PPU frame renderer (Goal 2 milestone 4): draws the current VRAM/CGRAM
## state into a pixie image. Scanline effects (HDMA) and sprites come
## later; this renders BG layers for the modes Earthbound's menus and
## intro screens use (0 and 1), which is enough for screenshot milestones.

import
  pixie,
  ./snesbus

const
  ScreenWidth* = 256
  ScreenHeight* = 224

proc bgr555ToColor(value: uint16): ColorRGBA =
  ## Convert a SNES BGR555 palette entry to RGBA.
  let r = (value and 0x1F).uint8
  let g = ((value shr 5) and 0x1F).uint8
  let b = ((value shr 10) and 0x1F).uint8
  ColorRGBA(r: (r shl 3) or (r shr 2), g: (g shl 3) or (g shr 2),
            b: (b shl 3) or (b shr 2), a: 255)

proc tilePixel(snes: SnesBus, chrBase: int, tile: int, x: int, y: int,
               bpp: int): int =
  ## Decode one pixel (palette index within the tile's palette) from a
  ## 2bpp, 4bpp, or 8bpp tile in VRAM.
  let wordsPerTile = bpp * 4
  let base = chrBase + tile * wordsPerTile
  var index = 0
  # Planes 0/1 from the first 8 words.
  let plane01 = snes.vram[(base + y) and 0x7FFF]
  if ((plane01 shr (7 - x)) and 1) != 0: index = index or 1
  if ((plane01 shr (15 - x)) and 1) != 0: index = index or 2
  if bpp >= 4:
    let plane23 = snes.vram[(base + 8 + y) and 0x7FFF]
    if ((plane23 shr (7 - x)) and 1) != 0: index = index or 4
    if ((plane23 shr (15 - x)) and 1) != 0: index = index or 8
  if bpp == 8:
    let plane45 = snes.vram[(base + 16 + y) and 0x7FFF]
    let plane67 = snes.vram[(base + 24 + y) and 0x7FFF]
    if ((plane45 shr (7 - x)) and 1) != 0: index = index or 0x10
    if ((plane45 shr (15 - x)) and 1) != 0: index = index or 0x20
    if ((plane67 shr (7 - x)) and 1) != 0: index = index or 0x40
    if ((plane67 shr (15 - x)) and 1) != 0: index = index or 0x80
  result = index

proc renderBg(snes: SnesBus, image: Image, bg: int, bpp: int,
              paletteBase: int) =
  ## Render one background layer over the image (transparent pixels skip).
  let scReg = snes.ppuRegs[0x07 + bg]  # $2107-$210A.
  let tilemapBase = ((scReg.int shr 2) shl 10) and 0x7FFF
  let chrReg = if bg < 2: snes.ppuRegs[0x0B] else: snes.ppuRegs[0x0C]
  let chrShift = if bg mod 2 == 0: chrReg.int and 0x0F
                 else: (chrReg.int shr 4) and 0x0F
  let chrBase = (chrShift shl 12) and 0x7FFF

  for ty in 0..<28:
    for tx in 0..<32:
      let entry = snes.vram[(tilemapBase + ty * 32 + tx) and 0x7FFF]
      let tile = (entry and 0x3FF).int
      let palette = ((entry shr 10) and 0x07).int
      let flipX = (entry and 0x4000) != 0
      let flipY = (entry and 0x8000) != 0
      for py in 0..<8:
        for px in 0..<8:
          let sx = if flipX: 7 - px else: px
          let sy = if flipY: 7 - py else: py
          let index = snes.tilePixel(chrBase, tile, sx, sy, bpp)
          if index == 0:
            continue
          let colorIndex = paletteBase + palette * (1 shl bpp) + index
          let color = bgr555ToColor(snes.cgram[colorIndex and 0xFF])
          image[tx * 8 + px, ty * 8 + py] = color

proc renderSprites(snes: SnesBus, image: Image) =
  ## Render OAM sprites (no per-scanline limits; front-to-back priority
  ## approximated by drawing sprite 127 first so sprite 0 wins overlaps).
  let obsel = snes.ppuRegs[0x01]
  let chrBase = ((obsel.int and 0x07) shl 13) and 0x7FFF
  let sizeSelect = (obsel.int shr 5) and 0x07
  # Small/large pixel sizes per OBSEL size select.
  let sizes = case sizeSelect:
    of 0: (8, 16)
    of 1: (8, 32)
    of 2: (8, 64)
    of 3: (16, 32)
    of 4: (16, 64)
    of 5: (32, 64)
    else: (16, 32)

  for sprite in countdown(127, 0):
    let base = sprite * 4
    let extra = snes.oam[512 + sprite div 4]
    let extraShift = (sprite mod 4) * 2
    let xHigh = (extra shr extraShift) and 1
    let large = ((extra shr (extraShift + 1)) and 1) != 0
    let size = if large: sizes[1] else: sizes[0]

    var x = snes.oam[base].int or (xHigh.int shl 8)
    if x >= 256:
      x -= 512
    let y = snes.oam[base + 1].int
    let tile = snes.oam[base + 2].int
    let attr = snes.oam[base + 3]
    let paletteGroup = (attr.int shr 1) and 0x07
    let table = (attr and 1).int
    let flipX = (attr and 0x40) != 0
    let flipY = (attr and 0x80) != 0
    let tileBase = chrBase + table * (((snes.ppuRegs[0x01].int shr 3) and 3 + 1) shl 12)

    for py in 0..<size:
      let sy = if flipY: size - 1 - py else: py
      let screenY = y + py
      if screenY < 0 or screenY >= ScreenHeight:
        continue
      for px in 0..<size:
        let sx = if flipX: size - 1 - px else: px
        let screenX = x + px
        if screenX < 0 or screenX >= ScreenWidth:
          continue
        # Sprites are built from 8x8 4bpp tiles in a 16x16-tile table.
        let tileCol = (tile + sx div 8) and 0x0F
        let tileRow = ((tile shr 4) + sy div 8) and 0x0F
        let tileIndex = tileRow * 16 + tileCol
        let index = snes.tilePixel(tileBase, tileIndex, sx mod 8, sy mod 8, 4)
        if index == 0:
          continue
        let color = bgr555ToColor(snes.cgram[128 + paletteGroup * 16 + index])
        image[screenX, screenY] = color

proc renderFrame*(snes: SnesBus): Image =
  ## Render the current PPU state: backdrop, then BG layers back to front.
  result = newImage(ScreenWidth, ScreenHeight)
  let backdrop = bgr555ToColor(snes.cgram[0])
  result.fill(backdrop)

  let mode = snes.ppuRegs[0x05] and 0x07
  let mainScreen = snes.ppuRegs[0x2C]  # TM: enabled main screen layers.

  case mode:
  of 0:
    # Mode 0: four 2bpp layers, each with its own palette section.
    if (mainScreen and 0x08) != 0: snes.renderBg(result, 3, 2, 96)
    if (mainScreen and 0x04) != 0: snes.renderBg(result, 2, 2, 64)
    if (mainScreen and 0x02) != 0: snes.renderBg(result, 1, 2, 32)
    if (mainScreen and 0x01) != 0: snes.renderBg(result, 0, 2, 0)
  of 1:
    # Mode 1: BG1/BG2 4bpp, BG3 2bpp.
    if (mainScreen and 0x04) != 0: snes.renderBg(result, 2, 2, 0)
    if (mainScreen and 0x02) != 0: snes.renderBg(result, 1, 4, 0)
    if (mainScreen and 0x01) != 0: snes.renderBg(result, 0, 4, 0)
  of 3:
    # Mode 3: BG1 8bpp (256 colors), BG2 4bpp.
    if (mainScreen and 0x02) != 0: snes.renderBg(result, 1, 4, 0)
    if (mainScreen and 0x01) != 0: snes.renderBg(result, 0, 8, 0)
  else:
    # Other modes not implemented yet; backdrop only.
    discard

  # Sprites over backgrounds (per-pixel BG/OBJ priority comes later).
  if (mainScreen and 0x10) != 0:
    snes.renderSprites(result)
