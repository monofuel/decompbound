## EarthBound map explorer (headless PNG dumper for overworld regions).
## Decodes a tilemap (2-byte tile+attr words per decompilation.md at 0x101800)
## + its tileset (gfx_lz compressed at e.g. 0x3E408 or raw fallback) + synthetic
## palette into a composed map chunk image. bin/ output is gitignored per
## copyright rules — never commit decoded map/graphics data.
## Supports choosing map region via --map-offset (tile WORD data) and
## --tileset-offset. Optionally overlays simple attr viz (prio/pal bits).
## Reuses gfx_lz.decode and ppu.bgr555ToColor by import; tile decode logic
## mirrors ppu.tilePixel adapted for byte buffer (as sprites_explore does).
## Usage: re-run with different offsets/width/height to browse regions.
## (Silky UI is the intended future for this stub.)

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[gfx_lz, ppu]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultOutDir = "bin"
  ## TODO: default map data and tileset from docs/decompilation.md Maps section
  ## (tilemap ptr table file 0x100000 bank $CF, tilemap data 0x101800 2-byte words,
  ## tileset gfx 0x3E408, sector config 0x3E250). These are magic for bootstrap;
  ## replace with resolved runtime values / table lookups in future.
  DefaultMapOffset = 0x101800
  DefaultTilesetOffset = 0x3E408
  DefaultMapWidth = 32
  DefaultMapHeight = 32
  DefaultBpp = 4

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

proc loadTileset(rom: seq[uint8], off: int): seq[uint8] =
  ## Load tileset bytes: use gfx_lz if the data at off looks like a compressed
  ## stream (contains 0xFF terminator soon), else fallback to raw bytes.
  ## Per task: "via gfx_lz if compressed, else raw".
  if off < 0 or off >= rom.len:
    return @[]
  var hasTerm = false
  for k in off ..< min(off + 2048, rom.len):
    if rom[k] == 0xFFu8:
      hasTerm = true
      break
  if hasTerm:
    let comp = extractCompressed(rom, off)
    if comp.len > 0:
      return gfx_lz.decode(comp)
  # raw fallback: take a reasonable chunk (4bpp tilesets are often 4k-8k)
  let take = min(8192, rom.len - off)
  if take > 0:
    return rom[off ..< off + take]
  return @[]

proc tilePixelFromBytes(chr: seq[uint8], tile: int, x: int, y: int, bpp: int): int =
  ## Decode a single pixel (0..(1<<bpp)-1) from planar tile bytes in the
  ## decompressed stream. Layout matches ppu.tilePixel: per-row low-byte=plane0,
  ## high-byte=plane1 (and planes 2/3 at +16 bytes for 4bpp).
  ## (Adapted here for direct byte buffer use, same as sprites_explore.)
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
    if base + 16 + y * 2 + 1 < chr.len:
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
  ## For map we allocate headroom for subpalettes (e.g. 8*16 for 4bpp).
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

proc renderMapRegion(tilemap: seq[uint16], mapW: int, mapH: int,
                     chr: seq[uint8], bpp: int, pal: seq[ColorRGBA],
                     overlayAttr: bool): Image =
  ## Render the tilemap (using 2-byte tile+attr entries) over the decoded
  ## tileset chr into a map image. Each tile 8x8. Applies h/v flips.
  ## Subpalette bits are noted but flattened into base palette for this viewer.
  ## If overlayAttr, tint/mark tiles that have nonzero pal or priority bit.
  ## Returns a non-bg image for valid inputs (wraps tile index for small sets).
  let imgW = mapW * 8
  let imgH = mapH * 8
  result = newImage(imgW, imgH)
  result.fill(pal[0])
  if mapW <= 0 or mapH <= 0 or chr.len == 0:
    return
  let bytesPerTile = bpp * 8
  let numTiles = if bytesPerTile > 0: chr.len div bytesPerTile else: 1
  let safeNum = max(1, numTiles)
  let bgCol = pal[0]
  for ty in 0..<mapH:
    for tx in 0..<mapW:
      let idx = ty * mapW + tx
      if idx >= tilemap.len:
        continue
      let entry = tilemap[idx]
      var tile = (entry and 0x3FF).int
      let hflip = (entry and 0x4000) != 0
      let vflip = (entry and 0x8000) != 0
      # wrap for small tilesets / out of range to guarantee visible pixels
      if tile >= safeNum:
        tile = tile mod safeNum
      let subpal = ((entry shr 10) and 7).int
      let hasOverlay = overlayAttr and (((entry and 0x2000) != 0) or subpal != 0)
      for py in 0..<8:
        for px in 0..<8:
          var sx = if hflip: 7 - px else: px
          var sy = if vflip: 7 - py else: py
          let ci = tilePixelFromBytes(chr, tile, sx, sy, bpp)
          # flatten: base + subpal*16 but clamp to pal
          var colIdx = ci + subpal * (1 shl bpp)
          if colIdx >= pal.len or colIdx < 0:
            colIdx = ci
          var col = if colIdx < pal.len: pal[colIdx] else: pal[ci mod pal.len]
          if hasOverlay and (px == 0 or py == 0):
            # simple attr overlay: magenta edge markers on affected tiles
            col = ColorRGBA(r: 255, g: 0, b: 255, a: 220)
          result[tx * 8 + px, ty * 8 + py] = col

proc readTilemapWords(rom: seq[uint8], off: int, w: int, h: int): seq[uint16] =
  ## Read w*h 2-byte little-endian tile+attr words from the tilemap data area.
  result = newSeq[uint16](w * h)
  for i in 0..<result.len:
    let p = off + i * 2
    if p + 1 < rom.len:
      result[i] = (rom[p].uint16) or (rom[p + 1].uint16 shl 8)
    else:
      result[i] = 0

