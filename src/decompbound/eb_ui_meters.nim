## Original EarthBound battle HP/PP rolling-meter tiles and phase.
##
## Digit CHR is the gfx_lz stream at `$E00000` / file `0x200000`, decompressed
## by `$C41A9E` to `$7F0000` (`$C0B573`–`$C0B5AA`). VRAM tile `$200` is 2bpp
## byte offset `$1000` in that buffer (battle F12 BG1 tile `$200` at WRAM
## `$7F1000`). `$C20DC5` builds six tilemap words from the displayed integer
## and the fraction word; `$C20F08` is the HP helper (X=0) and `$C20F26` is
## the PP helper (X=1, hide via `$C20D89` when char+`$12` is nonzero).

import
  std/strformat,
  pixie,
  ./[gfx_lz, memmap]

type
  EbMeterAssets* = object
    ## Decompressed 2bpp meter tileset, indexed from VRAM tile `$100`.
    tiles*: seq[uint8]
    sourceSnes*: uint32
    sourceFile*: int
    consumed*: int

  EbMeterKind* = enum
    meterHp
    meterPp

const
  MeterGfxSnes* = 0xE00000'u32
  MeterGfxFile* = 0x200000
  DecompressEntrySnes* = 0xC41A9E'u32
  DecompressDestSnes* = 0x7F0000'u32
  HpHelperSnes* = 0xC20F08'u32
  PpHelperSnes* = 0xC20F26'u32
  DigitSplitSnes* = 0xC20D3F'u32
  MeterWriterSnes* = 0xC20DC5'u32
  PpHideSnes* = 0xC20D89'u32
  VisualUpdaterSnes* = 0xC213AC'u32
  StreamTileBase* = 0x0100
  DigitChr* = 0x0200
  BlankChr* = 0x0248
  PpHideChr* = 0x024C
  TilePriorityPal* = 0x2400
  TileRowStride* = 0x0010
  FractionFloor* = 0x3000
  FractionStep* = 0x3400
  MeterWordsBase* = 0x8969
  PpMeterWordsBase* = 0x8975
  SlotStride* = 24
  MeterStride* = 12
  BytesPerTile* = 16
  TilePx* = 8
  MeterPixelWidth* = 24
  MeterPixelHeight* = 16
  DigitCount* = 3
  PhaseCount* = 4
  MaxMeterValue* = 999
  TileIndexMask = 0x03FF
  PpHideFieldOff* = 0x12
  MinAtlasTiles = (BlankChr + TileRowStride) - StreamTileBase + 1

proc ebDigitTileBase*(digit: int): int =
  ## Tile index inside the 16-wide digit sheet for settled digit 0..9.
  ## `$C20E30`: `(d >> 2) << 4` plus `d << 2`.
  let d = digit mod 10
  if d < 0:
    raise newException(ValueError, &"meter digit {digit} is negative")
  d * 4 + (d shr 2) * 16

proc ebMeterPhase*(fraction: int): int =
  ## Rolling sub-frame 0..3 from the HP/PP fraction word at `$C20DC5`.
  ## Y < `$3000` is phase 0; else `(Y - $3000) / $3400` via `$C090FF`.
  let frac = fraction and 0xFFFF
  if frac < FractionFloor:
    result = 0
  else:
    result = (frac - FractionFloor) div FractionStep
    if result >= PhaseCount:
      result = PhaseCount - 1

proc ebMeterWords*(value, fraction: int): array[6, uint16] =
  ## Reproduce `$C20DC5`'s six tilemap words for one HP or shown PP meter.
  let
    amount = value and 0xFFFF
    ones = amount mod 10
    tens = (amount div 10) mod 10
    hundreds = (amount div 100) mod 10
    phase = ebMeterPhase(fraction)
  var tensPhase, hundredsPhase = 0
  if ones == 9 and phase != 0:
    tensPhase = phase
  if tens == 9 and tensPhase != 0:
    hundredsPhase = tensPhase
  let onesWord = uint16(ebDigitTileBase(ones) + phase + DigitChr + TilePriorityPal)
  var tensChr = DigitChr
  if tens == 0 and hundreds == 0:
    tensChr = BlankChr
  let tensWord = uint16(ebDigitTileBase(tens) + tensPhase + tensChr + TilePriorityPal)
  var hundredsChr = DigitChr
  if hundreds == 0:
    hundredsChr = BlankChr
  let hundredsWord = uint16(ebDigitTileBase(hundreds) + hundredsPhase +
    hundredsChr + TilePriorityPal)
  result[0] = hundredsWord
  result[1] = tensWord
  result[2] = onesWord
  result[3] = hundredsWord + TileRowStride.uint16
  result[4] = tensWord + TileRowStride.uint16
  result[5] = onesWord + TileRowStride.uint16

