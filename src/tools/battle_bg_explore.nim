## EarthBound battle background explorer (headless PNG frame dumper).
## Decodes background-ID -> layer pair at $CBDA9A, layer table at $CADEA1,
## gfx pointers at $CAD9A1, inline palettes at $CADCD9. Decompresses CHR
## via gfx_lz, renders repeating 8xN tile base texture (wrap) with per-frame
## scroll, sine distortion (HDMA-style), and optional palette cycling.
## Two layers composited with additive color math (min(255,a+b)).
## bin/ output gitignored. Models closely after map_explore.nim helpers.
## Usage: make battle-bg BG=0 or nim r ... --bg 6 --frames 30

import
  std/[os, strformat, strutils, math],
  pixie,
  ../decompbound/[gfx_lz, ppu]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultFrames = 60
  DefaultOutBase = "bin/battle_bg"
  # HiROM: file offset from SNES addr
  FileOffsetMask = 0x3FFFFF
  # Confirmed table locations (file offsets)
  BgTableFile = 0x0BDA9A
  LayerTableFile = 0x0ADEA1
  GfxPtrTableFile = 0x0AD9A1
  PalTableFile = 0x0ADCD9
  MaxLayer = 326
  GfxPtrCount = 18
  OutputSize = 256

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

proc fileOff(snesAddr: int): int =
  ## Convert SNES HiROM address to file offset.
  snesAddr and FileOffsetMask

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
  ## (Copied from map_explore.nim)
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

proc parseNum(s: string): int =
  ## Parse decimal or 0x-hex string to int.
  if s.startsWith("0x") or s.startsWith("0X"):
    parseHexInt(s)
  else:
    parseInt(s)

type
  LayerInfo = object
    gfxIdx: int
    palIdx: int
    bpp: int
    palCountByte: int
    scrollDX: float
    scrollDY: float
    amplitude: float
    freq: float
    phaseSpeed: float
    hasPalCycle: bool

proc loadLayerInfo(rom: seq[uint8], layerIdx: int): LayerInfo =
  ## Load 17-byte layer entry from the layer table.
  if layerIdx < 0 or layerIdx > MaxLayer:
    return LayerInfo(gfxIdx: 0, palIdx: 0, bpp: 4)
  let off = LayerTableFile + layerIdx * 17
  if off + 16 >= rom.len:
    return LayerInfo(gfxIdx: 0, palIdx: 0, bpp: 4)
  let flag = rom[off + 2].int
  let dxRaw = cast[int8](rom[off + 8])
  let dyRaw = cast[int8](rom[off + 11])
  let d3 = rom[off + 15].int
  let d4 = rom[off + 16].int
  let palCountB = rom[off + 6].int
  LayerInfo(
    gfxIdx: rom[off + 0].int,
    palIdx: rom[off + 1].int,
    bpp: (if flag >= 2: 4 else: 2),
    palCountByte: palCountB,
    scrollDX: dxRaw.float / 16.0,
    scrollDY: dyRaw.float / 16.0,
    amplitude: (if d3 > 0: d3.float else: 8.0),
    freq: (if d4 > 0: d4.float / 32.0 else: 1.0),
    phaseSpeed: 0.20,
    hasPalCycle: (palCountB != 0)
  )

proc getBgLayerPair(rom: seq[uint8], bg: int): tuple[a: int, b: int] =
  ## Read little-endian u16 layerA, layerB for a background id.
  let off = BgTableFile + bg * 4
  if off + 3 >= rom.len:
    return (0, 0)
  let la = (rom[off + 0].uint16) or (rom[off + 1].uint16 shl 8)
  let lb = (rom[off + 2].uint16) or (rom[off + 3].uint16 shl 8)
  (la.int, lb.int)

