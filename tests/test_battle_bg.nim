import
  std/[unittest],
  pixie,
  decompbound/[battle_bg, common, ppu, snesbus]

proc syntheticLayer(): BattleBgLayer =
  ## Build an authored striped tile with four synthetic palette colors.
  result = BattleBgLayer(id: 1, bpp: 2, chr: newSeq[uint8](16),
    arrangement: newSeq[uint16](1024), palette: newSeq[ColorRGBA](16))
  for y in 0 ..< 8: result.chr[y * 2] = 0xAA
  for color in result.palette.mitems: color = rgba(0, 0, 0, 255)
  result.palette[1] = rgba(255, 0, 0, 255)
  result.palette[2] = rgba(0, 255, 0, 255)
  result.palette[3] = rgba(0, 0, 255, 255)

proc slowScroll(segments: seq[ScrollSegment], frame: int): tuple[x, y: int] =
  ## Independently step the documented velocity/acceleration model for small fixtures.
  var index, local, x, y: int
  var vx = segments[0].hVel
  var vy = segments[0].vVel
  for _ in 0 ..< frame:
    vx += segments[index].hAccel
    vy += segments[index].vAccel
    x += vx
    y += vy
    inc local
    if segments[index].duration > 0 and local == segments[index].duration:
      index = (index + 1) mod segments.len
      local = 0
      vx = segments[index].hVel
      vy = segments[index].vVel
  result = (((x mod 65536 + 65536) mod 65536) div 256,
    ((y mod 65536 + 65536) mod 65536) div 256)

suite "Battle backgrounds without a ROM":
  test "scroll integration matches independent stepped finite and held segments":
    for segments in [
      @[ScrollSegment(duration: 3, hVel: 101, vVel: -256, hAccel: 33, vAccel: -7),
        ScrollSegment(duration: 4, hVel: -1000, vVel: 2, hAccel: -23)],
      @[ScrollSegment(duration: 3, hVel: 256),
        ScrollSegment(duration: 0, hVel: -256, hAccel: 11, vAccel: -55)]]:
      for frame in [0, 1, 2, 3, 4, 7, 8, 500, 3000]:
        check scrollOffsetAt(segments, frame) == slowScroll(segments, frame)
    let forever = @[ScrollSegment(hVel: 256)]
    check scrollOffsetAt(forever, 1_000_000_001).x == 1
    expect ValueError: discard scrollOffsetAt(forever, -1)

  test "palette animation is deterministic and does not mutate decoded assets":
    var layer = syntheticLayer()
    layer.palCycleType = 1
    layer.palCycleSpeed = 1
    layer.cycle1Start = 0
    layer.cycle1End = 3
    let background = BattleBg(layerA: 1, layers: @[layer])
    let first = renderFrame(background, 0)
    let changed = renderFrame(background, 2)
    let differs = first.data != changed.data
    check differs
    discard renderFrame(background, 31)
    check renderFrame(background, 0).data == first.data
    check background.layers[0].palette[1] == rgba(255, 0, 0, 255)

  test "tile flips and scrolling affect actual pixels":
    var layer = syntheticLayer()
    let unflipped = renderFrame(BattleBg(layers: @[layer]), 0)
    layer.arrangement[0] = 0x4000
    let flipped = renderFrame(BattleBg(layers: @[layer]), 0)
    check flipped[0, 0] == unflipped[7, 0]
    check flipped[7, 0] == unflipped[0, 0]
    layer.arrangement[0] = 0
    layer.scroll = @[ScrollSegment(hVel: 256)]
    check renderFrame(BattleBg(layers: @[layer]), 1)[0, 0] == unflipped[1, 0]

  test "reusable rendering matches allocated output and clears an empty background":
    let background = BattleBg(layers: @[syntheticLayer()])
    let output = newImage(256, 224)
    var workspace: BackgroundWorkspace
    renderInto(background, 15, output, workspace)
    check output.data == renderFrame(background, 15).data
    renderInto(BattleBg(), 0, output, workspace)
    check isBlank(output)
    check output[0, 0] == rgbx(0, 0, 0, 255)
    expect ValueError: renderInto(background, -1, output, workspace)

  test "invalid indexes and truncated ROM tables fail instead of producing empty success":
    let bytes = newSeq[uint8](EarthboundRomSize)
    check bgLayerPair(bytes, 0) == (0, 0)
    check bgCount(bytes) == 484
    for id in [-1, 484]:
      expect ValueError: discard bgLayerPair(bytes, id)
    expect ValueError: discard bgLayerPair(@[0'u8], 1)
    expect ValueError: discard decodeLayer(bytes, 0)
    expect ValueError: discard decodeLayer(bytes, 327)
  test "two-layer transparency agrees with an independent PPU render":
    let machine = newSnesBus(newSeq[uint8](0))
    machine.ppuRegs[0] = 15
    machine.ppuRegs[5] = 0x08
    machine.ppuRegs[9] = 0x5C
    machine.ppuRegs[10] = 0x0C
    machine.ppuRegs[12] = 0x31
    machine.ppuRegs[0x2C] = 0x04
    machine.ppuRegs[0x2D] = 0x08
    machine.ppuRegs[0x30] = 0x02
    machine.ppuRegs[0x31] = 0x64
    machine.cgram[65] = 0x001F
    machine.cgram[97] = 0x7C00
    machine.vram[0x1000] = 0x00C0
    machine.vram[0x3000] = 0x00A0
    var a = syntheticLayer()
    var b = syntheticLayer()
    a.chr[0] = 0xC0
    b.chr[0] = 0xA0
    b.palette[1] = rgba(0, 0, 255, 255)
    let
      background = BattleBg(layerA: 1, layerB: 2, layers: @[a, b])
      rendered = renderFrame(background, 0, 4, 1)
      reference = newImage(256, 224)
    machine.renderScanline(reference, 0)
    for x in 0 ..< 4: check rendered[x, 0] == reference[x, 0]
