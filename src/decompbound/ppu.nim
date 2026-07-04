## PPU frame renderer (Goal 2 milestone 4): draws the current VRAM/CGRAM
## state into a pixie image. Basic HDMA, color math, and brightness are
## supported so that the initial red TV static over the War Against Giygas
## card (and similar Giygas death effects) become visible.

import
  pixie,
  std/algorithm,
  ./snesbus

const
  ScreenWidth* = 256
  ScreenHeight* = 224

proc bgr555ToColor*(value: uint16): ColorRGBA =
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
  ## Render one background layer over the image (transparent pixels skip),
  ## honoring the latched H/V scroll and the tilemap size bits (32/64
  ## tile maps arranged as up to four 32x32 screens).
  let scReg = snes.ppuRegs[0x07 + bg]  # $2107-$210A.
  let tilemapBase = ((scReg.int shr 2) shl 10) and 0x7FFF
  let sizeBits = scReg.int and 3
  let chrReg = if bg < 2: snes.ppuRegs[0x0B] else: snes.ppuRegs[0x0C]
  let chrShift = if bg mod 2 == 0: chrReg.int and 0x0F
                 else: (chrReg.int shr 4) and 0x0F
  let chrBase = (chrShift shl 12) and 0x7FFF
  let hofs = snes.bgScroll[bg * 2].int
  let vofs = snes.bgScroll[bg * 2 + 1].int

  for py in 0..<ScreenHeight:
    let wy = py + vofs
    var ty = (wy div 8)
    let subY = wy mod 8
    for px in 0..<ScreenWidth:
      let wx = px + hofs
      var tx = (wx div 8)
      # Screen selection within multi-screen maps: each screen is a
      # 32x32-tile block of 0x400 words; the second row of screens (64-tall
      # maps) starts 0x800 in when the map is 64 wide.
      let screenX = if (sizeBits and 1) != 0: (tx div 32) and 1 else: 0
      let screenY = if (sizeBits and 2) != 0: (ty div 32) and 1 else: 0
      var mapBase = tilemapBase + screenX * 0x400
      mapBase += screenY * (if sizeBits == 3: 0x800 else: 0x400)
      let entry = snes.vram[(mapBase + (ty mod 32) * 32 + (tx mod 32)) and 0x7FFF]
      let tile = (entry and 0x3FF).int
      let palette = ((entry shr 10) and 0x07).int
      let sx = if (entry and 0x4000) != 0: 7 - (wx mod 8) else: wx mod 8
      let sy = if (entry and 0x8000) != 0: 7 - subY else: subY
      let index = snes.tilePixel(chrBase, tile, sx, sy, bpp)
      if index == 0:
        continue
      let colorIndex = paletteBase + palette * (1 shl bpp) + index
      image[px, py] = bgr555ToColor(snes.cgram[colorIndex and 0xFF])

proc bgScanlineInto(snes: SnesBus, buf: var openArray[ColorRGBA],
                    drawn: var openArray[bool], py: int, bg: int, bpp: int,
                    paletteBase: int) =
  ## Fill a 256-wide line buffer with one BG layer's pixels for scanline py,
  ## marking which pixels were opaque. Honors latched scroll and map size.
  let scReg = snes.ppuRegs[0x07 + bg]
  let tilemapBase = ((scReg.int shr 2) shl 10) and 0x7FFF
  let sizeBits = scReg.int and 3
  let chrReg = if bg < 2: snes.ppuRegs[0x0B] else: snes.ppuRegs[0x0C]
  let chrShift = if bg mod 2 == 0: chrReg.int and 0x0F
                 else: (chrReg.int shr 4) and 0x0F
  let chrBase = (chrShift shl 12) and 0x7FFF
  let hofs = snes.bgScroll[bg * 2].int
  let vofs = snes.bgScroll[bg * 2 + 1].int

  let wy = py + vofs
  let ty = wy div 8
  let subY = wy mod 8
  for px in 0..<ScreenWidth:
    let wx = px + hofs
    let tx = wx div 8
    let screenX = if (sizeBits and 1) != 0: (tx div 32) and 1 else: 0
    let screenY = if (sizeBits and 2) != 0: (ty div 32) and 1 else: 0
    var mapBase = tilemapBase + screenX * 0x400
    mapBase += screenY * (if sizeBits == 3: 0x800 else: 0x400)
    let entry = snes.vram[(mapBase + (ty mod 32) * 32 + (tx mod 32)) and 0x7FFF]
    let tile = (entry and 0x3FF).int
    let palette = ((entry shr 10) and 0x07).int
    let sx = if (entry and 0x4000) != 0: 7 - (wx mod 8) else: wx mod 8
    let sy = if (entry and 0x8000) != 0: 7 - subY else: subY
    let index = snes.tilePixel(chrBase, tile, sx, sy, bpp)
    if index == 0:
      continue
    let colorIndex = paletteBase + palette * (1 shl bpp) + index
    buf[px] = bgr555ToColor(snes.cgram[colorIndex and 0xFF])
    drawn[px] = true

