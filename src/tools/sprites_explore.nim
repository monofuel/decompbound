## EarthBound graphics explorer (headless PNG dumper).
## Decodes compressed graphic via gfx_lz at a ROM file offset, interprets the
## decompressed bytes as a stream of 2bpp or 4bpp SNES planar tiles, applies a
## CGRAM-style palette, and renders a tile sheet to a PNG. bin/ output is
## gitignored per copyright rules — never commit decoded graphics.
## Usage for "browsing": re-run with different --offset/--bpp/--wide to step and
## explore variants. (Silky UI browser is the intended future for this stub.)

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[gfx_lz, ppu]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultOutDir = "bin"

proc readRom(path: string): seq[uint8] =
  ## Read ROM bytes, stripping a leading 512-byte copier header if present.
  if not fileExists(path):
    stderr.writeLine &"ROM not found: {path}"
    quit(1)
  let data = readFile(path)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc extractCompressed(rom: seq[uint8], off: int): seq[uint8] =
  ## Extract the compressed stream starting at off, up to and including 0xFF.
  result = @[]
  var j = off
  while j < rom.len:
    let b = rom[j]
    result.add(b)
    j += 1
    if b == 0xFFu8:
      break

proc tilePixelFromBytes(chr: seq[uint8], tile: int, x: int, y: int, bpp: int): int =
  ## Decode a single pixel (0..(1<<bpp)-1) from planar tile bytes in the
  ## decompressed stream. Layout matches ppu.tilePixel: per-row low-byte=plane0,
  ## high-byte=plane1 (and planes 2/3 at +16 bytes for 4bpp).
  let bytesPerTile = bpp * 8
  let base = tile * bytesPerTile
  if base + bytesPerTile > chr.len or x < 0 or x > 7 or y < 0 or y > 7:
    return 0
  var index = 0
  let p0 = chr[base + y * 2 + 0]
  let p1 = chr[base + y * 2 + 1]
  let plane01 = (uint16(p1) shl 8) or uint16(p0)
  if ((plane01 shr (7 - x)) and 1'u16) != 0:
    index = index or 1
  if ((plane01 shr (15 - x)) and 1'u16) != 0:
    index = index or 2
  if bpp >= 4:
    let p2 = chr[base + 16 + y * 2 + 0]
    let p3 = chr[base + 16 + y * 2 + 1]
    let plane23 = (uint16(p3) shl 8) or uint16(p2)
    if ((plane23 shr (7 - x)) and 1'u16) != 0:
      index = index or 4
    if ((plane23 shr (15 - x)) and 1'u16) != 0:
      index = index or 8
  result = index

proc makePalette(n: int, style: string): seq[ColorRGBA] =
  ## Build a CGRAM-style palette of n colors. Index 0 is a dark placeholder.
  ## Uses ppu.bgr555ToColor for a couple of reference entries; otherwise
  ## ramps or simple spread for visibility in the absence of the real CGRAM.
  result = newSeq[ColorRGBA](n)
  result[0] = ColorRGBA(r: 20, g: 20, b: 32, a: 255)
  if n > 1:
    result[1] = ppu.bgr555ToColor(0x7FFF'u16)
  if n > 2:
    result[2] = ppu.bgr555ToColor(0x001F'u16)
  if n > 3:
    result[3] = ppu.bgr555ToColor(0x03E0'u16)
  if style == "color":
    for i in 4..<n:
      let r5 = ((i * 7) and 0x1F).uint8
      let g5 = ((i * 11 + 5) and 0x1F).uint8
      let b5 = ((i * 13 + 9) and 0x1F).uint8
      let val = (uint16(b5) shl 10) or (uint16(g5) shl 5) or r5
      result[i] = ppu.bgr555ToColor(val)
  else:
    # gray ramp for structure visibility
    for i in 4..<n:
      let v = uint8(32 + ((i - 1) * 192) div max(1, n - 2))
      result[i] = ColorRGBA(r: v, g: v, b: v, a: 255)

proc renderTileSheet(chr: seq[uint8], bpp: int, tilesWide: int, pal: seq[ColorRGBA]): Image =
  ## Render the complete tiles from the byte stream into a grid image.
  ## Each tile is 8x8; partial trailing data for the last tile is ignored.
  let bytesPerTile = bpp * 8
  let numTiles = if bytesPerTile > 0: chr.len div bytesPerTile else: 0
  if numTiles <= 0:
    result = newImage(16, 16)
    result.fill(rgbx(255, 0, 255, 255))
    return
  let tilesHigh = (numTiles + tilesWide - 1) div tilesWide
  let w = tilesWide * 8
  let h = tilesHigh * 8
  result = newImage(w, h)
  result.fill(pal[0])
  for t in 0..<numTiles:
    let tx = t mod tilesWide
    let ty = t div tilesWide
    for py in 0..<8:
      for px in 0..<8:
        let ci = tilePixelFromBytes(chr, t, px, py, bpp)
        let col = if ci < pal.len: pal[ci] else: pal[0]
        result[tx * 8 + px, ty * 8 + py] = col

proc main() =
  ## Parse CLI and drive decode + render for one graphic.
  var
    romPath = DefaultRom
    offset = 0x214EE0
    bpp = 4
    tilesWide = 8
    palStyle = "gray"
    outPath = ""

  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a in ["--help", "-h"]:
      echo """sprites_explore — decode gfx_lz + render SNES planar tiles to PNG

Headless mode (PNG to bin/, gitignored). Re-run with varied flags to browse.

  nim r src/tools/sprites_explore.nim --offset 0x214EE0 --bpp 4 --wide 6 --palette gray
  nim r src/tools/sprites_explore.nim 0x214EE0 --bpp 2

Options:
  --rom <path>         ROM (default: bin/Earthbound (U) [!].smc)
  --offset <0xHEX|N>   File offset of compressed graphic (default 0x214EE0)
  --bpp <2|4>          Planar bits per pixel (default 4)
  --wide <N>           Tiles wide in sheet (default 8)
  --palette <gray|color>  Palette style (default gray)
  --out <path.png>     Output file (default auto in bin/)
  --help               Show this
"""
      quit(0)
    elif a == "--rom" and i + 1 <= paramCount():
      i += 1
      romPath = paramStr(i)
    elif a == "--offset" and i + 1 <= paramCount():
      i += 1
      let s = paramStr(i)
      offset = if s.startsWith("0x") or s.startsWith("0X"): parseHexInt(s) else: parseInt(s)
    elif a == "--bpp" and i + 1 <= paramCount():
      i += 1
      bpp = parseInt(paramStr(i))
    elif a == "--wide" and i + 1 <= paramCount():
      i += 1
      tilesWide = parseInt(paramStr(i))
    elif a == "--palette" and i + 1 <= paramCount():
      i += 1
      palStyle = paramStr(i)
    elif a == "--out" and i + 1 <= paramCount():
      i += 1
      outPath = paramStr(i)
    elif not a.startsWith("--") and offset == 0x214EE0:
      # bare arg treated as offset for quick use
      offset = if a.startsWith("0x") or a.startsWith("0X"): parseHexInt(a) else: parseInt(a)
    i += 1

  if bpp notin {2, 4}:
    echo "bpp must be 2 or 4"
    quit(1)
  if tilesWide < 1:
    tilesWide = 8

  if outPath.len == 0:
    outPath = DefaultOutDir / &"sprites_{offset:06X}_{bpp}bpp.png"

  echo &"sprites_explore"
  echo &"  rom: {romPath}"
  echo &"  offset: 0x{offset:06X}"
  echo &"  bpp: {bpp}  wide: {tilesWide}  palette: {palStyle}"
  echo &"  out: {outPath}"

  let rom = readRom(romPath)
  if offset < 0 or offset >= rom.len:
    echo "offset out of ROM"
    quit(1)

  let comp = extractCompressed(rom, offset)
  echo &"  compressed stream: {comp.len} bytes (incl. terminator)"

  let decoded = decode(comp)
  echo &"  decoded via gfx_lz: {decoded.len} bytes"

  let bytesPerTile = bpp * 8
  let numTiles = decoded.len div bytesPerTile
  echo &"  tiles: {numTiles}  (consuming {numTiles * bytesPerTile} bytes)"

  let colors = 1 shl bpp
  let pal = makePalette(colors, palStyle)
  let img = renderTileSheet(decoded, bpp, tilesWide, pal)

  createDir(parentDir(outPath))
  img.writeFile(outPath)

  # quick non-emptiness check (any non-bg pixel)
  var nonBg = 0
  for p in img.data:
    if p.a > 200 and (p.r > 30 or p.g > 30 or p.b > 30):
      nonBg += 1
  let empty = (nonBg < 10)
  echo &"  rendered: {img.width}x{img.height}  non-bg-ish pixels: {nonBg}"
  echo &"  empty?: {empty}"
  echo "DONE"

when isMainModule:
  main()
