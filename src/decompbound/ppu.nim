## PPU frame renderer (Goal 2 milestone 4): draws the current VRAM/CGRAM
## state into a pixie image. Basic HDMA, color math, and brightness are
## supported so that the initial red TV static over the War Against Giygas
## card (and similar Giygas death effects) become visible.

import
  pixie,
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
                    paletteBase: int, prio: int = -1) =
  ## Fill a 256-wide line buffer with one BG layer's pixels for scanline py,
  ## marking which pixels were opaque. Honors latched scroll and map size.
  ## prio filters by the tilemap per-tile priority bit (0x2000): -1 = all
  ## tiles, 0 = low-priority tiles only, 1 = high-priority tiles only. Used to
  ## split a layer across the priority order (e.g. BG3-priority menus).
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
    if prio >= 0 and ((entry and 0x2000) != 0).int != prio:
      continue
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

proc modeLayers(mode: int, bg3prio: bool): seq[tuple[bg, bpp, pal, prio: int]] =
  ## Back-to-front BG passes for a mode: (layer, bpp, palette base, priority
  ## filter). prio -1 = all tiles; 0 = low-priority tiles only; 1 = high only.
  ## In mode 1 with the BG3-priority bit ($2105 bit 3) set, BG3 is split: its
  ## low-priority tiles stay at the back, but its high-priority tiles draw in
  ## FRONT of BG1/BG2 (this is how EarthBound's menus put their text window over
  ## the checkerboard BG2).
  case mode:
  of 0: @[(3, 2, 96, -1), (2, 2, 64, -1), (1, 2, 32, -1), (0, 2, 0, -1)]
  of 1:
    if bg3prio: @[(2, 2, 0, 0), (1, 4, 0, -1), (0, 4, 0, -1), (2, 2, 0, 1)]
    else: @[(2, 2, 0, -1), (1, 4, 0, -1), (0, 4, 0, -1)]
  of 3: @[(1, 4, 0, -1), (0, 8, 0, -1)]
  else: @[]

type
  WindowLine = array[ScreenWidth, bool]
    ## Per-pixel booleans across one scanline (true = inside the window area).

const
  WinCombineAnd = 1   ## WBGLOG/WOBJLOG 2-bit logic: 0=OR, 1=AND, 2=XOR, 3=XNOR.
  WinCombineXor = 2
  WinCombineXnor = 3

var
  objSuppressLine: array[ScreenHeight, WindowLine]
    ## Per-scanline mask: pixels where OBJ must not draw (force-main-black or the
    ## OBJ window disabled the layer). Populated by renderScanline so the later
    ## whole-frame sprite pass can clip sprites inside the transition iris.
  objSuppressActive: array[ScreenHeight, bool]
    ## Whether objSuppressLine[y] has any suppressing pixel (fast skip when not).
  objSpritePrio: array[ScreenHeight, array[ScreenWidth, int8]]
    ## OBJ priority (0-3) of the sprite drawn at each pixel this frame, or -1 if
    ## none. Recorded by renderSprites; read by overlayForegroundBg to interleave
    ## high-priority BG tiles in front of the sprites they should cover.
  anySpriteDrawn: bool
    ## True if renderSprites drew any pixel this frame (lets the foreground-BG
    ## overlay skip its passes entirely when nothing needs interleaving).