proc modeLayers(mode: int): seq[tuple[bg, bpp, pal: int]] =
  ## Back-to-front BG list for a mode: (layer, bpp, palette base).
  case mode:
  of 0: @[(3, 2, 96), (2, 2, 64), (1, 2, 32), (0, 2, 0)]
  of 1: @[(2, 2, 0), (1, 4, 0), (0, 4, 0)]
  of 3: @[(1, 4, 0), (0, 8, 0)]
  else: @[]

proc compositeScreen(snes: SnesBus, py: int, mask: uint8,
                     backdrop: ColorRGBA): tuple[buf: array[ScreenWidth, ColorRGBA],
                                                 drawn: array[ScreenWidth, bool]] =
  ## Composite one screen (main or sub) for scanline py: backdrop, then the
  ## mask-enabled BG layers of the current mode, back to front.
  let mode = (snes.ppuRegs[0x05] and 0x07).int
  for px in 0..<ScreenWidth:
    result.buf[px] = backdrop
  var line: array[ScreenWidth, ColorRGBA]
  var lineDrawn: array[ScreenWidth, bool]
  for layer in modeLayers(mode):
    if (mask.int and (1 shl layer.bg)) == 0:
      continue
    for px in 0..<ScreenWidth:
      lineDrawn[px] = false
    snes.bgScanlineInto(line, lineDrawn, py, layer.bg, layer.bpp, layer.pal)
    for px in 0..<ScreenWidth:
      if lineDrawn[px]:
        result.buf[px] = line[px]
        result.drawn[px] = true

proc clamp8(v: int): uint8 =
  ## Clamp an int to a byte.
  if v < 0: 0'u8 elif v > 255: 255'u8 else: v.uint8

proc renderScanline*(snes: SnesBus, image: Image, py: int) =
  ## Render one fully composited scanline: main + subscreen color math +
  ## brightness. This is the path that makes color-math effects (the Giygas
  ## red TV static: BG1 main + BG2 static subscreen, added) actually appear.
  let backdrop = bgr555ToColor(snes.cgram[0])
  let mainMask = snes.ppuRegs[0x2C]
  let cgadsub = snes.ppuRegs[0x31]
  let cgwsel = snes.ppuRegs[0x30]
  let mathLayers = cgadsub and 0x3F
  let doSub = (cgadsub and 0x40) != 0
  let doHalf = (cgadsub and 0x80) != 0
  let useSubScreen = (cgwsel and 0x02) != 0

  let main = snes.compositeScreen(py, mainMask, backdrop)
  var mathBuf: array[ScreenWidth, ColorRGBA]
  var subDrawn: array[ScreenWidth, bool]
  if mathLayers != 0:
    if useSubScreen:
      let sub = snes.compositeScreen(py, snes.ppuRegs[0x2D], backdrop)
      mathBuf = sub.buf
      subDrawn = sub.drawn
    else:
      let fixed = bgr555ToColor(snes.fixedColorB.uint16 or
        (snes.fixedColorG.uint16 shl 5) or (snes.fixedColorR.uint16 shl 10))
      for px in 0..<ScreenWidth:
        mathBuf[px] = fixed
        subDrawn[px] = true

  let bright = ((snes.ppuRegs[0x00].int and 0x0F) + 1)
  for px in 0..<ScreenWidth:
    var m = main.buf[px]
    if mathLayers != 0:
      let s = mathBuf[px]
      var r = if doSub: m.r.int - s.r.int else: m.r.int + s.r.int
      var g = if doSub: m.g.int - s.g.int else: m.g.int + s.g.int
      var b = if doSub: m.b.int - s.b.int else: m.b.int + s.b.int
      if doHalf and (useSubScreen and subDrawn[px] or not useSubScreen):
        r = r div 2
        g = g div 2
        b = b div 2
      m = ColorRGBA(r: clamp8(r), g: clamp8(g), b: clamp8(b), a: 255)
    m.r = ((m.r.int * bright) div 16).uint8
    m.g = ((m.g.int * bright) div 16).uint8
    m.b = ((m.b.int * bright) div 16).uint8
    image[px, py] = m

