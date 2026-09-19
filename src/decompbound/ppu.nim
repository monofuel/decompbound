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
  BrightLut = block:
    var t: array[16, array[256, uint8]]
    for level in 0 .. 15:
      for c in 0 .. 255:
        t[level][c] = uint8((c * level) div 15)
    t
  NoSpriteRow = block:
    var r: array[ScreenWidth, int8]
    for i in 0 ..< ScreenWidth:
      r[i] = -1
    r

type
  Layer = tuple[bg, bpp, pal, prio: int]
    ## One BG compositing pass: layer, bits per pixel, palette base, priority
    ## filter (-1 = all tiles, 0 = low-priority tiles, 1 = high-priority tiles).

const
  # Back-to-front BG passes per mode. Mode 0 always uses the standard ladder
  # (BGMODE bit 3 is a mode 1 feature); mode 1 with bg3prio puts BG3-high last.
  Mode0Layers: array[8, Layer] = [(3, 2, 96, 0), (2, 2, 64, 0), (3, 2, 96, 1), (2, 2, 64, 1),
    (1, 2, 32, 0), (0, 2, 0, 0), (1, 2, 32, 1), (0, 2, 0, 1)]
  Mode1PrioLayers: array[6, Layer] = [(2, 2, 0, 0), (1, 4, 0, 0), (0, 4, 0, 0),
    (1, 4, 0, 1), (0, 4, 0, 1), (2, 2, 0, 1)]
  Mode1Layers: array[3, Layer] = [(2, 2, 0, -1), (1, 4, 0, -1), (0, 4, 0, -1)]
  Mode3Layers: array[2, Layer] = [(1, 4, 0, -1), (0, 8, 0, -1)]

proc bgr555ToColor*(value: uint16): ColorRGBA {.inline.} =
  ## Convert a SNES BGR555 palette entry to RGBA.
  let r = (value and 0x1F).uint8
  let g = ((value shr 5) and 0x1F).uint8
  let b = ((value shr 10) and 0x1F).uint8
  ColorRGBA(r: (r shl 3) or (r shr 2), g: (g shl 3) or (g shr 2),
            b: (b shl 3) or (b shr 2), a: 255)

proc applyMasterBrightness*(c: ColorRGBA, inidisp: uint8): ColorRGBA {.inline.} =
  ## Apply INIDISP master brightness (bits 0-3) as on hardware.
  ## Level 0 is true black; levels 1..15 scale each channel by n/15.
  ## (Bit 7 force-blank is handled by callers — this only covers the ramp.)
  ## Old (level+1)/16 never reached black, so brightness-only fades (Halken
  ## card, battle wipe, etc.) lingered on a dim ghost of the last frame.
  let level = inidisp.int and 0x0F
  if level == 0:
    return ColorRGBA(r: 0, g: 0, b: 0, a: c.a)
  if level >= 15:
    return c
  ColorRGBA(r: BrightLut[level][c.r], g: BrightLut[level][c.g],
            b: BrightLut[level][c.b], a: c.a)

proc toRgbx(c: ColorRGBA): ColorRGBX {.inline.} =
  ## Store an opaque colour in pixie's premultiplied layout (identity at a=255).
  ColorRGBX(r: c.r, g: c.g, b: c.b, a: 255)

proc tilePixel(snes: SnesBus, chrBase: int, tile: int, x: int, y: int,
               bpp: int): int {.inline.} =
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

