import
  std/[strutils, unittest],
  decompbound/[ds_companion, viewport_geometry]

proc pointerAt(x, y, width, height: int): DsPointer =
  ## Encode pixel centers in libretro's signed full-frame coordinate space.
  DsPointer(x: (((x * 2 + 1) * 32767 div width) - 32767).int16,
    y: (((y * 2 + 1) * 32767 div height) - 32767).int16, pressed: true)

suite "experimental viewport geometry":
  test "all presets and odd custom sizes preserve the companion":
    for (width, height) in [(256, 224), (320, 240), (336, 256),
        (448, 252), (512, 384), (257, 225), (1024, 1024)]:
      let geometry = viewportGeometry(width, height)
      check geometry.outputHeight(false) == height
      check geometry.outputHeight(true) == height + 224
      for (x, y) in [(0, 0), (255, 0), (0, 223), (255, 223), (127, 100)]:
        let
          input = pointerAt((width - 256) div 2 + x, height + y,
            width, geometry.outputHeight(true))
          actual = geometry.companionPointer(input)
        check actual.pressed
        check (actual.x.int + 32767) * 256 div 65534 == x
        check (actual.y.int + 32767) * 448 div 65534 - 224 == y
      check not geometry.companionPointer(pointerAt(0, 0, width,
        geometry.outputHeight(true))).pressed
      if width > 257:
        check not geometry.companionPointer(pointerAt(0, height, width,
          geometry.outputHeight(true))).pressed
      check not geometry.companionPointer(DsPointer()).pressed

  test "all advertised values are accepted without hidden rounding":
    let values = dimensionOptions("Width", 256).split("; ")[1].split('|')
    check values.len == 1024 - 256 + 1
    for value in values:
      check $parseDimension(value, 256) == value

  test "malformed and out of range values are rejected":
    for value in ["", "enabled", "-1", " 256", "256.0", "255", "1025"]:
      expect ValueError: discard parseDimension(value, 256)
    for (width, height) in [(255, 224), (256, 223), (1025, 224), (256, 1025)]:
      expect ValueError: discard viewportGeometry(width, height)
