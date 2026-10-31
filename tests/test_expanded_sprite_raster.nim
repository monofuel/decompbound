import
  std/[strformat, unittest],
  pixie,
  decompbound/[expanded_sprite_frame, expanded_sprite_raster, expanded_sprite_texture, ppu, snesbus]

const
  SyntheticRomBytes = 0x10000
  DisplayRegister = 0x00
  ObjectSelectionRegister = 0x01
  FullBrightness = 0x0F'u8
  ParkedOamY = 0xE0'u8
  TileWords = 16
  TileSide = 8
  NameTableTiles = 256
  ObjectPaletteBase = 128
  VramMask = 0x7FFF
  NativeSmallSizes = [8, 8, 8, 16, 16, 32, 16, 16]
  NativeLargeSizes = [16, 32, 64, 32, 64, 64, 32, 32]
    ## Independent OBSEL size table matching the native PPU, not the raster module.
  Sentinel = rgbx(12, 34, 56, 255)
  NativeSafeX = 40
  NativeSafeY = 48
  ExpandedWidth = 320
  ExpandedHeight = 240
  WideWidth = 512
  WideHeight = 512

proc machine(): SnesBus =
  ## Build authored blank hardware with full brightness and distinct OBJ palette colours.
  result = newSnesBus(newSeq[uint8](SyntheticRomBytes))
  result.ppuRegs[DisplayRegister] = FullBrightness
  for index in 0 .. 255:
    result.cgram[index] = uint16((index * 17) and 0x7FFF)

proc release(snes: SnesBus) =
  ## Break the synthetic machine's bus and APU closure cycles.
  snes.bus.readHook = nil
  snes.bus.writeHook = nil
  snes.apu.spc.readHook = nil
  snes.apu.spc.writeHook = nil

proc originX(width: int): int =
  ## Return the original 256-wide frame's left edge inside an expanded raster.
  (width - ScreenWidth) div 2

proc originY(height: int): int =
  ## Return the original 224-tall frame's top edge inside an expanded raster.
  (height - ScreenHeight) div 2

proc obselValue(chrNibble, nameSelect, sizeGroup: int): uint8 =
  ## Pack OBSEL: CHR word base nibble, name-table gap, and small/large size group.
  uint8((chrNibble and 7) or ((nameSelect and 3) shl 3) or ((sizeGroup and 7) shl 5))

proc chrBase(snes: SnesBus): int =
  ## Independent CHR word base from live OBSEL bits 0-2.
  ((snes.ppuRegs[ObjectSelectionRegister].int and 7) shl 13) and VramMask

proc nameGap(snes: SnesBus): int =
  ## Independent name-table gap in VRAM words from live OBSEL bits 3-4.
  (((snes.ppuRegs[ObjectSelectionRegister].int shr 3) and 3) + 1) shl 12

proc sizeGroup(snes: SnesBus): int =
  ## Independent OBSEL size-select field.
  (snes.ppuRegs[ObjectSelectionRegister].int shr 5) and 7

proc spriteSize(snes: SnesBus, large: bool): int =
  ## Resolve small or large pixel size from the independently authored OBSEL table.
  let group = snes.sizeGroup
  if large: NativeLargeSizes[group] else: NativeSmallSizes[group]

proc setObsel(snes: SnesBus, chrNibble = 0, nameSelect = 0, sizeGroup = 0) =
  ## Install one authored OBSEL combination.
  snes.ppuRegs[ObjectSelectionRegister] = obselValue(chrNibble, nameSelect, sizeGroup)

proc sprite(x, y, tile: int, attributes: uint8, large = false): ExpandedSpriteElement =
  ## Author one raster element in native origin space.
  ExpandedSpriteElement(x: x, y: y, tile: tile, attributes: attributes, large: large)

proc fillSolid(snes: SnesBus, base, tile, index: int) =
  ## Write one 4bpp tile as a uniform palette index using SNES plane layout.
  let
    low = (if (index and 1) != 0: 0x00FF'u16 else: 0'u16) or
      (if (index and 2) != 0: 0xFF00'u16 else: 0'u16)
    high = (if (index and 4) != 0: 0x00FF'u16 else: 0'u16) or
      (if (index and 8) != 0: 0xFF00'u16 else: 0'u16)
    address = (base + tile * TileWords) and VramMask
  for row in 0 ..< TileSide:
    snes.vram[address + row] = low
    snes.vram[(address + row + TileSide) and VramMask] = high

