import std/unittest

include ../src/decompbound/expanded_viewport

proc authoredView(width, height: int): ExpandedViewport =
  ## Construct a synthetic live scene with both planes, flips and logical-family boundaries.
  let layout = WorldMapLayout(arrangements: newSeq[uint16](MapColumns * MapRows),
    regions: newSeq[WorldMapRegion](RegionCount))
  for index in 0..<layout.regions.len:
    layout.regions[index].mapTilesetId = index and 1
  for index in 0..<layout.arrangements.len: layout.arrangements[index] = (index and 1).uint16
  let resource = WorldMapResource(graphics: newSeq[uint8](WorldChrBytes),
    arrangements: newSeq[array[WorldArrangementCells, uint16]](2))
  for tile in 0..<WorldChrTileCount:
    for y in 0..<8:
      for x in 0..<8:
        let value = (tile + x * 3 + y * 5) and 15
        for plane in 0..<4:
          if (value and (1 shl plane)) != 0:
            let address = tile * 32 + y * 2 + (plane div 2) * 16 + plane mod 2
            resource.graphics[address] = resource.graphics[address] or (1'u8 shl (7 - x))
  for arrangement in 0..1:
    for cell in 0..<WorldArrangementCells:
      let tile = [0, 1, WorldBg2TileCount - 1, WorldBg2TileCount,
        WorldChrTileCount - 1][(cell + arrangement) mod 5]
      resource.arrangements[arrangement][cell] = (tile or (((cell + arrangement) and 7) shl 10) or
        ((cell and 1) shl 13) or (((cell shr 1) and 1) shl 14) or
        (((cell shr 2) and 1) shl 15)).uint16
  result = ExpandedViewport(width: width, height: height,
    originX: (width - ScreenWidth) div 2, originY: (height - ScreenHeight) div 2,
    atlas: WorldMapAtlas(layout: layout), liveResource: resource,
    battle: newBattleViewport(width, height), captured: true, extended: true,
    output: newImage(width, height), spriteRaster: newExpandedSpriteRaster(width, height))
  result.registers[InidispReg] = 15
  result.registers[TmReg] = 3
  for index in 0..<256:
    result.liveColors[index] = bgr555ToColor(((index and 31) or
      (((index * 3) and 31) shl 5) or (((index * 7) and 31) shl 10)).uint16)
  result.resetLiveRowCache()
  result.prepareLiveColors()

proc checkMargins(view: ExpandedViewport, original: Image) =
  ## Compare every added pixel with the unchanged scalar sampler and preserve the center.
  let actual = view.compose(original)
  for y in 0..<view.height:
    for x in 0..<view.width:
      if x >= view.originX and x < view.originX + ScreenWidth and
          y >= view.originY and y < view.originY + ScreenHeight:
        doAssert actual[x, y] == original[x - view.originX, y - view.originY]
      else:
        let expected = view.sceneryPixel(view.cameraX + x - view.originX,
          view.cameraY + y - view.originY)
        doAssert actual[x, y] == expected,
          "Map span differed at " & $x & "," & $y & "; camera=" & $view.worldOrigin

suite "Expanded map span composition":
  test "odd spans retain both planes, flips, layer masks, brightness and signed positions":
    let
      view = authoredView(257, 225)
      original = newImage(ScreenWidth, ScreenHeight)
    original.fill(rgbx(71, 73, 79, 255))
    for (cameraX, cameraY) in [(-19, 0), (0, -7), (251, 125), (WorldWidth - 3, WorldHeight - 5)]:
      view.cameraX = cameraX
      view.cameraY = cameraY
      for mask in 0..3:
        view.registers[TmReg] = mask.uint8
        for brightness in [0'u8, 1, 7, 15]:
          view.registers[InidispReg] = brightness
          view.prepareLiveColors()
          doAssert view.mapSpanFastPath()
          view.checkMargins(original)
  test "ordinary presets paint all four margins with the scalar scene's exact colours":
    for (width, height) in [(320, 240), (336, 256), (448, 252), (512, 384)]:
      let
        view = authoredView(width, height)
        original = newImage(ScreenWidth, ScreenHeight)
      view.cameraX = -1
      view.cameraY = 3
      view.checkMargins(original)
  test "new snapshots invalidate decoded rows and refresh palette brightness":
    let
      view = authoredView(336, 256)
      original = newImage(ScreenWidth, ScreenHeight)
    view.checkMargins(original)
    var before = newSeq[ColorRGBX](view.output.data.len)
    copyMem(addr before[0], addr view.output.data[0], before.len * sizeof(ColorRGBX))
    for byte in view.liveResource.graphics.mitems: byte = byte xor 0xFF
    view.resetLiveRowCache()
    view.checkMargins(original)
    check before != view.output.data
    for color in view.liveColors.mitems: color = rgba(29, 59, 89, 255)
    view.registers[InidispReg] = 7
    view.prepareLiveColors()
    view.checkMargins(original)
  test "layer windows, colour math and force-black retain scalar composition":
    let
      view = authoredView(336, 256)
      original = newImage(ScreenWidth, ScreenHeight)
    for (register, value) in [(TmwReg, 1'u8), (CgadsubReg, 0x63'u8), (CgwselReg, 0x80'u8)]:
      let previous = view.registers[register]
      view.registers[register] = value
      view.registers[W12SelReg] = 0x33
      view.registers[Window1LeftReg] = 13
      view.registers[Window1LeftReg + 1] = 177
      doAssert not view.mapSpanFastPath()
      view.checkMargins(original)
      view.registers[register] = previous