proc tileRowIndices(snes: SnesBus, chrBase: int, tile: int, y: int, bpp: int,
                    idx: var array[8, uint8]) {.inline.} =
  ## Decode all eight palette indices of one tile row (x = 0..7), reading each
  ## VRAM plane word once. Bit layout matches tilePixel exactly.
  let base = chrBase + tile * (bpp * 4)
  let plane01 = snes.vram[(base + y) and 0x7FFF]
  var plane23 = 0'u16
  var plane45 = 0'u16
  var plane67 = 0'u16
  if bpp >= 4:
    plane23 = snes.vram[(base + 8 + y) and 0x7FFF]
  if bpp == 8:
    plane45 = snes.vram[(base + 16 + y) and 0x7FFF]
    plane67 = snes.vram[(base + 24 + y) and 0x7FFF]
  for x in 0 .. 7:
    var index = 0
    if ((plane01 shr (7 - x)) and 1) != 0: index = index or 1
    if ((plane01 shr (15 - x)) and 1) != 0: index = index or 2
    if bpp >= 4:
      if ((plane23 shr (7 - x)) and 1) != 0: index = index or 4
      if ((plane23 shr (15 - x)) and 1) != 0: index = index or 8
    if bpp == 8:
      if ((plane45 shr (7 - x)) and 1) != 0: index = index or 0x10
      if ((plane45 shr (15 - x)) and 1) != 0: index = index or 0x20
      if ((plane67 shr (7 - x)) and 1) != 0: index = index or 0x40
      if ((plane67 shr (15 - x)) and 1) != 0: index = index or 0x80
    idx[x] = uint8(index)

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

proc bgLineSetup(snes: SnesBus, py: int, bg: int, sizeBits: var int,
                 chrBase: var int, hofs: var int, rowBase: var int, subY: var int) {.inline.} =
  ## Per-scanline constants of one BG layer: map size, char base, H scroll,
  ## the tilemap word index of this line's row (screen-Y already folded in)
  ## and the row within the tile.
  let scReg = snes.ppuRegs[0x07 + bg]
  let tilemapBase = ((scReg.int shr 2) shl 10) and 0x7FFF
  sizeBits = scReg.int and 3
  let chrReg = if bg < 2: snes.ppuRegs[0x0B] else: snes.ppuRegs[0x0C]
  let chrShift = if bg mod 2 == 0: chrReg.int and 0x0F
                 else: (chrReg.int shr 4) and 0x0F
  chrBase = (chrShift shl 12) and 0x7FFF
  hofs = snes.bgScroll[bg * 2].int
  let vofs = snes.bgScroll[bg * 2 + 1].int
  let wy = py + vofs
  let ty = wy shr 3
  subY = wy and 7
  let screenY = if (sizeBits and 2) != 0: (ty shr 5) and 1 else: 0
  rowBase = tilemapBase + screenY * (if sizeBits == 3: 0x800 else: 0x400) + (ty and 31) * 32

proc bgScanlineInto(snes: SnesBus, buf: var openArray[ColorRGBA],
                    drawn: var openArray[bool], py: int, bg: int, bpp: int,
                    paletteBase: int, prio: int = -1) =
  ## Fill a 256-wide line buffer with one BG layer's pixels for scanline py,
  ## marking which pixels were opaque. Honors latched scroll and map size.
  ## prio filters by the tilemap per-tile priority bit (0x2000): -1 = all
  ## tiles, 0 = low-priority tiles only, 1 = high-priority tiles only. Used to
  ## split a layer across the priority order (e.g. BG3-priority menus).
  ## Works one tile run (up to 8 pixels) at a time: the map entry and the
  ## tile's plane words are read once per run.
  var sizeBits, chrBase, hofs, rowBase, subY: int
  snes.bgLineSetup(py, bg, sizeBits, chrBase, hofs, rowBase, subY)
  let colorsPerPal = 1 shl bpp
  var idx: array[8, uint8]
  var px = 0
  while px < ScreenWidth:
    let wx = px + hofs
    let tx = wx shr 3
    let sub = wx and 7
    let runLen = min(8 - sub, ScreenWidth - px)
    let screenX = if (sizeBits and 1) != 0: (tx shr 5) and 1 else: 0
    let entry = snes.vram[(rowBase + screenX * 0x400 + (tx and 31)) and 0x7FFF]
    if prio >= 0 and ((entry and 0x2000) != 0).int != prio:
      px += runLen
      continue
    let tile = (entry and 0x3FF).int
    let palBase = paletteBase + ((entry shr 10) and 0x07).int * colorsPerPal
    let flipX = (entry and 0x4000) != 0
    let sy = if (entry and 0x8000) != 0: 7 - subY else: subY
    snes.tileRowIndices(chrBase, tile, sy, bpp, idx)
    for i in 0 ..< runLen:
      let sx = if flipX: 7 - (sub + i) else: sub + i
      let index = idx[sx].int
      if index != 0:
        buf[px + i] = bgr555ToColor(snes.cgram[(palBase + index) and 0xFF])
        drawn[px + i] = true
    px += runLen