proc fillNameTable(snes: SnesBus, base, index: int) =
  ## Fill one 16-by-16 OBJ name table with a uniform 4bpp index.
  for tile in 0 ..< NameTableTiles:
    snes.fillSolid(base, tile, index)

proc putTexel(snes: SnesBus, base, tile, px, py, index: int) =
  ## Write one 4bpp texel into VRAM planes 0-3.
  let
    address = (base + tile * TileWords + py) and VramMask
    shift = TileSide - 1 - px
    lowBit = uint16(1 shl shift)
    highBit = uint16(1 shl (shift + 8))
  if (index and 1) != 0: snes.vram[address] = snes.vram[address] or lowBit
  else: snes.vram[address] = snes.vram[address] and not lowBit
  if (index and 2) != 0: snes.vram[address] = snes.vram[address] or highBit
  else: snes.vram[address] = snes.vram[address] and not highBit
  let highAddress = (address + TileSide) and VramMask
  if (index and 4) != 0: snes.vram[highAddress] = snes.vram[highAddress] or lowBit
  else: snes.vram[highAddress] = snes.vram[highAddress] and not lowBit
  if (index and 8) != 0: snes.vram[highAddress] = snes.vram[highAddress] or highBit
  else: snes.vram[highAddress] = snes.vram[highAddress] and not highBit

proc texel(snes: SnesBus, base, tile, px, py: int): int =
  ## Decode one 4bpp OBJ texel from authored VRAM independently of the raster.
  let
    address = (base + tile * TileWords + py) and VramMask
    shift = TileSide - 1 - px
    low = snes.vram[address]
    high = snes.vram[(address + TileSide) and VramMask]
  ((low.int shr shift) and 1) or (((low.int shr (shift + 8)) and 1) shl 1) or
    (((high.int shr shift) and 1) shl 2) or (((high.int shr (shift + 8)) and 1) shl 3)

proc uniqueIndex(px, py: int): int =
  ## Author a non-zero 4bpp index that still fits in one tile.
  1 + (px + py * TileSide) mod 15

proc fillUniqueTile(snes: SnesBus, base, tile: int) =
  ## Store a per-pixel pattern used to detect horizontal and vertical flips.
  for py in 0 ..< TileSide:
    for px in 0 ..< TileSide:
      snes.putTexel(base, tile, px, py, uniqueIndex(px, py))

