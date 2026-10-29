import
  ./eb_ui_status

type
  EbMeterTiles* = array[6, uint16]
  EbStatusTiles* = array[8, array[7, uint16]]
  EbGoodsFrame* = array[16, array[24, uint16]]

const
  TilePriority = 0x2000'u16
  FlipHorizontal = 0x4000'u16
  FlipVertical = 0x8000'u16
  PaletteShift = 10
  IncapacitatedFrame = 0x0C00'u16
  IncapacitatedMeter = 0x0800'u16
  NameTopTile = 0x02A0'u16
  NameBottomTile = 0x02B0'u16
  CornerTile = 4'u16
  HorizontalTile = 5'u16
  VerticalTile = 6'u16
  EmptyNameTop = 7'u16
  EmptyNameBottom = 0x17'u16
  NormalLabelPalette = 0x1000'u16
  TileRowStride = 0x10'u16

proc composeEbGoodsFrame*(nameLength: int): EbGoodsFrame =
  ## Reproduce a separate Goods window's border and header at original $C107AF.
  if nameLength notin 1 .. 5:
    raise newException(ValueError, "Invalid character name length for Goods window")
  const
    WindowAttributes = 0x3C00'u16
    WindowCorner = 0x10'u16
    WindowHorizontal = 0x11'u16
    WindowVertical = 0x12'u16
    HeaderSeam = 0x16'u16
    HeaderGlyph = 0x2E0'u16
  for column in 0 ..< result[0].len:
    let
      corner = column == 0 or column == result[0].high
      shape = if corner: WindowCorner else: WindowHorizontal
      flip = if column == result[0].high: FlipHorizontal else: 0'u16
    result[0][column] = WindowAttributes + shape + flip
    result[^1][column] = WindowAttributes + shape + flip + FlipVertical
  for row in 1 ..< result.high:
    result[row][0] = WindowAttributes + WindowVertical
    result[row][^1] = WindowAttributes + WindowVertical + FlipHorizontal
  let headerTiles = (nameLength * 6 + 7) div 8
  result[0][1] = WindowAttributes + HeaderSeam
  for column in 0 ..< headerTiles:
    result[0][column + 2] = TilePriority + HeaderGlyph + column.uint16
  result[0][headerTiles + 2] = WindowAttributes + HeaderSeam + FlipHorizontal

proc composeEbStatus*(tables: EbUiStatusTables, labels: array[8, uint8],
    memberId, nameLength: int, framePalette: uint16, conditions: EbConditions,
    hp, pp: EbMeterTiles): EbStatusTiles =
  ## Reproduce the eight-by-seven tile composition of original $C203C3.
  if memberId notin 1 .. 4 or nameLength notin 0 .. 5:
    raise newException(ValueError, "Invalid character for EarthBound status window")
  let
    border = framePalette + TilePriority
    incapacitated = framePalette == IncapacitatedFrame
    inside = if incapacitated: IncapacitatedFrame
      else: uint16(tables.conditionPalette(conditions) shl PaletteShift)
    nameTileCount = (nameLength * 6 + 9) div 8
    nameOffset = ((memberId - 1) * 4).uint16
    icon = tables.conditionIcon(conditions)
    iconOffset = icon + (icon and 0xFFF0'u16)
    meterOffset = if incapacitated: IncapacitatedMeter else: 0'u16
    labelPalette = if incapacitated: IncapacitatedFrame else: NormalLabelPalette
  for column in 0 .. 6:
    let tile = if column in [0, 6]: CornerTile else: HorizontalTile
    let flip = if column == 6: FlipHorizontal else: 0'u16
    result[0][column] = border + tile + flip
    result[7][column] = border + tile + flip + FlipVertical
  for row in 1 .. 6:
    result[row][0] = border + VerticalTile
    result[row][6] = border + VerticalTile + FlipHorizontal
  for column in 0 .. 3:
    result[1][column + 1] = inside + TilePriority +
      (if column < nameTileCount: NameTopTile + nameOffset + column.uint16 else: EmptyNameTop)
    result[2][column + 1] = inside + TilePriority +
      (if column < nameTileCount: NameBottomTile + nameOffset + column.uint16 else: EmptyNameBottom)
  result[1][5] = inside + TilePriority + iconOffset
  result[2][5] = inside + TilePriority + iconOffset + TileRowStride
  for row in 0 .. 3:
    for column in 0 .. 1:
      result[row + 3][column + 1] = labelPalette + TilePriority + labels[row * 2 + column].uint16
    for column in 0 .. 2:
      let tile = if row < 2: hp[row * 3 + column] else: pp[(row - 2) * 3 + column]
      result[row + 3][column + 3] = tile + meterOffset