proc renderBgScanline*(snes: SnesBus, image: Image, py: int, bg: int, bpp: int, paletteBase: int) =
  ## Render one scanline of a single BG layer (legacy per-line path, kept
  ## for callers that do not need color math).
  let scReg = snes.ppuRegs[0x07 + bg]
  let tilemapBase = ((scReg.int shr 2) shl 10) and 0x7FFF
  let sizeBits = scReg.int and 3
  let chrReg = if bg < 2: snes.ppuRegs[0x0B] else: snes.ppuRegs[0x0C]
  let chrShift = if bg mod 2 == 0: chrReg.int and 0x0F
                 else: (chrReg.int shr 4) and 0x0F
  let chrBase = (chrShift shl 12) and 0x7FFF
  let hofs = snes.bgScroll[bg * 2].int
  let vofs = snes.bgScroll[bg * 2 + 1].int

  let wy = py + vofs
  var ty = wy div 8
  let subY = wy mod 8
  for px in 0..<ScreenWidth:
    let wx = px + hofs
    var tx = wx div 8
    let screenX = if (sizeBits and 1) != 0: (tx div 32) and 1 else: 0
    let screenY = if (sizeBits and 2) != 0: (ty div 32) and 1 else: 0
    var mapBase = tilemapBase + screenX * 0x400
    mapBase += screenY * (if sizeBits == 3: 0x800 else: 0x400)
    let entry = snes.vram[(mapBase + (ty mod 32) * 32 + (tx mod 32)) and 0x7FFF]
    let tile = (entry and 0x3FF).int
    let palette = ((entry shr 10) and 0x07).int
    let sx = if (entry and 0x4000) != 0: 7 - (wx mod 8) else: wx mod 8
    let sy = if (entry and 0x8000) != 0: 7 - subY else: subY
    let index = snes.tilePixel(chrBase, tile, sx, sy, bpp)
    if index == 0:
      continue
    let colorIndex = paletteBase + palette * (1 shl bpp) + index
    image[px, py] = bgr555ToColor(snes.cgram[colorIndex and 0xFF])

