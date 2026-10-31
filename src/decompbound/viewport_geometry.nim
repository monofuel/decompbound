import
  std/strutils,
  ./ds_companion

type
  ViewportGeometry* = object
    width*, height*: int

const
  OriginalWidth* = 256
  OriginalHeight* = 224
  MaximumViewportDimension* = 1024
  ViewportWidthOption* = "decompbound_viewport_width"
  ViewportHeightOption* = "decompbound_viewport_height"
  PointerMaximum = 32767

proc viewportGeometry*(width = OriginalWidth, height = OriginalHeight): ViewportGeometry =
  ## Validate bounded experimental dimensions independently of physical displays.
  if width notin OriginalWidth .. MaximumViewportDimension or
      height notin OriginalHeight .. MaximumViewportDimension:
    raise newException(ValueError, "Viewport must be 256..1024 pixels wide and 224..1024 high.")
  ViewportGeometry(width: width, height: height)

proc expanded*(geometry: ViewportGeometry): bool =
  ## Report whether extra world pixels have been requested.
  geometry.width != OriginalWidth or geometry.height != OriginalHeight

proc outputHeight*(geometry: ViewportGeometry, dual: bool): int =
  ## Include the unchanged companion below the logical game viewport.
  geometry.height + (if dual: OriginalHeight else: 0)

proc dimensionOptions*(label: string, first: int): string =
  ## Advertise every supported integer to frontends with strict option validation.
  result = label & " (restart required); " & $first
  for value in first + 1 .. MaximumViewportDimension:
    result.add("|" & $value)

proc parseDimension*(value: string, first: int): int =
  ## Reject malformed dimensions rather than silently selecting a nearby preset.
  if value.len == 0 or value.find(AllChars - Digits) >= 0:
    raise newException(ValueError, "Viewport dimension must be a decimal integer.")
  result = parseInt(value)
  if result notin first .. MaximumViewportDimension:
    raise newException(ValueError, "Viewport dimension is outside its supported range.")

proc companionPointer*(geometry: ViewportGeometry, pointer: DsPointer): DsPointer =
  ## Translate full-frame libretro coordinates to the companion's legacy virtual frame.
  if not pointer.pressed: return
  let
    x = (pointer.x.int + PointerMaximum) * geometry.width div (PointerMaximum * 2)
    y = (pointer.y.int + PointerMaximum) * geometry.outputHeight(true) div (PointerMaximum * 2)
    left = (geometry.width - OriginalWidth) div 2
  if x < left or x >= left + OriginalWidth or
      y < geometry.height or y >= geometry.height + OriginalHeight:
    return
  result = DsPointer(
    x: (((x - left) * 2 + 1) * PointerMaximum div OriginalWidth - PointerMaximum).int16,
    y: (((y - geometry.height + OriginalHeight) * 2 + 1) * PointerMaximum div
      (OriginalHeight * 2) - PointerMaximum).int16,
    pressed: true)