proc bgScanlineMask(snes: SnesBus, drawn: var openArray[bool], py: int, bg: int,
                    bpp: int, prio: int = -1) =
  ## Like bgScanlineInto but only records which pixels the layer would draw;
  ## no palette lookups. Same run/priority/flip logic.
  var sizeBits, chrBase, hofs, rowBase, subY: int
  snes.bgLineSetup(py, bg, sizeBits, chrBase, hofs, rowBase, subY)
  var idx: array[8, uint8]
  var px = 0
  while px < ScreenWidth:
    let wx = px + hofs
    let tx = wx shr 3
    let sub = wx and 7
    let runLen = min(8 - sub, ScreenWidth - px)
    let screenX = if (sizeBits and 1) != 0: (tx shr 5) and 1 else: 0
    let entry = snes.vram[(rowBase + screenX * 0x400 + (tx and 31)) and 0x7FFF]
    if prio >= 0 and ((entry and 0x2000) != 0).int != prio:
      px += runLen
      continue
    let tile = (entry and 0x3FF).int
    let flipX = (entry and 0x4000) != 0
    let sy = if (entry and 0x8000) != 0: 7 - subY else: subY
    snes.tileRowIndices(chrBase, tile, sy, bpp, idx)
    for i in 0 ..< runLen:
      let sx = if flipX: 7 - (sub + i) else: sub + i
      if idx[sx] != 0:
        drawn[px + i] = true
    px += runLen