proc loadLayerGfx(rom: seq[uint8], gfxIdx: int): seq[uint8] =
  ## Resolve gfx ptr table entry (3-byte LE SNES far ptr + pad), extract
  ## compressed stream, decode with gfx_lz.
  if gfxIdx < 0 or gfxIdx >= GfxPtrCount:
    return @[]
  let poff = GfxPtrTableFile + gfxIdx * 4
  if poff + 2 >= rom.len:
    return @[]
  let snesAddr = (rom[poff + 0].uint32) or
                 (rom[poff + 1].uint32 shl 8) or
                 (rom[poff + 2].uint32 shl 16)
  let foff = fileOff(snesAddr.int)
  if foff < 0 or foff >= rom.len:
    return @[]
  let comp = extractCompressed(rom, foff)
  if comp.len == 0:
    return @[]
  gfx_lz.decode(comp)

proc loadPalette(rom: seq[uint8], palIdx: int): seq[ColorRGBA] =
  ## Load 16-color inline palette (BGR555 LE) and convert via ppu.
  result = newSeq[ColorRGBA](16)
  let off = PalTableFile + palIdx * 32
  for i in 0..<16:
    if off + i*2 + 1 >= rom.len:
      result[i] = ColorRGBA(r: 0, g: 0, b: 0, a: 255)
      continue
    let val = (rom[off + i*2].uint16) or (rom[off + i*2 + 1].uint16 shl 8)
    result[i] = ppu.bgr555ToColor(val)

type
  IndexLayer = object
    indices: seq[int]
    w: int
    h: int

proc buildIndexLayer(chr: seq[uint8], bpp: int, tilesWide = 8): IndexLayer =
  ## Build a repeating base texture as palette indices from planar CHR.
  ## 8 tiles wide (64px), height = ceil(tiles/8) rows.
  let bpt = bpp * 8
  let nTiles = if bpt > 0: chr.len div bpt else: 0
  let tw = tilesWide
  let th = if nTiles > 0: (nTiles + tw - 1) div tw else: 1
  let ww = tw * 8
  let hh = th * 8
  var idxs = newSeq[int](ww * hh)
  for t in 0..<nTiles:
    let tx0 = (t mod tw) * 8
    let ty0 = (t div tw) * 8
    for py in 0..<8:
      for px in 0..<8:
        let ci = tilePixelFromBytes(chr, t, px, py, bpp)
        idxs[(ty0 + py) * ww + (tx0 + px)] = ci
  IndexLayer(indices: idxs, w: ww, h: hh)

proc sampleIndex(il: IndexLayer, x: int, y: int): int =
  ## Wrap sample from the index base texture.
  if il.w <= 0 or il.h <= 0:
    return 0
  var mx = x mod il.w
  if mx < 0: mx += il.w
  var my = y mod il.h
  if my < 0: my += il.h
  il.indices[my * il.w + mx]

proc renderLayerFrame(il: IndexLayer, pal: seq[ColorRGBA],
                      scrollX: float, scrollY: float,
                      amplitude: float, freq: float, phase: float,
                      palRot: int, size: int = OutputSize): Image =
  ## Render one 256x256 frame for a layer: base repeat + scroll offset +
  ## per-scanline sine x-distort + palette cycle shift (if enabled).
  result = newImage(size, size)
  let bg = if pal.len > 0: pal[0] else: ColorRGBA(r: 16, g: 16, b: 24, a: 255)
  result.fill(bg)
  if il.w <= 0 or il.h <= 0:
    return
  for y in 0..<size:
    let xdist = round(amplitude * sin(2.0 * PI * (y.float * freq / 64.0) + phase)).int
    for x in 0..<size:
      let sx = x + xdist + round(scrollX).int
      let sy = y + round(scrollY).int
      var ci = sampleIndex(il, sx, sy)
      if ci > 0 and palRot != 0:
        # rotate indices 1..15
        ci = 1 + ((ci - 1 + palRot) mod 15)
      let col = if ci < pal.len and ci >= 0: pal[ci] else: bg
      result[x, y] = col