proc main() =
  ## Parse CLI and drive decode tilemap + tileset + render composed PNG.
  var
    romPath = DefaultRom
    mapOffset = DefaultMapOffset
    tilesetOffset = DefaultTilesetOffset
    mapW = DefaultMapWidth
    mapH = DefaultMapHeight
    bpp = DefaultBpp
    palStyle = "gray"
    overlayAttr = false
    outPath = ""

  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a in ["--help", "-h"]:
      echo """map_explore — decode tilemap (2B words) + gfx_lz tileset + render overworld map region to PNG

Headless mode (PNG to bin/, gitignored). Re-run with varied flags to browse regions.
Follows docs/decompilation.md (ptr table 0x100000, data 0x101800, tileset 0x3E408).

  nim r src/tools/map_explore.nim --map-offset 0x101800 --tileset-offset 0x3E408 --width 32 --height 32
  nim r src/tools/map_explore.nim 0x101800 --tileset-offset 0x03FD00 --width 64 --height 32 --overlay

Options:
  --rom <path>              ROM (default: bin/Earthbound (U) [!].smc)
  --map-offset <0xHEX|N>    File offset of 2-byte tile+attr tilemap data (default 0x101800)
  --tileset-offset <0xHEX|N> File offset of (compressed) tileset gfx (default 0x3E408)
  --width <N>               Map width in tiles (default 32)
  --height <N>              Map height in tiles (default 32)
  --bpp <2|4>               Bits per pixel for tileset (default 4)
  --palette <gray|color>    Palette style (default gray)
  --overlay                 Overlay tile attr markers (pal/prio bits) in magenta
  --out <path.png>          Output file (default auto in bin/)
  --help                    Show this
"""
      quit(0)
    elif a == "--rom" and i + 1 <= paramCount():
      i += 1
      romPath = paramStr(i)
    elif a == "--map-offset" and i + 1 <= paramCount():
      i += 1
      let s = paramStr(i)
      mapOffset = if s.startsWith("0x") or s.startsWith("0X"): parseHexInt(s) else: parseInt(s)
    elif a == "--tileset-offset" and i + 1 <= paramCount():
      i += 1
      let s = paramStr(i)
      tilesetOffset = if s.startsWith("0x") or s.startsWith("0X"): parseHexInt(s) else: parseInt(s)
    elif a == "--width" and i + 1 <= paramCount():
      i += 1
      mapW = parseInt(paramStr(i))
    elif a == "--height" and i + 1 <= paramCount():
      i += 1
      mapH = parseInt(paramStr(i))
    elif a == "--bpp" and i + 1 <= paramCount():
      i += 1
      bpp = parseInt(paramStr(i))
    elif a == "--palette" and i + 1 <= paramCount():
      i += 1
      palStyle = paramStr(i)
    elif a == "--overlay":
      overlayAttr = true
    elif a == "--out" and i + 1 <= paramCount():
      i += 1
      outPath = paramStr(i)
    elif not a.startsWith("--") and mapOffset == DefaultMapOffset:
      # bare arg treated as map-offset for quick use
      mapOffset = if a.startsWith("0x") or a.startsWith("0X"): parseHexInt(a) else: parseInt(a)
    i += 1

  if bpp notin {2, 4}:
    echo "bpp must be 2 or 4"
    quit(1)
  if mapW < 1: mapW = DefaultMapWidth
  if mapH < 1: mapH = DefaultMapHeight
  if mapW * mapH > 4096:
    echo "region too large (cap at 4096 tiles for safety)"
    quit(1)

  if outPath.len == 0:
    outPath = DefaultOutDir / &"map_{mapOffset:06X}_{tilesetOffset:06X}_{mapW}x{mapH}.png"

  echo "map_explore"
  echo &"  rom: {romPath}"
  echo &"  map-offset: 0x{mapOffset:06X}  tileset-offset: 0x{tilesetOffset:06X}"
  echo &"  region: {mapW}x{mapH} tiles  bpp: {bpp}  palette: {palStyle}"
  if overlayAttr:
    echo "  overlay: attr markers enabled"
  echo &"  out: {outPath}"

  let rom = readRom(romPath)
  if mapOffset < 0 or mapOffset + (mapW * mapH * 2) > rom.len:
    echo "map-offset out of ROM or region overruns"
    quit(1)
  if tilesetOffset < 0 or tilesetOffset >= rom.len:
    echo "tileset-offset out of ROM"
    quit(1)

  let chr = loadTileset(rom, tilesetOffset)
  echo &"  tileset loaded: {chr.len} bytes"

  let tilemap = readTilemapWords(rom, mapOffset, mapW, mapH)
  echo &"  tilemap: {tilemap.len} entries (2-byte words)"

  let bytesPerTile = bpp * 8
  let numTiles = if bytesPerTile > 0: chr.len div bytesPerTile else: 0
  echo &"  tiles: {numTiles}  (consuming {numTiles * bytesPerTile} bytes)"

  # allocate palette with room for subpals (4bpp -> up to 8*16)
  let palSize = if bpp == 4: 128 else: 32
  let pal = makePalette(palSize, palStyle)
  let img = renderMapRegion(tilemap, mapW, mapH, chr, bpp, pal, overlayAttr)

  createDir(parentDir(outPath))
  img.writeFile(outPath)

  # quick non-emptiness check (any non-bg pixel)
  var nonBg = 0
  let bg = pal[0]
  for p in img.data:
    if p.a > 200 and (p.r != bg.r or p.g != bg.g or p.b != bg.b):
      nonBg += 1
  let empty = (nonBg < 10)
  echo &"  rendered: {img.width}x{img.height}  non-bg-ish pixels: {nonBg}"
  echo &"  empty?: {empty}"
  echo "DONE"

when isMainModule:
  main()