proc ebPpHidden*(conditionByte12: uint8): bool =
  ## True when `$C20F26` takes the `$C20D89` hide path.
  ## X is char+`$0E`; `LDA $0004,X` reads char+`$12` (condition group 4).
  ## TODO: name condition group 4 from independent status-table evidence.
  conditionByte12 != 0

proc ebPpHideWords*(): array[6, uint16] =
  ## Six PP tilemap words written by `$C20D89` when char+`$12` is nonzero.
  for column in 0 ..< DigitCount:
    let chr = PpHideChr + column
    result[column] = uint16(chr + TilePriorityPal)
    result[column + DigitCount] = uint16(chr + TileRowStride + TilePriorityPal)

proc loadEbMeterAssets*(rom: openArray[uint8]): EbMeterAssets =
  ## Decode the `$E00000` gfx_lz stream that `$C0B598` feeds to `$C41A9E`.
  let fileOff = snesToFile(MeterGfxSnes)
  if fileOff < 0 or fileOff >= rom.len:
    raise newException(ValueError, "meter graphics pointer is outside the ROM")
  if fileOff != MeterGfxFile:
    raise newException(ValueError,
      &"meter graphics file 0x{fileOff:06X} != 0x{MeterGfxFile:06X}")
  let hi = min(fileOff + 0x10000, rom.len)
  let (decoded, consumed, clean) = decodeWithConsumed(rom.toOpenArray(fileOff, hi - 1))
  if not clean:
    raise newException(ValueError, "meter graphics gfx_lz stream did not terminate")
  if decoded.len < MinAtlasTiles * BytesPerTile:
    raise newException(ValueError,
      &"meter graphics decoded {decoded.len} bytes, need {MinAtlasTiles * BytesPerTile}")
  result = EbMeterAssets(
    tiles: decoded,
    sourceSnes: MeterGfxSnes,
    sourceFile: fileOff,
    consumed: consumed)

proc ebMeterTileOffset*(vramTile: int): int =
  ## Byte offset of VRAM tile `vramTile` inside the decompressed `$7F0000` atlas.
  let local = vramTile - StreamTileBase
  if local < 0:
    raise newException(ValueError,
      &"meter tile ${vramTile:03X} is below stream base ${StreamTileBase:03X}")
  result = local * BytesPerTile

proc ebMeterTilePixel*(assets: EbMeterAssets, vramTile, x, y: int): int =
  ## 2bpp palette index 0..3 of one pixel in VRAM tile `vramTile`.
  if x < 0 or x >= TilePx or y < 0 or y >= TilePx:
    return 0
  let off = ebMeterTileOffset(vramTile)
  if off < 0 or off + BytesPerTile > assets.tiles.len:
    raise newException(ValueError,
      &"meter tile ${vramTile:03X} is outside the {assets.tiles.len}-byte atlas")
  let
    plane0 = assets.tiles[off + y * 2]
    plane1 = assets.tiles[off + y * 2 + 1]
    bit = 7 - x
  int((plane0 shr bit) and 1) or (int((plane1 shr bit) and 1) shl 1)

proc drawEbMeter*(image: Image, assets: EbMeterAssets, value, fraction, x, y: int,
    palette: array[4, ColorRGBA]) =
  ## Draw one 24×16 rolling HP/PP meter into `image` using `palette`.
  ## Color 0 is skipped when its alpha is 0. Windows, names, and status colors
  ## stay with the caller.
  let words = ebMeterWords(value, fraction)
  for row in 0 ..< 2:
    for column in 0 ..< DigitCount:
      let
        word = words[row * DigitCount + column]
        tile = int(word) and TileIndexMask
        px0 = x + column * TilePx
        py0 = y + row * TilePx
      for py in 0 ..< TilePx:
        let iy = py0 + py
        if iy < 0 or iy >= image.height:
          continue
        for px in 0 ..< TilePx:
          let ix = px0 + px
          if ix < 0 or ix >= image.width:
            continue
          let color = palette[assets.ebMeterTilePixel(tile, px, py)]
          if color.a == 0:
            continue
          image[ix, iy] = color