iterator modeLayers(mode: int, bg3prio: bool): Layer =
  ## Back-to-front BG passes for a mode (see Mode*Layers). Modes other than
  ## 0, 1 and 3 yield nothing (backdrop only).
  case mode
  of 0:
    for l in Mode0Layers: yield l
  of 1:
    if bg3prio:
      for l in Mode1PrioLayers: yield l
    else:
      for l in Mode1Layers: yield l
  of 3:
    for l in Mode3Layers: yield l
  else:
    discard

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
  objColorMathLine: array[ScreenHeight, WindowLine]
    ## Per-scanline mask: pixels where color math is *allowed* by CGWSEL bits 5-4
    ## (always / inside / outside / never the color window). renderSprites must
    ## honor this — applying fixed-color subtract everywhere dims spotlighted
    ## sprites (Runaway Five, advantage win) that sit *inside* a math-outside
    ## window. Filled by renderScanline with live HDMA window edges.
  objSpritePrio: array[ScreenHeight, array[ScreenWidth, int8]]
    ## OBJ priority (0-3) of the sprite drawn at each pixel this frame, or -1 if
    ## none. Recorded by renderSprites; read by overlayForegroundBg to interleave
    ## high-priority BG tiles in front of the sprites they should cover.
  objLayerOffLine: array[ScreenHeight, bool]
    ## Per-scanline: the OBJ layer was enabled on NEITHER screen (TM $212C and
    ## TS $212D both had bit 4 clear) when the line was composited. Hardware
    ## shows no sprites there; without this gate, stale OAM entries render as a
    ## garbage blob when a scene runs BG-only (the Giygas praying cutscene runs
    ## TM=$04 with 8 sprites still parked mid-screen). Default false (= OBJ on)
    ## so legacy callers that skip renderScanline keep their sprites. Recorded
    ## per line because battle HDMA rewrites TM/TS mid-frame.
  anySpriteDrawn: bool
    ## True if renderSprites drew any pixel this frame (lets the foreground-BG
    ## overlay skip its passes entirely when nothing needs interleaving).
  anySpriteOnLine: array[ScreenHeight, bool]
    ## Per-scanline: renderSprites drew at least one pixel on this line, so the
    ## foreground-BG overlay only decodes tiles where an occlusion is possible.
  preSpriteComposite: array[ScreenHeight, array[ScreenWidth, ColorRGBA]]
    ## Snapshot of the fully color-math'd + brightness'd BG composite each pixel
    ## had *before* renderSprites clobbered it. Filled by renderScanline. When
    ## overlayForegroundBg redraws a foreground BG tile back in front of a sprite,
    ## it restores this instead of re-decoding a raw tile — so the occluding patch
    ## keeps the same color math (swirl/dim) as the rest of that object, and the
    ## seam between over-sprite and not-over-sprite pixels disappears.

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
                     backdrop: ColorRGBA, buf: var array[ScreenWidth, ColorRGBA],
                     drawn: var array[ScreenWidth, bool],
                     srcBit: var array[ScreenWidth, uint8]) =
  ## Composite one screen (main or sub) for scanline py: backdrop, then the
  ## mask-enabled BG layers of the current mode, back to front. `winReg` is the
  ## screen's window-disable register (TMW $212E for main, TSW $212F for sub):
  ## where a layer's window bit is set, the combined window area hides that
  ## layer for this scanline so lower layers / backdrop show through. This is
  ## what carves the scene-transition iris and clips the battle bands. With
  ## winReg = 0 (the common case) nothing is masked and output is unchanged.
  ##
  ## `srcBit[px]` is the CGADSUB layer bit of the topmost contributor:
  ## bit0 BG1 .. bit3 BG4, bit5 backdrop (matches $2131). Used so color math
  ## only applies to layers that enable it — without this, battle UI (BG1) was
  ## half-blended whenever BG3 math was on, so the animated BG looked "on top".
  let mode = (snes.ppuRegs[0x05] and 0x07).int
  let bg3prio = (snes.ppuRegs[0x05] and 0x08) != 0
  const BackdropMathBit = 0x20'u8  ## CGADSUB bit 5.
  for px in 0..<ScreenWidth:
    buf[px] = backdrop
    drawn[px] = false
    srcBit[px] = BackdropMathBit
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
    let layerBit = (1'u8 shl layer.bg)
    for px in 0..<ScreenWidth:
      if lineDrawn[px] and not (windowed and winHidden[px]):
        buf[px] = line[px]
        drawn[px] = true
        srcBit[px] = layerBit

proc clamp5(v: int): int =
  ## Clamp to a SNES 5-bit color channel (0..31).
  if v < 0: 0 elif v > 31: 31 else: v

proc expand5to8(v: int): uint8 =
  ## Expand a 5-bit SNES channel to 8-bit display (same as bgr555ToColor).
  uint8((v shl 3) or (v shr 2))

proc colorMathBlend*(main, sub: ColorRGBA; doSub, doHalf: bool): ColorRGBA =
  ## Apply SNES color math in the true 5-bit domain, then expand to 8-bit.
  ## Doing the add/sub in 8-bit after expansion (old path) oversaturates —
  ## mid-gray static + war card becomes a yellow/green mess during the Giygas
  ## intro fade. Hardware: (main ± sub), optional /2, clamp each channel 0..31.
  var r = main.r.int shr 3
  var g = main.g.int shr 3
  var b = main.b.int shr 3
  let sr = sub.r.int shr 3
  let sg = sub.g.int shr 3
  let sb = sub.b.int shr 3
  if doSub:
    r -= sr
    g -= sg
    b -= sb
  else:
    r += sr
    g += sg
    b += sb
  if doHalf:
    r = r div 2
    g = g div 2
    b = b div 2
  ColorRGBA(
    r: expand5to8(clamp5(r)),
    g: expand5to8(clamp5(g)),
    b: expand5to8(clamp5(b)),
    a: 255)

proc renderScanline*(snes: SnesBus, image: Image, py: int) =
  ## Render one fully composited scanline: main + subscreen color math +
  ## brightness, with window masking. Windows carve per-scanline regions: the
  ## layer windows (TMW/TSW) hide BG layers, and the color window (CGWSEL bits
  ## 7-4) forces the main screen black and gates where color math applies. This
  ## is the path that makes the scene-transition iris, the battle bands, and the
  ## Giygas red static (BG1 main + BG2 static subscreen, added) appear.
  let backdrop = bgr555ToColor(snes.cgram[0])
  let mainMask = snes.ppuRegs[0x2C]
  objLayerOffLine[py] = ((mainMask or snes.ppuRegs[0x2D]) and 0x10) == 0
  let cgadsub = snes.ppuRegs[0x31]
  let cgwsel = snes.ppuRegs[0x30]
  let mathLayers = cgadsub and 0x3F
  let doSub = (cgadsub and 0x80) != 0    # CGADSUB bit 7: 0=add, 1=subtract.
  let doHalf = (cgadsub and 0x40) != 0   # CGADSUB bit 6: halve the math result.
  let useSubScreen = (cgwsel and 0x02) != 0

  var mainBuf: array[ScreenWidth, ColorRGBA]
  var mainDrawn: array[ScreenWidth, bool]
  var mainSrc: array[ScreenWidth, uint8]
  snes.compositeScreen(py, mainMask, snes.ppuRegs[0x2E], backdrop, mainBuf,
                       mainDrawn, mainSrc)  # TMW.
  # SNES CGRAM/COLDATA pack is R in bits 0-4, G in 5-9, B in 10-14.
  let fixedColor = bgr555ToColor(snes.fixedColorR.uint16 or
    (snes.fixedColorG.uint16 shl 5) or (snes.fixedColorB.uint16 shl 10))
  var mathBuf: array[ScreenWidth, ColorRGBA]
  var subDrawn: array[ScreenWidth, bool]
  var subSrc: array[ScreenWidth, uint8]
  if mathLayers != 0:
    if useSubScreen:
      # Subscreen transparent pixels must math against the FIXED color (COLDATA),
      # not CGRAM $00. Using the main backdrop here made every hole in the Giygas
      # noise layer add cgram0 (often a non-black thrash color like $32AD) and
      # turn the "almost faded" static into a yellow/green mess.
      snes.compositeScreen(py, snes.ppuRegs[0x2D], snes.ppuRegs[0x2F], fixedColor,
                           mathBuf, subDrawn, subSrc)  # TSW + fixed as sub backdrop.
    else:
      for px in 0..<ScreenWidth:
        mathBuf[px] = fixedColor
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

  let inidisp = snes.ppuRegs[0x00]
  # TM=00 (main layers off via HDMA band) + subscreen (TS) layers + color math
  # enabled with subscreen operand (CGWSEL bit 1) + mathLayers (CGADSUB): output
  # the subscreen composite directly. This makes the bordered-battle HP/PP status
  # window (a subscreen BG) visible instead of flat backdrop.
  let showSubscreenDirect = (mainMask == 0'u8) and useSubScreen and
    (mathLayers != 0) and (snes.ppuRegs[0x2D] != 0'u8)
  let rowIdx = py * ScreenWidth
  for px in 0..<ScreenWidth:
    # CGWSEL bits 5-4 only (not layer enable): sprite pass reuses this so OBJ
    # fixed-color math is skipped inside spotlight windows (math-outside mode).
    let windowAllowsMath = case mathEnableMode
      of 1: colorWin[px]
      of 2: not colorWin[px]
      of 3: false
      else: true
    objColorMathLine[py][px] = windowAllowsMath
    var m: ColorRGBA
    if showSubscreenDirect:
      m = mathBuf[px]
      objSuppressLine[py][px] = false
    else:
      m = mainBuf[px]
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
      # Also require the *topmost main layer* to be in CGADSUB (hardware): UI on
      # BG1 must stay opaque when only BG3 has math enabled (borderless battles).
      let layerMath = (mathLayers and mainSrc[px]) != 0
      let mathHere = layerMath and windowAllowsMath
      if mathHere:
        let s = mathBuf[px]
        # Half only when the subscreen actually contributed a pixel (or when
        # the math operand is the fixed color). Matches prior half-gate.
        let half = doHalf and (useSubScreen and subDrawn[px] or not useSubScreen)
        m = colorMathBlend(m, s, doSub, half)
    let outPixel = applyMasterBrightness(m, inidisp)
    image.data[rowIdx + px] = toRgbx(outPixel)
    preSpriteComposite[py][px] = outPixel

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
    objSpritePrio[py] = NoSpriteRow
    anySpriteOnLine[py] = false
  anySpriteDrawn = false
  if (snes.ppuRegs[0x00] and 0x80) != 0:
    return  # force blank: nothing is displayed
  let inidisp = snes.ppuRegs[0x00]
  # OBJ color math: when CGADSUB enables OBJ (bit 4), sprites in palettes 4-7
  # take the same fixed-color add/subtract (+ optional half) as the BG layers —
  # so a world-wide darken (a subtract, e.g. the boss-intro dim) dims those
  # sprites too instead of leaving them full-bright. Only the fixed-color operand
  # is handled (the common global-dim case); subscreen-operand OBJ math is left
  # approximate. Per hardware, OBJ math applies only to OBJ palettes 4-7.
  let cgadsub = snes.ppuRegs[0x31]
  let objMath = (cgadsub and 0x10) != 0
  let objSub = (cgadsub and 0x80) != 0
  let objHalf = (cgadsub and 0x40) != 0
  let objUseFixed = (snes.ppuRegs[0x30] and 0x02) == 0
  let objFixed = bgr555ToColor(snes.fixedColorR.uint16 or
    (snes.fixedColorG.uint16 shl 5) or (snes.fixedColorB.uint16 shl 10))
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
  let nameGap = (((obsel.int shr 3) and 3) + 1) shl 12

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
    # Hardware: first drawn scanline is OAM Y+1; Y is 8-bit and wraps at 256 so
    # sprites with Y≈240..255 enter from the top (tree monkeys, etc.).
    # Linear Y (no wrap) only showed the lower half of a two-tile monkey
    # (upper sprite at Y=$FC vanished). Skip pure offscreen park: Y≥224 and
    # y+size≤256 (e.g. Y=$E0 size 32) — those only wrap a junk line onto 0.
    # See: https://snes.nesdev.org/wiki/Sprites
    if y >= ScreenHeight and y + size <= 256:
      continue

    var x = snes.oam[base].int or (xHigh.int shl 8)
    if x >= 256:
      x -= 512
    let pxStart = max(0, -x)
    let pxEnd = min(size, ScreenWidth - x)
    if pxStart >= pxEnd:
      continue
    let tile = snes.oam[base + 2].int
    let attr = snes.oam[base + 3]
    let prio = int((attr shr 4) and 0x03)
    let paletteGroup = (attr.int shr 1) and 0x07
    let table = (attr and 1).int
    let flipX = (attr and 0x40) != 0
    let flipY = (attr and 0x80) != 0
    let tileBase = (chrBase + table * nameGap) and 0x7FFF
    let objMathHere = objMath and objUseFixed and paletteGroup >= 4
    let palBase = 128 + paletteGroup * 16

    for py in 0..<size:
      let sy = if flipY: size - 1 - py else: py
      # +1: OAM Y is the scanline above the first visible sprite row; wrap at 256.
      let screenY = (y + py + 1) and 0xFF
      if screenY >= ScreenHeight:
        continue
      if objLayerOffLine[screenY]:
        continue   # OBJ layer disabled on both screens for this line (TM/TS).
      let tileRow = ((tile shr 4) + sy div 8) and 0x0F
      let rowIdx = screenY * ScreenWidth
      for px in pxStart ..< pxEnd:
        let sx = if flipX: size - 1 - px else: px
        let screenX = x + px
        if objSuppressActive[screenY] and objSuppressLine[screenY][screenX]:
          continue   # OBJ window / force-black hides sprites here (the iris).
        let tileCol = (tile + sx div 8) and 0x0F
        let tileIndex = tileRow * 16 + tileCol
        let index = snes.tilePixel(tileBase, tileIndex, sx mod 8, sy mod 8, 4)
        if index == 0:
          continue
        var color = bgr555ToColor(snes.cgram[palBase + index])
        # Gate on CGWSEL math window (objColorMathLine from renderScanline).
        # Without this, subtract-dim (swirl / stage lighting / advantage) applies
        # to every sprite pixel, including those inside a "math outside window"
        # spotlight — Runaway Five and similar look far too dark.
        if objMathHere and objColorMathLine[screenY][screenX]:
          color = colorMathBlend(color, objFixed, objSub, objHalf)
        image.data[rowIdx + screenX] = toRgbx(applyMasterBrightness(color, inidisp))
        objSpritePrio[screenY][screenX] = prio.int8
        anySpriteOnLine[screenY] = true
        anySpriteDrawn = true

proc overlayForegroundBg*(snes: SnesBus, image: Image) =
  ## Interleave HIGH-priority BG tiles in FRONT of the sprites they should cover,
  ## over the whole-frame sprite pass. The per-scanline composite already orders
  ## BG layers correctly, but sprites are a separate later pass, so without this
  ## every sprite sits on top of every BG.
  ##
  ## Mode 1: high-priority BG1/BG2 above OBJ 0-2 (trees over NPCs; dialogue over
  ## characters); BG3-high above OBJ 0, or all OBJ when $2105.3 (bg3prio) is set.
  ##
  ## Mode 0 (Earthbound battles / Goods inventory): same interleave for high
  ## BG1/BG2 (2bpp, palette sections 0/32). Battle enemy sprites commonly use
  ## OBJ priority 2; without this pass they paint over the command/Goods UI.
  ## (Strict fullsnes order puts OBJ2 above BG1.1; matching mode-1 liberality
  ## here is what makes battle menus readable — verified on user F12 states.)
  ##
  ## Only pixels where a sprite was drawn (objSpritePrio >= 0) are touched, so the
  ## full per-scanline composite (color math, windows, force-black) is preserved
  ## everywhere else. Call AFTER renderSprites.
  if not anySpriteDrawn: return
  if (snes.ppuRegs[0x00] and 0x80) != 0: return         # force blank
  let mode = snes.ppuRegs[0x05] and 0x07
  if mode != 0 and mode != 1: return
  let mainMask = snes.ppuRegs[0x2C].int
  let bg3prio = (snes.ppuRegs[0x05] and 0x08) != 0
  # High-priority BG passes, back to front: (bg, bpp, paletteBase, maxSpritePrio).
  var passes: array[4, tuple[bg, bpp, pal, maxPrio: int]]
  var passCount = 0
  case mode:
  of 0:
    # Mode 0: 2bpp layers, CGRAM sections 0/32/64/96 for BG1..BG4.
    if (mainMask and 0x02) != 0:
      passes[passCount] = (1, 2, 32, 2)    # BG2-high over OBJ 0-2.
      inc passCount
    if (mainMask and 0x01) != 0:
      passes[passCount] = (0, 2, 0, 2)     # BG1-high over OBJ 0-2 (battle UI).
      inc passCount
  of 1:
    if (mainMask and 0x04) != 0 and not bg3prio:
      passes[passCount] = (2, 2, 0, 0)     # BG3-high (no prio bit).
      inc passCount
    if (mainMask and 0x02) != 0:
      passes[passCount] = (1, 4, 0, 2)     # BG2-high.
      inc passCount
    if (mainMask and 0x01) != 0:
      passes[passCount] = (0, 4, 0, 2)     # BG1-high.
      inc passCount
    if (mainMask and 0x04) != 0 and bg3prio:
      passes[passCount] = (2, 2, 0, 3)     # BG3-high (prio bit): frontmost, over all OBJ.
      inc passCount
  else:
    discard
  var drawn: array[ScreenWidth, bool]
  for i in 0 ..< passCount:
    let p = passes[i]
    for py in 0..<ScreenHeight:
      if not anySpriteOnLine[py]:
        continue    # nothing to occlude on this line.
      for px in 0..<ScreenWidth:
        drawn[px] = false
      # `drawn[px]` flags where this high-priority tile exists; the correct
      # color-math'd pixel comes from preSpriteComposite.
      snes.bgScanlineMask(drawn, py, p.bg, p.bpp, 1)  # high tiles.
      let rowIdx = py * ScreenWidth
      for px in 0..<ScreenWidth:
        if not drawn[px]:
          continue
        let sp = objSpritePrio[py][px].int
        if sp < 0 or sp > p.maxPrio:
          continue    # no sprite here, or the sprite is in front of this BG.
        # Restore the pre-sprite composite (already color-math'd + brightness'd)
        # rather than re-decoding a raw tile — keeps swirl/dim tint over sprites
        # and removes the occlusion seam. See preSpriteComposite decl.
        image.data[rowIdx + px] = toRgbx(preSpriteComposite[py][px])

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

  # Whole-frame path has no HDMA-per-line history; clear OBJ suppress and fill
  # the color-math window mask from the *final* WH/CGWSEL so renderSprites still
  # gates fixed-color OBJ math (spotlight / dim) instead of reading stale lines.
  anySpriteDrawn = false
  let cgwselFrame = snes.ppuRegs[0x30]
  let mathEnableModeFrame = (cgwselFrame.int shr 4) and 0x03
  var colorWinFrame: WindowLine
  if mathEnableModeFrame != 0:
    let combine = (snes.ppuRegs[0x2B].int shr 2) and 0x03
    snes.windowAreaLine(snes.ppuRegs[0x25], 4, combine, colorWinFrame)
  for py in 0..<ScreenHeight:
    objSuppressActive[py] = false
    for px in 0..<ScreenWidth:
      objSpritePrio[py][px] = -1
      objColorMathLine[py][px] = case mathEnableModeFrame
        of 1: colorWinFrame[px]
        of 2: not colorWinFrame[px]
        of 3: false
        else: true

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
  # CGWSEL bit 1: 0 = fixed color operand, 1 = subscreen operand (matches renderScanline).
  let useSubScreen = (cgwsel and 0x02) != 0
  let fixedPx = bgr555ToColor(snes.fixedColorR.uint16 or
    (snes.fixedColorG.uint16 shl 5) or (snes.fixedColorB.uint16 shl 10))
  var subImg: Image = nil
  if (cgadsub and 0x3F) != 0 and (subMask != 0 or not useSubScreen):
    subImg = newImage(ScreenWidth, ScreenHeight)
    # Subscreen transparent = fixed color (COLDATA), not CGRAM $00.
    subImg.fill(fixedPx)
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

  # Color math: blend main with subscreen or fixed color where enabled.
  # This is what makes the red tv static overlay the war card (and giygas death).
  if (cgadsub and 0x3F) != 0:
    let doAdd = (cgadsub and 0x80) == 0    # CGADSUB bit 7: 0=add, 1=subtract
    let doHalf = (cgadsub and 0x40) != 0   # CGADSUB bit 6: halve the math result
    let objMathEnabled = (cgadsub and 0x10) != 0  # CGADSUB bit 4: OBJ layer enable for color math
    for i in 0 ..< result.data.len:
      var m = result.data[i]
      var s = if (not useSubScreen) or subImg == nil:
                fixedPx
              else:
                subImg.data[i]
      let y = i div ScreenWidth
      let x = i mod ScreenWidth
      if objSpritePrio[y][x] >= 0 and not objMathEnabled:
        # Gate OBJ color-math on (cgadsub & 0x10) != 0 for this frame.
        # When CGADSUB bit 4 (OBJ) not set, do not apply fixed math here:
        # sprites must render at NORMAL palette color, no tint.
        continue
      if objSpritePrio[y][x] >= 0:
        # Bit set: renderSprites already applied (gated) tint using live COLDATA;
        # skip here to prevent double application on sprite pixels.
        continue
      result.data[i] = colorMathBlend(m, s, not doAdd, doHalf)

  # Master brightness last (matches renderScanline): level 0 → true black.
  for i in 0 ..< result.data.len:
    result.data[i] = applyMasterBrightness(result.data[i], inidisp)
