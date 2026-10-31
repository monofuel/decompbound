import
  ./[expanded_sprite_frame, expanded_sprite_texture, snesbus, viewport_geometry]

type
  ExpandedSpritePixel* = object
    ## Retain an opaque object palette index and its native attributes until composition.
    colorIndex*, attributes*: uint8
  ExpandedSpriteRaster* = ref object
    ## Rasterize unwrapped sprite elements into reusable, sparsely cleared storage.
    width*, height*: int
    originX, originY: int
    pixels*: seq[ExpandedSpritePixel]
    touched*: seq[int]

const
  SmallSizes = [8, 8, 8, 16, 16, 32, 16, 16]
  LargeSizes = [16, 32, 64, 32, 64, 64, 32, 32]
    ## Match the native PPU's supported OBSEL size interpretation.
  ObjectSelectionRegister = 0x01
  VramMask = 0x7FFF
  TileWords = 16
  TileSide = 8
  ObjectPaletteBase = 128

proc newExpandedSpriteRaster*(width, height: int): ExpandedSpriteRaster =
  ## Allocate one viewport-sized object plane with the original frame centered.
  discard viewportGeometry(width, height)
  ExpandedSpriteRaster(width: width, height: height,
    originX: (width - OriginalWidth) div 2,
    originY: (height - OriginalHeight) div 2,
    pixels: newSeq[ExpandedSpritePixel](width * height))

proc clear*(raster: ExpandedSpriteRaster) =
  ## Clear only pixels touched by the previous sprite frame, retaining allocation capacity.
  for index in raster.touched:
    raster.pixels[index] = ExpandedSpritePixel()
  raster.touched.setLen(0)

proc textureWord(snes: SnesBus, texture: SpriteTexturePatch, address: int): uint16 {.inline.} =
  ## Read private replacement words, retaining native VRAM for untouched locations.
  let offset = (address and VramMask) - (if texture == nil: 0 else: texture.firstWord)
  if texture != nil and offset >= 0 and offset < texture.words.len and texture.present[offset]:
    texture.words[offset]
  else:
    snes.vram[address and VramMask]

proc pixelIndex(snes: SnesBus, texture: SpriteTexturePatch, base, tile, x, y: int): int {.inline.} =
  ## Decode a four-plane OBJ texel from the currently displayed VRAM.
  let
    address = base + tile * TileWords + y
    low = snes.textureWord(texture, address)
    high = snes.textureWord(texture, address + TileSide)
    shift = TileSide - 1 - x
  ((low.int shr shift) and 1) or (((low.int shr (shift + 8)) and 1) shl 1) or
    (((high.int shr shift) and 1) shl 2) or (((high.int shr (shift + 8)) and 1) shl 3)

proc draw*(raster: ExpandedSpriteRaster, snes: SnesBus,
    elements: openArray[ExpandedSpriteElement], textures: seq[SpriteTexturePatch] = @[]) =
  ## Preserve native submission precedence while drawing full signed coordinates.
  raster.clear()
  let
    selection = snes.ppuRegs[ObjectSelectionRegister].int
    sizeGroup = (selection shr 5) and 7
    chrBase = ((selection and 7) shl 13) and VramMask
    nameGap = (((selection shr 3) and 3) + 1) shl 12
  for elementIndex in countdown(elements.high, 0):
    let
      element = elements[elementIndex]
      texture = if element.texture > 0 and element.texture <= textures.len:
          textures[element.texture - 1]
        else: nil
      size = if element.large: LargeSizes[sizeGroup] else: SmallSizes[sizeGroup]
      left = element.x + raster.originX
      top = element.y + raster.originY
      firstX = max(0, -left)
      lastX = min(size, raster.width - left)
      firstY = max(0, -top)
      lastY = min(size, raster.height - top)
    if firstX >= lastX or firstY >= lastY: continue
    let
      attributes = element.attributes.int
      base = (chrBase + (attributes and 1) * nameGap) and VramMask
      palette = ObjectPaletteBase + ((attributes shr 1) and 7) * 16
      flipX = (attributes and 0x40) != 0
      flipY = (attributes and 0x80) != 0
    for py in firstY ..< lastY:
      let
        sy = if flipY: size - 1 - py else: py
        tileRow = ((element.tile shr 4) + sy div TileSide) and 15
        row = (top + py) * raster.width
      for px in firstX ..< lastX:
        let
          sx = if flipX: size - 1 - px else: px
          tileColumn = (element.tile + sx div TileSide) and 15
          index = snes.pixelIndex(texture, base, tileRow * 16 + tileColumn,
            sx mod TileSide, sy mod TileSide)
        if index == 0: continue
        let target = row + left + px
        if raster.pixels[target].colorIndex == 0: raster.touched.add(target)
        raster.pixels[target] = ExpandedSpritePixel(colorIndex: (palette + index).uint8,
          attributes: element.attributes)