proc compositeAdd(a: Image, b: Image): Image =
  ## Classic EB additive layer combine (BG1+BG2 color math).
  doAssert a.width == b.width and a.height == b.height
  result = newImage(a.width, a.height)
  for i in 0..<a.data.len:
    let ca = a.data[i]
    let cb = b.data[i]
    result.data[i] = ColorRGBA(
      r: min(255, ca.r.int + cb.r.int).uint8,
      g: min(255, ca.g.int + cb.g.int).uint8,
      b: min(255, ca.b.int + cb.b.int).uint8,
      a: 255
    )

proc countNonBg(img: Image, bg: ColorRGBA): int =
  ## Count pixels that are visibly non-background (like map_explore).
  result = 0
  for p in img.data:
    if p.a > 200 and (p.r != bg.r or p.g != bg.g or p.b != bg.b):
      result += 1

proc main() =
  ## Parse CLI, decode bg->layers, render animated 256x256 frame sequence
  ## with scroll + sine warp + pal cycle, composite if two layers, write PNGs.
  var
    romPath = DefaultRom
    bg = 0
    frames = DefaultFrames
    outDir = ""
    i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a in ["--help", "-h"]:
      echo """battle_bg_explore — decode + render EarthBound animated battle backgrounds to PNG frames

Headless. Repeats small CHR tile base to 256x256 with per-frame scroll, sine distortion,
palette cycling, and two-layer additive composite.

  nix develop -c nim r src/tools/battle_bg_explore.nim --bg 0
  make battle-bg BG=6 FRAMES=30
  nix develop -c nim r src/tools/battle_bg_explore.nim 6 --frames 120 --out bin/bg6

Options:
  --bg N            Background id (default 0; bare first arg also works)
  --frames N        Number of frames to emit (default 60)
  --rom <path>      ROM path (default bin/Earthbound (U) [!].smc)
  --out <dir>       Output dir (default bin/battle_bg_<BG>)
  --help
"""
      quit(0)
    elif a == "--rom" and i + 1 <= paramCount():
      i += 1
      romPath = paramStr(i)
    elif a == "--bg" and i + 1 <= paramCount():
      i += 1
      bg = parseNum(paramStr(i))
    elif a == "--frames" and i + 1 <= paramCount():
      i += 1
      frames = parseNum(paramStr(i))
    elif a == "--out" and i + 1 <= paramCount():
      i += 1
      outDir = paramStr(i)
    elif not a.startsWith("--") and bg == 0 and i == 1:
      # bare numeric arg as bg id (convenience, first only)
      bg = parseNum(a)
    i += 1

  if bg < 0: bg = 0
  if frames < 1: frames = DefaultFrames
  if frames > 240: frames = 240  # safety cap
  if outDir.len == 0:
    outDir = &"{DefaultOutBase}_{bg}"

  echo "battle_bg_explore"
  echo &"  rom: {romPath}"
  echo &"  bg: {bg}  frames: {frames}"
  echo &"  out: {outDir}"

  let rom = readRom(romPath)

  let (layerA, layerB) = getBgLayerPair(rom, bg)
  echo &"  layers: A={layerA} B={layerB}"

  # stop marker guard (both zero or out of range)
  if (layerA == 0 and layerB == 0) or layerA > MaxLayer or layerB > MaxLayer:
    echo "  (bg table end marker or out of range; nothing to render)"
    quit(0)

  var laInfo = LayerInfo(gfxIdx: 0, palIdx: 0)
  var lbInfo = LayerInfo(gfxIdx: 0, palIdx: 0)
  var chrA: seq[uint8] = @[]
  var chrB: seq[uint8] = @[]
  var palA: seq[ColorRGBA] = @[]
  var palB: seq[ColorRGBA] = @[]
  var baseA: IndexLayer
  var baseB: IndexLayer

  if layerA > 0 and layerA <= MaxLayer:
    laInfo = loadLayerInfo(rom, layerA)
    echo &"  layerA: gfx={laInfo.gfxIdx} pal={laInfo.palIdx} bpp={laInfo.bpp} cycle={laInfo.hasPalCycle}"
    chrA = loadLayerGfx(rom, laInfo.gfxIdx)
    let tileBytesA = if laInfo.bpp > 0: laInfo.bpp * 8 else: 32
    let nTilesA = if tileBytesA > 0: chrA.len div tileBytesA else: 0
    echo &"  chrA: {chrA.len} bytes  tiles={nTilesA}"
    palA = loadPalette(rom, laInfo.palIdx)
    baseA = buildIndexLayer(chrA, laInfo.bpp)
    # Verification: roundtrip on decoded bytes for layerA
    let rtOk = gfx_lz.roundtrip(chrA)
    echo &"  ROUND-TRIP: {(if rtOk: \"PASS\" else: \"FAIL\")}"
    doAssert rtOk, "layerA gfx_lz roundtrip failed"

  if layerB > 0 and layerB <= MaxLayer:
    lbInfo = loadLayerInfo(rom, layerB)
    echo &"  layerB: gfx={lbInfo.gfxIdx} pal={lbInfo.palIdx} bpp={lbInfo.bpp} cycle={lbInfo.hasPalCycle}"
    chrB = loadLayerGfx(rom, lbInfo.gfxIdx)
    let tileBytesB = if lbInfo.bpp > 0: lbInfo.bpp * 8 else: 32
    let nTilesB = if tileBytesB > 0: chrB.len div tileBytesB else: 0
    echo &"  chrB: {chrB.len} bytes  tiles={nTilesB}"
    palB = loadPalette(rom, lbInfo.palIdx)
    baseB = buildIndexLayer(chrB, lbInfo.bpp)

  if baseA.w == 0 and baseB.w == 0:
    echo "  no renderable layers (empty CHR)"
    quit(1)

  createDir(outDir)

  var nonBgTotal = 0
  var frame0: Image = nil
  var frameMid: Image = nil

  for f in 0..<frames:
    let phaseA = f.float * laInfo.phaseSpeed
    let scrollXA = f.float * laInfo.scrollDX
    let scrollYA = f.float * laInfo.scrollDY
    let rotA = if laInfo.hasPalCycle: (f mod 15) else: 0
    let imgA = if baseA.w > 0:
      renderLayerFrame(baseA, palA, scrollXA, scrollYA, laInfo.amplitude, laInfo.freq, phaseA, rotA)
    else:
      newImage(OutputSize, OutputSize)

    var outImg = imgA
    if baseB.w > 0:
      let phaseB = f.float * lbInfo.phaseSpeed
      let scrollXB = f.float * lbInfo.scrollDX
      let scrollYB = f.float * lbInfo.scrollDY
      let rotB = if lbInfo.hasPalCycle: (f mod 15) else: 0
      let imgB = renderLayerFrame(baseB, palB, scrollXB, scrollYB, lbInfo.amplitude, lbInfo.freq, phaseB, rotB)
      outImg = compositeAdd(imgA, imgB)

    let fname = outDir / &"frame_{f:03}.png"
    outImg.writeFile(fname)

    if f == 0:
      frame0 = outImg
      let bg0 = if palA.len > 0: palA[0] else: ColorRGBA()
      nonBgTotal = countNonBg(outImg, bg0)
    if f == min(30, frames - 1):
      frameMid = outImg

  let bgRef = if palA.len > 0: palA[0] else: ColorRGBA()
  let nonBg = countNonBg(frame0, bgRef)
  echo &"  rendered: {frames} frames @ {OutputSize}x{OutputSize}  non-bg-ish pixels (frame0): {nonBg}"
  echo &"  output dir: {outDir}"

  # quick differ check (animation actually moves): compare frame0 vs a mid frame
  if frameMid != nil and frame0 != nil:
    var same = true
    if frame0.data.len == frameMid.data.len:
      for k in 0..<frame0.data.len:
        if frame0.data[k] != frameMid.data[k]:
          same = false
          break
    if not same:
      echo "  animation: frames differ (ok)"
    else:
      echo "  animation: WARNING frames identical?"

  echo "DONE"

when isMainModule:
  main()