proc windowAreaLine(snes: SnesBus, sel: uint8, shift: int, combine: int,
                    area: var WindowLine) =
  ## Compute one layer's combined two-window "area" across the current scanline.
  ## `sel` is the layer's window-select register (W12SEL/W34SEL/WOBJSEL); `shift`
  ## is 0 for the low layer or 4 for the high layer packed into that register;
  ## `combine` is the 2-bit mask logic from WBGLOG/WOBJLOG. Honors per-window
  ## enable and in/out inversion. An empty range (left > right) is simply never
  ## inside, so its inverted form is always inside — matching hardware. Reads the
  ## live WH0-WH3 so per-scanline HDMA rewrites animate the region (the iris).
  # Per-window bits in the select register are ordered [invert, enable]: the low
  # bit of each window's pair is area-invert, the high bit is enable (the $2123 /
  # $2125 hardware layout). Swapping these renders the iris inverted/absent.
  let w1out = (sel and (1'u8 shl shift)) != 0          # bit+0: window 1 invert.
  let w1on = (sel and (1'u8 shl (shift + 1))) != 0     # bit+1: window 1 enable.
  let w2out = (sel and (1'u8 shl (shift + 2))) != 0    # bit+2: window 2 invert.
  let w2on = (sel and (1'u8 shl (shift + 3))) != 0     # bit+3: window 2 enable.
  let l1 = snes.ppuRegs[0x26].int      # WH0: window 1 left edge.
  let r1 = snes.ppuRegs[0x27].int      # WH1: window 1 right edge.
  let l2 = snes.ppuRegs[0x28].int      # WH2: window 2 left edge.
  let r2 = snes.ppuRegs[0x29].int      # WH3: window 2 right edge.
  for x in 0 ..< ScreenWidth:
    var inside: bool
    if w1on and w2on:
      var one = x >= l1 and x <= r1
      if w1out: one = not one
      var two = x >= l2 and x <= r2
      if w2out: two = not two
      inside = case combine
        of WinCombineAnd: one and two
        of WinCombineXor: one != two
        of WinCombineXnor: not (one != two)
        else: one or two
    elif w1on:
      inside = x >= l1 and x <= r1
      if w1out: inside = not inside
    elif w2on:
      inside = x >= l2 and x <= r2
      if w2out: inside = not inside
    else:
      inside = false
    area[x] = inside

proc bgWindowParams(bg: int): tuple[selIdx, shift, logicShift, screenBit: int] =
  ## Window registers for a BG layer (0-3 = BG1-BG4): the select-register
  ## ppuRegs index, the nibble shift within it, the 2-bit shift into WBGLOG
  ## ($212A), and the TMW/TSW screen-disable bit.
  case bg
  of 0: (0x23, 0, 0, 0)   # BG1: W12SEL low nibble.
  of 1: (0x23, 4, 2, 1)   # BG2: W12SEL high nibble.
  of 2: (0x24, 0, 4, 2)   # BG3: W34SEL low nibble.
  else: (0x24, 4, 6, 3)   # BG4: W34SEL high nibble.

proc compositeScreen(snes: SnesBus, py: int, mask: uint8, winReg: uint8,
                     backdrop: ColorRGBA): tuple[buf: array[ScreenWidth, ColorRGBA],
                                                 drawn: array[ScreenWidth, bool]] =
  ## Composite one screen (main or sub) for scanline py: backdrop, then the
  ## mask-enabled BG layers of the current mode, back to front. `winReg` is the
  ## screen's window-disable register (TMW $212E for main, TSW $212F for sub):
  ## where a layer's window bit is set, the combined window area hides that
  ## layer for this scanline so lower layers / backdrop show through. This is
  ## what carves the scene-transition iris and clips the battle bands. With
  ## winReg = 0 (the common case) nothing is masked and output is unchanged.
  let mode = (snes.ppuRegs[0x05] and 0x07).int
  let bg3prio = (snes.ppuRegs[0x05] and 0x08) != 0
  for px in 0..<ScreenWidth:
    result.buf[px] = backdrop
  var line: array[ScreenWidth, ColorRGBA]
  var lineDrawn: array[ScreenWidth, bool]
  var winHidden: WindowLine
  for layer in modeLayers(mode, bg3prio):
    if (mask.int and (1 shl layer.bg)) == 0:
      continue
    let wp = bgWindowParams(layer.bg)
    let windowed = (winReg and (1'u8 shl wp.screenBit)) != 0
    if windowed:
      let combine = (snes.ppuRegs[0x2A].int shr wp.logicShift) and 0x03
      snes.windowAreaLine(snes.ppuRegs[wp.selIdx], wp.shift, combine, winHidden)
    for px in 0..<ScreenWidth:
      lineDrawn[px] = false
    snes.bgScanlineInto(line, lineDrawn, py, layer.bg, layer.bpp, layer.pal,
                        layer.prio)
    for px in 0..<ScreenWidth:
      if lineDrawn[px] and not (windowed and winHidden[px]):
        result.buf[px] = line[px]
        result.drawn[px] = true

proc clamp8(v: int): uint8 =
  ## Clamp an int to a byte.
  if v < 0: 0'u8 elif v > 255: 255'u8 else: v.uint8

proc renderScanline*(snes: SnesBus, image: Image, py: int) =
  ## Render one fully composited scanline: main + subscreen color math +
  ## brightness, with window masking. Windows carve per-scanline regions: the
  ## layer windows (TMW/TSW) hide BG layers, and the color window (CGWSEL bits
  ## 7-4) forces the main screen black and gates where color math applies. This
  ## is the path that makes the scene-transition iris, the battle bands, and the
  ## Giygas red static (BG1 main + BG2 static subscreen, added) appear.
  let backdrop = bgr555ToColor(snes.cgram[0])
  let mainMask = snes.ppuRegs[0x2C]
  let cgadsub = snes.ppuRegs[0x31]
  let cgwsel = snes.ppuRegs[0x30]
  let mathLayers = cgadsub and 0x3F
  let doSub = (cgadsub and 0x40) != 0
  let doHalf = (cgadsub and 0x80) != 0
  let useSubScreen = (cgwsel and 0x02) != 0

  let main = snes.compositeScreen(py, mainMask, snes.ppuRegs[0x2E], backdrop)  # TMW.
  var mathBuf: array[ScreenWidth, ColorRGBA]
  var subDrawn: array[ScreenWidth, bool]
  if mathLayers != 0:
    if useSubScreen:
      let sub = snes.compositeScreen(py, snes.ppuRegs[0x2D], snes.ppuRegs[0x2F],
                                     backdrop)  # TSW.
      mathBuf = sub.buf
      subDrawn = sub.drawn
    else:
      let fixed = bgr555ToColor(snes.fixedColorB.uint16 or
        (snes.fixedColorG.uint16 shl 5) or (snes.fixedColorR.uint16 shl 10))
      for px in 0..<ScreenWidth:
        mathBuf[px] = fixed
        subDrawn[px] = true

  # Color (math) window: CGWSEL bits 7-6 force the main screen to black, and
  # bits 5-4 gate where color math applies, both relative to the color/math
  # window (WOBJSEL high nibble + WOBJLOG bits 3-2). Both default to 0 (off), so
  # ordinary scenes are untouched. Force-black is the other half of the iris:
  # the region outside the shrinking circle goes solid black.
  let forceBlackMode = (cgwsel.int shr 6) and 0x03
  let mathEnableMode = (cgwsel.int shr 4) and 0x03
  var colorWin: WindowLine
  if forceBlackMode != 0 or mathEnableMode != 0:
    let combine = (snes.ppuRegs[0x2B].int shr 2) and 0x03   # WOBJLOG color bits.
    snes.windowAreaLine(snes.ppuRegs[0x25], 4, combine, colorWin)   # WOBJSEL hi.

  # OBJ (sprite) window for this scanline: main-screen OBJ window disable is TMW
  # $212E bit 4; the OBJ window area is WOBJSEL low nibble ($2125) + WOBJLOG bits
  # 1-0 ($212B). Recorded together with the force-black region so the whole-frame
  # sprite pass (renderSprites) clips sprites to the same per-scanline window,
  # keeping them inside the iris. Both default off, so ordinary scenes record an
  # all-false line and nothing is suppressed.
  let objWindowed = (snes.ppuRegs[0x2E] and 0x10) != 0
  var objWin: WindowLine
  if objWindowed:
    let objCombine = snes.ppuRegs[0x2B].int and 0x03
    snes.windowAreaLine(snes.ppuRegs[0x25], 0, objCombine, objWin)
  objSuppressActive[py] = forceBlackMode != 0 or objWindowed

  let bright = ((snes.ppuRegs[0x00].int and 0x0F) + 1)
  for px in 0..<ScreenWidth:
    var m = main.buf[px]
    # Force main screen black: 0=never, 1=outside window, 2=inside, 3=always.
    let blackHere = case forceBlackMode
      of 1: not colorWin[px]
      of 2: colorWin[px]
      of 3: true
      else: false
    if blackHere:
      m = ColorRGBA(r: 0, g: 0, b: 0, a: 255)
    objSuppressLine[py][px] = blackHere or (objWindowed and objWin[px])
    # Color-math enable window: 0=always, 1=inside, 2=outside, 3=never.
    let mathHere = mathLayers != 0 and (case mathEnableMode
      of 1: colorWin[px]
      of 2: not colorWin[px]
      of 3: false
      else: true)
    if mathHere:
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

proc renderBgScanline*(snes: SnesBus, image: Image, py: int, bg: int, bpp: int,
                       paletteBase: int, prio: int = -1) =
  ## Render one scanline of a single BG layer (legacy per-line path, kept
  ## for callers that do not need color math). prio filters by the tilemap
  ## per-tile priority bit (0x2000): -1 = all, 0 = low only, 1 = high only.
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
    if prio >= 0 and ((entry and 0x2000) != 0).int != prio:
      continue
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
  ## Sprites honor INIDISP master brightness (like BG layers) so fades dim OBJ
  ## and BG together — otherwise a brightness-ramp fade (e.g. the EarthBound
  ## logo dissolve) dims the BG letters but leaves sprite glows full-bright, so
  ## the BG parts (like the "B") appear to vanish early.
  for py in 0..<ScreenHeight:
    for px in 0..<ScreenWidth:
      objSpritePrio[py][px] = -1
  anySpriteDrawn = false
  if (snes.ppuRegs[0x00] and 0x80) != 0:
    return  # force blank: nothing is displayed
  let bright = (snes.ppuRegs[0x00].int and 0x0F) + 1
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

  # OBJ-vs-OBJ order is OAM index only: a lower index is frontmost. (The 2-bit
  # attribute priority does NOT order sprites against each other — it only picks
  # the OBJ-vs-BG band, recorded in objSpritePrio for overlayForegroundBg.) Draw
  # 127 down to 0 so sprite 0 ends up on top.
  for sprite in countdown(127, 0):
    let base = sprite * 4
    let extra = snes.oam[512 + sprite div 4]
    let extraShift = (sprite mod 4) * 2
    let xHigh = (extra shr extraShift) and 1
    let large = ((extra shr (extraShift + 1)) and 1) != 0
    let size = if large: sizes[1] else: sizes[0]

    let y = snes.oam[base + 1].int
    # Skip sprites with no visible row: entirely in the off-screen 224-255 band
    # and not wrapping past line 256 back to the top.
    if y >= ScreenHeight and y + size <= 256:
      continue

    var x = snes.oam[base].int or (xHigh.int shl 8)
    if x >= 256:
      x -= 512
    let tile = snes.oam[base + 2].int
    let attr = snes.oam[base + 3]
    let prio = int((attr shr 4) and 0x03)
    let paletteGroup = (attr.int shr 1) and 0x07
    let table = (attr and 1).int
    let flipX = (attr and 0x40) != 0
    let flipY = (attr and 0x80) != 0
    let nameGap = (((snes.ppuRegs[0x01].int shr 3) and 3) + 1) shl 12
    let tileBase = (chrBase + table * nameGap) and 0x7FFF

    for py in 0..<size:
      let sy = if flipY: size - 1 - py else: py
      # Sprite Y wraps at 256: a sprite near line 256 shows its wrapped rows at
      # the top of the screen (how sprites enter from the top edge).
      let screenY = (y + py) and 0xFF
      if screenY >= ScreenHeight:
        continue
      for px in 0..<size:
        let sx = if flipX: size - 1 - px else: px
        let screenX = x + px
        if screenX < 0 or screenX >= ScreenWidth:
          continue
        if objSuppressActive[screenY] and objSuppressLine[screenY][screenX]:
          continue   # OBJ window / force-black hides sprites here (the iris).
        let tileCol = (tile + sx div 8) and 0x0F
        let tileRow = ((tile shr 4) + sy div 8) and 0x0F
        let tileIndex = tileRow * 16 + tileCol
        let index = snes.tilePixel(tileBase, tileIndex, sx mod 8, sy mod 8, 4)
        if index == 0:
          continue
        var color = bgr555ToColor(snes.cgram[128 + paletteGroup * 16 + index])
        color.r = ((color.r.int * bright) div 16).uint8
        color.g = ((color.g.int * bright) div 16).uint8
        color.b = ((color.b.int * bright) div 16).uint8
        image[screenX, screenY] = color
        objSpritePrio[screenY][screenX] = prio.int8
        anySpriteDrawn = true

proc overlayForegroundBg*(snes: SnesBus, image: Image) =
  ## Interleave HIGH-priority BG tiles in FRONT of the sprites they should cover,
  ## over the whole-frame sprite pass. The per-scanline composite already orders
  ## BG layers correctly, but sprites are a separate later pass, so without this
  ## every sprite sits on top of every BG. Per the SNES mode-1 priority ladder,
  ## high-priority BG1/BG2 tiles sit above OBJ priority 0-2 (a foreground map tile
  ## over an NPC; the battle command/status windows over the battlers), and BG3
  ## high-priority tiles sit above OBJ 0 — or above ALL OBJ when the BG3-priority
  ## bit ($2105.3) is set (dialogue/HUD windows over characters).
  ##
  ## Only pixels where a sprite was drawn (objSpritePrio >= 0) are touched, so the
  ## full per-scanline composite (color math, windows, force-black) is preserved
  ## everywhere else. Call AFTER renderSprites.
  if not anySpriteDrawn: return
  if (snes.ppuRegs[0x00] and 0x80) != 0: return         # force blank
  if (snes.ppuRegs[0x05] and 0x07) != 1: return         # scoped to mode 1
  let mainMask = snes.ppuRegs[0x2C].int
  let bg3prio = (snes.ppuRegs[0x05] and 0x08) != 0
  # High-priority BG passes, back to front: (bg, bpp, paletteBase, maxSpritePrio
  # covered). BG1/BG2-high sit above OBJ 0-2; BG3-high above OBJ 0, or all OBJ
  # when the BG3-priority bit moves it to the very front.
  var passes: seq[tuple[bg, bpp, pal, maxPrio: int]] = @[]
  if (mainMask and 0x04) != 0 and not bg3prio:
    passes.add (2, 2, 0, 0)     # BG3-high (no prio bit).
  if (mainMask and 0x02) != 0:
    passes.add (1, 4, 0, 2)     # BG2-high.
  if (mainMask and 0x01) != 0:
    passes.add (0, 4, 0, 2)     # BG1-high.
  if (mainMask and 0x04) != 0 and bg3prio:
    passes.add (2, 2, 0, 3)     # BG3-high (prio bit): frontmost, over all OBJ.
  let bright = (snes.ppuRegs[0x00].int and 0x0F) + 1
  var line: array[ScreenWidth, ColorRGBA]
  var drawn: array[ScreenWidth, bool]
  for p in passes:
    for py in 0..<ScreenHeight:
      for px in 0..<ScreenWidth:
        drawn[px] = false
      snes.bgScanlineInto(line, drawn, py, p.bg, p.bpp, p.pal, 1)  # high tiles.
      for px in 0..<ScreenWidth:
        if not drawn[px]:
          continue
        let sp = objSpritePrio[py][px].int
        if sp < 0 or sp > p.maxPrio:
          continue    # no sprite here, or the sprite is in front of this BG.
        var c = line[px]
        c.r = ((c.r.int * bright) div 16).uint8
        c.g = ((c.g.int * bright) div 16).uint8
        c.b = ((c.b.int * bright) div 16).uint8
        image[px, py] = c

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

  # The whole-frame path does not populate the per-scanline OBJ suppression mask
  # (that comes from renderScanline); clear it so renderSprites here never
  # suppresses sprites based on stale window state from another render path.
  for py in 0..<ScreenHeight:
    objSuppressActive[py] = false

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
    let doAdd = (cgadsub and 0x80) == 0    # CGADSUB bit 7: 0=add, 1=subtract
    let doHalf = (cgadsub and 0x40) != 0   # CGADSUB bit 6: halve the math result
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