proc publishOam(snes: SnesBus, elements: openArray[ExpandedSpriteElement]) =
  ## Install raster elements into native OAM using the hardware Y-plus-one encoding.
  for sprite in 0 ..< 128:
    snes.oam[sprite * 4] = 0
    snes.oam[sprite * 4 + 1] = ParkedOamY
    snes.oam[sprite * 4 + 2] = 0
    snes.oam[sprite * 4 + 3] = 0
  for i in 512 ..< 544:
    snes.oam[i] = 0
  for i, element in elements:
    snes.oam[i * 4] = (element.x and 255).uint8
    snes.oam[i * 4 + 1] = ((element.y - 1) and 255).uint8
    snes.oam[i * 4 + 2] = element.tile.uint8
    snes.oam[i * 4 + 3] = element.attributes
    let
      byteIndex = 512 + i div 4
      shift = (i mod 4) * 2
    var extra = snes.oam[byteIndex]
    if element.x < 0:
      extra = extra or (1'u8 shl shift)
    if element.large:
      extra = extra or (2'u8 shl shift)
    snes.oam[byteIndex] = extra

proc renderNative(snes: SnesBus): Image =
  ## Render the native 256x224 sprite pass over a sentinel backdrop.
  result = newImage(ScreenWidth, ScreenHeight)
  result.fill(Sentinel)
  snes.renderSprites(result)

proc rasterPixel(raster: ExpandedSpriteRaster, x, y: int): ExpandedSpritePixel =
  ## Read one stored object-plane pixel.
  raster.pixels[y * raster.width + x]

proc rasterColor(raster: ExpandedSpriteRaster, snes: SnesBus, x, y: int): ColorRGBX =
  ## Map a stored colour index through CGRAM the way composition does.
  let pixel = raster.rasterPixel(x, y)
  if pixel.colorIndex == 0:
    return Sentinel
  bgr555ToColor(snes.cgram[pixel.colorIndex]).rgbx

proc nativeParked(oamY, size: int): bool =
  ## Reproduce the native PPU's pure-offscreen Y skip independently.
  oamY >= ScreenHeight and oamY + size <= 256

proc compareOriginal(raster: ExpandedSpriteRaster, snes: SnesBus, native: Image) =
  ## Require the original 256x224 window to match native palette output.
  let
    left = originX(raster.width)
    top = originY(raster.height)
  for ny in 0 ..< ScreenHeight:
    for nx in 0 ..< ScreenWidth:
      let
        actual = raster.rasterColor(snes, left + nx, top + ny)
        expected = native[nx, ny]
      doAssert actual == expected,
        &"native mismatch at {nx},{ny}: raster {actual} native {expected}"

proc expectedOpaque(snes: SnesBus, element: ExpandedSpriteElement, px, py: int):
    tuple[index: uint8, attributes: uint8] =
  ## Independently sample one sprite-local texel after flips and 16-wide tile wrap.
  let
    size = snes.spriteSize(element.large)
    attributes = element.attributes.int
    sx = if (attributes and 0x40) != 0: size - 1 - px else: px
    sy = if (attributes and 0x80) != 0: size - 1 - py else: py
    tileColumn = (element.tile + sx div TileSide) and 15
    tileRow = ((element.tile shr 4) + sy div TileSide) and 15
    base = (snes.chrBase + (attributes and 1) * snes.nameGap) and VramMask
    index = snes.texel(base, tileRow * 16 + tileColumn, sx mod TileSide, sy mod TileSide)
  if index == 0:
    return (0'u8, 0'u8)
  let palette = ObjectPaletteBase + ((attributes shr 1) and 7) * 16
  (uint8(palette + index), element.attributes)

proc checkSpritePixels(raster: ExpandedSpriteRaster, snes: SnesBus,
    element: ExpandedSpriteElement) =
  ## Require every on-raster pixel of one element to match the independent texel oracle.
  let
    size = snes.spriteSize(element.large)
    left = element.x + originX(raster.width)
    top = element.y + originY(raster.height)
  for py in 0 ..< size:
    for px in 0 ..< size:
      let
        x = left + px
        y = top + py
      if x < 0 or x >= raster.width or y < 0 or y >= raster.height:
        continue
      let
        actual = raster.rasterPixel(x, y)
        expected = snes.expectedOpaque(element, px, py)
      if expected.index == 0:
        continue
      doAssert actual.colorIndex == expected.index,
        &"colorIndex at {x},{y}: {actual.colorIndex} != {expected.index}"
      doAssert actual.attributes == expected.attributes,
        &"attributes at {x},{y}: {actual.attributes} != {expected.attributes}"

proc checkUntouchedZero(raster: ExpandedSpriteRaster) =
  ## Require sparse storage: only touched slots may hold an opaque colour.
  var seen = newSeq[bool](raster.pixels.len)
  for index in raster.touched:
    doAssert index >= 0 and index < raster.pixels.len
    doAssert raster.pixels[index].colorIndex != 0
    seen[index] = true
  for index, pixel in raster.pixels:
    if not seen[index]:
      doAssert pixel.colorIndex == 0
      doAssert pixel.attributes == 0

proc drawAndCompare(raster: ExpandedSpriteRaster, snes: SnesBus,
    elements: openArray[ExpandedSpriteElement]) =
  ## Draw with the two-argument API and compare original-frame pixels to native PPU output.
  snes.publishOam(elements)
  let native = snes.renderNative()
  raster.draw(snes, elements)
  raster.checkUntouchedZero()
  raster.compareOriginal(snes, native)

suite "expanded sprite raster":
  test "private texture words stay actor-local and untouched words use native VRAM":
    let snes = machine()
    defer: snes.release()
    snes.setObsel()
    snes.fillSolid(0, 0, 2)
    let
      before = snes.vram
      raster = newExpandedSpriteRaster(ScreenWidth, ScreenHeight)
      patch = SpriteTexturePatch(firstWord: 0,
        words: @[0x00FF'u16, 0xFFFF], present: @[true, false])
      nativeElement = sprite(40, 48, 0, 0x02)
    var privateElement = nativeElement
    privateElement.texture = 1
    snes.vram[0] = patch.words[0]
    snes.publishOam([privateElement])
    let expected = snes.renderNative()
    snes.vram = before
    raster.draw(snes, [privateElement], @[patch])
    raster.compareOriginal(snes, expected)
    doAssert snes.vram == before
    doAssert raster.rasterPixel(40, 48).colorIndex == ObjectPaletteBase + 16 + 1
    doAssert raster.rasterPixel(40, 49).colorIndex == ObjectPaletteBase + 16 + 2
    raster.draw(snes, [nativeElement])
    doAssert raster.rasterPixel(40, 48).colorIndex == ObjectPaletteBase + 16 + 2

  test "small and large sizes for every OBSEL group match native palette output":
    let snes = machine()
    defer: snes.release()
    let raster = newExpandedSpriteRaster(ScreenWidth, ScreenHeight)
    for group in 0 .. 7:
      snes.setObsel(sizeGroup = group)
      snes.fillNameTable(snes.chrBase, 1)
      for large in [false, true]:
        let
          size = snes.spriteSize(large)
          element = sprite(NativeSafeX, NativeSafeY, 0, 0x02, large)
        raster.drawAndCompare(snes, [element])
        raster.checkSpritePixels(snes, element)
        let
          left = NativeSafeX
          top = NativeSafeY
          pixel = raster.rasterPixel(left, top)
        doAssert pixel.colorIndex == uint8(ObjectPaletteBase + 16 + 1)
        doAssert pixel.attributes == 0x02
        if left > 0:
          doAssert raster.rasterPixel(left - 1, top).colorIndex == 0
        if top > 0:
          doAssert raster.rasterPixel(left, top - 1).colorIndex == 0
        if left + size < raster.width:
          doAssert raster.rasterPixel(left + size, top).colorIndex == 0
        if top + size < raster.height:
          doAssert raster.rasterPixel(left, top + size).colorIndex == 0

  test "horizontal, vertical, and both flips match native and the texel oracle":
    let snes = machine()
    defer: snes.release()
    snes.setObsel()
    snes.fillUniqueTile(snes.chrBase, 0)
    let raster = newExpandedSpriteRaster(ScreenWidth, ScreenHeight)
    let
      x = NativeSafeX
      y = NativeSafeY
    let unflipped = sprite(x, y, 0, 0x00)
    raster.drawAndCompare(snes, [unflipped])
    raster.checkSpritePixels(snes, unflipped)
    let
      c00 = raster.rasterPixel(x, y).colorIndex
      c70 = raster.rasterPixel(x + 7, y).colorIndex
      c07 = raster.rasterPixel(x, y + 7).colorIndex
      c77 = raster.rasterPixel(x + 7, y + 7).colorIndex
    doAssert c00 != c70 and c00 != c07 and c00 != c77
    for attributes in [0x40'u8, 0x80'u8, 0xC0'u8]:
      let element = sprite(x, y, 0, attributes)
      raster.drawAndCompare(snes, [element])
      raster.checkSpritePixels(snes, element)
      let
        actual00 = raster.rasterPixel(x, y).colorIndex
        actual70 = raster.rasterPixel(x + 7, y).colorIndex
        actual07 = raster.rasterPixel(x, y + 7).colorIndex
        actual77 = raster.rasterPixel(x + 7, y + 7).colorIndex
      case attributes
      of 0x40:
        doAssert actual00 == c70 and actual70 == c00
        doAssert actual07 == c77 and actual77 == c07
      of 0x80:
        doAssert actual00 == c07 and actual07 == c00
        doAssert actual70 == c77 and actual77 == c70
      else:
        doAssert actual00 == c77 and actual77 == c00
        doAssert actual70 == c07 and actual07 == c70

  test "tile low-nibble wrapping samples the wrapped name-table column":
    let snes = machine()
    defer: snes.release()
    snes.setObsel(sizeGroup = 0)
    snes.fillSolid(snes.chrBase, 0x0F, 5)
    snes.fillSolid(snes.chrBase, 0x00, 9)
    let
      raster = newExpandedSpriteRaster(ScreenWidth, ScreenHeight)
      element = sprite(NativeSafeX, NativeSafeY, 0x0F, 0x04, large = true)
    raster.drawAndCompare(snes, [element])
    raster.checkSpritePixels(snes, element)
    doAssert raster.rasterPixel(NativeSafeX, NativeSafeY).colorIndex ==
      uint8(ObjectPaletteBase + 32 + 5)
    doAssert raster.rasterPixel(NativeSafeX + 8, NativeSafeY).colorIndex ==
      uint8(ObjectPaletteBase + 32 + 9)

  test "tile row wrapping samples the wrapped name-table row":
    let snes = machine()
    defer: snes.release()
    snes.setObsel(sizeGroup = 0)
    snes.fillSolid(snes.chrBase, 0xF0, 3)
    snes.fillSolid(snes.chrBase, 0x00, 11)
    let
      raster = newExpandedSpriteRaster(ScreenWidth, ScreenHeight)
      element = sprite(NativeSafeX, NativeSafeY, 0xF0, 0x06, large = true)
    raster.drawAndCompare(snes, [element])
    raster.checkSpritePixels(snes, element)
    doAssert raster.rasterPixel(NativeSafeX, NativeSafeY).colorIndex ==
      uint8(ObjectPaletteBase + 48 + 3)
    doAssert raster.rasterPixel(NativeSafeX, NativeSafeY + 8).colorIndex ==
      uint8(ObjectPaletteBase + 48 + 11)

  test "both CHR name tables and a non-zero CHR base match native":
    let snes = machine()
    defer: snes.release()
    snes.setObsel(chrNibble = 2, nameSelect = 1)
    let
      first = snes.chrBase
      second = (first + snes.nameGap) and VramMask
    snes.fillSolid(first, 1, 7)
    snes.fillSolid(second, 1, 12)
    let
      raster = newExpandedSpriteRaster(ScreenWidth, ScreenHeight)
      table0 = sprite(16, NativeSafeY, 1, 0x08)
      table1 = sprite(32, NativeSafeY, 1, 0x09)
    raster.drawAndCompare(snes, [table0, table1])
    raster.checkSpritePixels(snes, table0)
    raster.checkSpritePixels(snes, table1)
    doAssert raster.rasterPixel(16, NativeSafeY).colorIndex ==
      uint8(ObjectPaletteBase + 64 + 7)
    doAssert raster.rasterPixel(32, NativeSafeY).colorIndex ==
      uint8(ObjectPaletteBase + 64 + 12)

  test "transparent texels drop through and earliest OAM wins over attr priority":
    let snes = machine()
    defer: snes.release()
    snes.setObsel()
    for py in 0 ..< TileSide:
      for px in 0 ..< TileSide:
        let index = if ((px + py) and 1) == 0: 0 else: 2
        snes.putTexel(snes.chrBase, 0, px, py, index)
    snes.fillSolid(snes.chrBase, 1, 4)
    let
      front = sprite(NativeSafeX, NativeSafeY, 0, 0x02)
      back = sprite(NativeSafeX + 2, NativeSafeY + 2, 1, 0x34)
      raster = newExpandedSpriteRaster(ScreenWidth, ScreenHeight)
    raster.drawAndCompare(snes, [front, back])
    let
      frontOpaque = raster.rasterPixel(NativeSafeX + 1, NativeSafeY)
      overlapFront = raster.rasterPixel(NativeSafeX + 3, NativeSafeY + 2)
      overlapBack = raster.rasterPixel(NativeSafeX + 2, NativeSafeY + 2)
      backOnly = raster.rasterPixel(NativeSafeX + 9, NativeSafeY + 9)
    doAssert frontOpaque.colorIndex == uint8(ObjectPaletteBase + 16 + 2)
    doAssert frontOpaque.attributes == 0x02
    doAssert overlapFront.colorIndex == uint8(ObjectPaletteBase + 16 + 2)
    doAssert overlapFront.attributes == 0x02
    doAssert overlapBack.colorIndex == uint8(ObjectPaletteBase + 32 + 4)
    doAssert overlapBack.attributes == 0x34
    doAssert backOnly.colorIndex == uint8(ObjectPaletteBase + 32 + 4)
    doAssert backOnly.attributes == 0x34

  test "signed positions and seam extents occupy expanded margins without wrapping":
    let snes = machine()
    defer: snes.release()
    snes.setObsel()
    snes.fillNameTable(snes.chrBase, 1)
    let
      raster = newExpandedSpriteRaster(ExpandedWidth, ExpandedHeight)
      left = originX(ExpandedWidth)
      top = originY(ExpandedHeight)
      pal5 = uint8(ObjectPaletteBase + 80 + 1)
      pal6 = uint8(ObjectPaletteBase + 96 + 1)
      pal7 = uint8(ObjectPaletteBase + 112 + 1)
      pal0 = uint8(ObjectPaletteBase + 1)
    raster.draw(snes, [sprite(-8, NativeSafeY, 0, 0x0A)])
    raster.checkUntouchedZero()
    doAssert raster.rasterPixel(left - 8, top + NativeSafeY).colorIndex == pal5
    doAssert raster.rasterPixel(left - 1, top + NativeSafeY).colorIndex == pal5
    doAssert raster.rasterPixel(left, top + NativeSafeY).colorIndex == 0
    raster.draw(snes, [sprite(ScreenWidth - 4, NativeSafeY, 0, 0x0C)])
    doAssert raster.rasterPixel(left + ScreenWidth - 4, top + NativeSafeY).colorIndex == pal6
    doAssert raster.rasterPixel(left + ScreenWidth + 3, top + NativeSafeY).colorIndex == pal6
    doAssert raster.rasterPixel(left, top + NativeSafeY).colorIndex == 0
    raster.draw(snes, [sprite(NativeSafeX, -4, 0, 0x0E)])
    doAssert raster.rasterPixel(left + NativeSafeX, top - 4).colorIndex == pal7
    doAssert raster.rasterPixel(left + NativeSafeX, top + 3).colorIndex == pal7
    doAssert raster.rasterPixel(left + NativeSafeX, top + ScreenHeight - 1).colorIndex == 0
    raster.draw(snes, [sprite(NativeSafeX, ScreenHeight - 4, 0, 0x00)])
    doAssert raster.rasterPixel(left + NativeSafeX, top + ScreenHeight - 4).colorIndex == pal0
    doAssert raster.rasterPixel(left + NativeSafeX, top + ScreenHeight + 3).colorIndex == pal0
    doAssert raster.rasterPixel(left + NativeSafeX, top).colorIndex == 0

  test "parked native Y does not wrap onto the original frame":
    let snes = machine()
    defer: snes.release()
    snes.setObsel(sizeGroup = 1)
    snes.fillNameTable(snes.chrBase, 1)
    let
      size = NativeLargeSizes[1]
      elementY = 241
      oamY = elementY - 1
      raster = newExpandedSpriteRaster(WideWidth, WideHeight)
      element = sprite(NativeSafeX, elementY, 0, 0x02, large = true)
      left = originX(WideWidth)
      top = originY(WideHeight)
    doAssert not nativeParked(oamY, size)
    raster.draw(snes, [element])
    raster.checkUntouchedZero()
    raster.checkSpritePixels(snes, element)
    doAssert raster.rasterPixel(left + NativeSafeX, top + elementY).colorIndex ==
      uint8(ObjectPaletteBase + 16 + 1)
    for ny in 0 ..< ScreenHeight:
      for nx in 0 ..< ScreenWidth:
        doAssert raster.rasterPixel(left + nx, top + ny).colorIndex == 0,
          &"wrapped original pixel at {nx},{ny}"
    snes.publishOam([element])
    let native = snes.renderNative()
    var nativeDrew = false
    for ny in 0 ..< ScreenHeight:
      for nx in 0 ..< ScreenWidth:
        if native[nx, ny] != Sentinel:
          nativeDrew = true
    doAssert nativeDrew
    doAssert native[NativeSafeX, 0] != Sentinel

  test "sparse clear removes prior opaque pixels and empties touched":
    let snes = machine()
    defer: snes.release()
    snes.setObsel()
    snes.fillNameTable(snes.chrBase, 1)
    let
      raster = newExpandedSpriteRaster(ScreenWidth, ScreenHeight)
      first = sprite(10, 20, 0, 0x02)
      second = sprite(80, 90, 0, 0x04)
    raster.draw(snes, [first])
    doAssert raster.rasterPixel(10, 20).colorIndex != 0
    doAssert raster.touched.len > 0
    let previousTouched = raster.touched.len
    raster.draw(snes, [second])
    doAssert raster.rasterPixel(10, 20).colorIndex == 0
    doAssert raster.rasterPixel(10, 20).attributes == 0
    doAssert raster.rasterPixel(80, 90).colorIndex == uint8(ObjectPaletteBase + 32 + 1)
    doAssert raster.touched.len > 0
    doAssert raster.touched.len <= previousTouched
    raster.checkUntouchedZero()
    raster.clear()
    doAssert raster.touched.len == 0
    doAssert raster.rasterPixel(80, 90).colorIndex == 0
    raster.draw(snes, newSeq[ExpandedSpriteElement]())
    doAssert raster.touched.len == 0
    for pixel in raster.pixels:
      doAssert pixel.colorIndex == 0