proc renderSprites*(snes: SnesBus, image: Image) =
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

  # Collect visible sprites with their priority for better layering
  type SpriteInfo = object
    idx: int
    prio: int
  var sprites: seq[SpriteInfo] = @[]
  for sprite in 0..<128:
    let base = sprite * 4
    let y = snes.oam[base + 1]
    if y >= 224: continue  # rough offscreen
    let attr = snes.oam[base + 3]
    let prio = int((attr shr 4) and 0x03)
    sprites.add SpriteInfo(idx: sprite, prio: prio)

  # Draw higher priority first (on top)
  sprites.sort(proc(a, b: SpriteInfo): int = cmp(b.prio, a.prio))

  for si in sprites:
    let sprite = si.idx
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
    let nameGap = (((snes.ppuRegs[0x01].int shr 3) and 3) + 1) shl 12
    let tileBase = (chrBase + table * nameGap) and 0x7FFF

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
  ## Applies brightness from INIDISP and basic color math (fixed color add/sub
  ## with optional half) using the final register state after HDMA updates.
  result = newImage(ScreenWidth, ScreenHeight)
  let inidisp = snes.ppuRegs[0x00]
  if (inidisp and 0x80) != 0:
    result.fill(ColorRGBA(r: 0, g: 0, b: 0, a: 255))
    return
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

  # Subscreen rendering for color math (TS mask).
  # The giygas red static appears to use BG2 (heavily scrolled via HDMA) + math.
  let subMask = snes.ppuRegs[0x2D]
  let cgadsub = snes.ppuRegs[0x31]
  let cgwsel = snes.ppuRegs[0x30]
  let useFixedSub = (cgwsel and 0x02) != 0
  var subImg: Image = nil
  if (cgadsub and 0x3F) != 0 and (subMask != 0 or useFixedSub):
    subImg = newImage(ScreenWidth, ScreenHeight)
    let subBackdrop = bgr555ToColor(snes.cgram[0])
    subImg.fill(subBackdrop)
    let subMode = mode
    case subMode:
    of 0:
      if (subMask and 0x08) != 0: snes.renderBg(subImg, 3, 2, 96)
      if (subMask and 0x04) != 0: snes.renderBg(subImg, 2, 2, 64)
      if (subMask and 0x02) != 0: snes.renderBg(subImg, 1, 2, 32)
      if (subMask and 0x01) != 0: snes.renderBg(subImg, 0, 2, 0)
    of 1:
      if (subMask and 0x04) != 0: snes.renderBg(subImg, 2, 2, 0)
      if (subMask and 0x02) != 0: snes.renderBg(subImg, 1, 4, 0)
      if (subMask and 0x01) != 0: snes.renderBg(subImg, 0, 4, 0)
    of 3:
      if (subMask and 0x02) != 0: snes.renderBg(subImg, 1, 4, 0)
      if (subMask and 0x01) != 0: snes.renderBg(subImg, 0, 8, 0)
    else:
      discard
    if (subMask and 0x10) != 0:
      snes.renderSprites(subImg)

  # Brightness scale (0-15).
  let bright = (inidisp and 0x0F) + 1
  if bright < 16:
    for i in 0 ..< result.data.len:
      var px = result.data[i]
      px.r = ((px.r.uint16 * bright.uint16) div 16).uint8
      px.g = ((px.g.uint16 * bright.uint16) div 16).uint8
      px.b = ((px.b.uint16 * bright.uint16) div 16).uint8
      result.data[i] = px

  # Color math: blend main with subscreen or fixed color where enabled.
  # This is what makes the red tv static overlay the war card (and giygas death).
  if (cgadsub and 0x3F) != 0:
    let doAdd = (cgadsub and 0x40) == 0
    let doHalf = (cgadsub and 0x80) != 0
    let fixed15 = snes.fixedColorB.uint16 or
                  (snes.fixedColorG.uint16 shl 5) or
                  (snes.fixedColorR.uint16 shl 10)
    let fixedPx = bgr555ToColor(fixed15)
    for i in 0 ..< result.data.len:
      var m = result.data[i]
      var s = if useFixedSub or subImg == nil:
                fixedPx
              else:
                subImg.data[i]
      var br = m.r.int
      var bg = m.g.int
      var bb = m.b.int
      if doAdd:
        br += s.r.int
        bg += s.g.int
        bb += s.b.int
      else:
        br -= s.r.int
        bg -= s.g.int
        bb -= s.b.int
      if doHalf:
        br = br div 2
        bg = bg div 2
        bb = bb div 2
      br = clamp(br, 0, 255)
      bg = clamp(bg, 0, 255)
      bb = clamp(bb, 0, 255)
      result.data[i] = ColorRGBA(r: br.uint8, g: bg.uint8, b: bb.uint8, a: 255)
