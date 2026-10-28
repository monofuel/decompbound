## Runtime decoder and deterministic renderer for enemy encounter backgrounds.
## Table formats and original CPU/PPU evidence: docs/battle-backgrounds.md.
## The preview omits battle UI/letterbox and uses a black CGRAM backdrop.
## Script-controlled boss phases are outside the static encounter preset.

import
  std/[strformat],
  pixie,
  ./[gfx_lz, common],
  ./ppu

const
  DefaultRomPath* = "bin/Earthbound (U) [!].smc"
  RomEnvVar* = "DECOMPBOUND_ROM"

  FileOffsetMask = 0x3FFFFF

  GfxPtrTableFile* = 0x0AD7A1
  ArrPtrTableFile* = 0x0AD93D
  PalPtrTableFile* = 0x0ADAD9
  LayerTableFile* = 0x0ADCA1
  ScrollTableFile* = 0x0AF258
  DistortTableFile* = 0x0AF708
  BgPairTableFile* = 0x0BD89A
  SineTableFile = 0x00B425

  GfxCount* = 103
  PalCount* = 114
  LayerCount* = 327
  ScrollCount* = 120
  DistortCount* = 135
  ## Loader-backed battle-group table count; see battle_bg_catalog.
  BgScanCap* = 484

  LayerEntrySize = 17
  ScrollEntrySize = 10
  DistortEntrySize = 17
  ArrangementSide = 32
  DecodeWindow = 0x10000

  ScreenW* = 256
  ScreenH* = 224

type
  ScrollSegment* = object
    ## One scroll-table entry: velocities/accelerations in 8.8 px units.
    duration*: int
    hVel*, vVel*: int
    hAccel*, vAccel*: int

  DistortSegment* = object
    ## One distortion program, with 16-bit parameters and byte-sized angle/speed.
    duration*: int
    kind*: int
    frequency*, amplitude*, compression*: int
    freqAccel*, ampAccel*, compAccel*: int
    angle*, speed*: int

  BattleBgLayer* = object
    ## Fully decoded layer: pixels + palette + animation programs.
    id*: int
    gfxIdx*, palIdx*, bpp*: int
    palCycleType*, palCycleSpeed*: int
    cycle1Start*, cycle1End*, cycle2Start*, cycle2End*: int
    chr*: seq[uint8]
    arrangement*: seq[uint16]
    palette*: seq[ColorRGBA]
    scroll*: seq[ScrollSegment]
    distort*: seq[DistortSegment]

  BackgroundWorkspace* = object
    ## Reusable layer buffers for an animated preview.
    layerA, layerB: seq[ColorRGBA]

  BattleBg* = object
    ## A background id resolved to its decoded layer(s) + the sine table.
    id*: int
    layerA*, layerB*: int
    layers*: seq[BattleBgLayer]
    sine*: array[256, int]

proc loadBattleBgRom*(path: string): seq[uint8] =
  ## Read a 3 MiB user ROM and strip an optional 512-byte copier header.
  let data = readFile(path)
  let start = if data.len == EarthboundRomSize + 512: 512 else: 0
  if data.len - start != EarthboundRomSize:
    raise newException(ValueError, "Battle backgrounds require the 3 MiB US ROM.")
  result = newSeq[uint8](EarthboundRomSize)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8

proc u16(rom: seq[uint8], off: int): int {.inline.} =
  ## Read a checked little-endian word from a ROM table.
  if off < 0 or off + 1 >= rom.len:
    raise newException(ValueError, &"Background word at {off:#x} is outside ROM.")
  rom[off].int or (rom[off + 1].int shl 8)

proc s16(rom: seq[uint8], off: int): int {.inline.} =
  ## Read a signed little-endian table word.
  cast[int16](uint16(u16(rom, off))).int

proc farPtrFileOff(rom: seq[uint8], tableOff: int, index: int): int =
  ## Resolve a checked little-endian HiROM pointer in a four-byte entry.
  let poff = tableOff + index * 4
  if index < 0 or poff < 0 or poff + 3 >= rom.len:
    raise newException(ValueError, "Background pointer-table entry is outside ROM.")
  let snes = rom[poff].int or (rom[poff + 1].int shl 8) or (rom[poff + 2].int shl 16)
  result = snes and FileOffsetMask
  if snes == 0 or result >= rom.len:
    raise newException(ValueError, "Background resource pointer is outside ROM.")

proc decodeAt(rom: seq[uint8], fileOff: int): seq[uint8] =
  ## Decode a complete graphics stream and reject truncation.
  if fileOff < 0 or fileOff >= rom.len:
    raise newException(ValueError, "Background graphics pointer is outside ROM.")
  let decoded = gfx_lz.decodeWithConsumed(rom[fileOff ..< min(fileOff + DecodeWindow, rom.len)])
  if not decoded.clean:
    raise newException(ValueError, &"Truncated background graphics stream at {fileOff:#x}.")
  decoded.data

proc bgLayerPair*(rom: seq[uint8], bgId: int): tuple[a, b: int] =
  ## Read the ordered background layer pair selected by a battle group.
  if rom.len != EarthboundRomSize or bgId < 0 or bgId >= BgScanCap:
    raise newException(ValueError, "Invalid battle-group background index or ROM size.")
  let off = BgPairTableFile + bgId * 4
  result = (u16(rom, off), u16(rom, off + 2))
  if result.a >= LayerCount or result.b >= LayerCount:
    raise newException(ValueError, &"Group {bgId} references an invalid background layer.")

proc bgCount*(rom: seq[uint8]): int =
  ## Validate the loader-backed 484-group table rather than guessing a terminator.
  for id in 0 ..< BgScanCap: discard bgLayerPair(rom, id)
  BgScanCap

proc loadScrollSegment(rom: seq[uint8], idx: int): ScrollSegment =
  ## Decode one original ten-byte scroll program.
  let off = ScrollTableFile + idx * ScrollEntrySize
  ScrollSegment(
    duration: u16(rom, off),
    hVel: s16(rom, off + 2), vVel: s16(rom, off + 4),
    hAccel: s16(rom, off + 6), vAccel: s16(rom, off + 8))

proc loadDistortSegment(rom: seq[uint8], idx: int): DistortSegment =
  ## Decode the original seventeen-byte distortion program.
  let off = DistortTableFile + idx * DistortEntrySize
  DistortSegment(
    duration: u16(rom, off),
    kind: rom[off + 2].int,
    frequency: u16(rom, off + 3),
    amplitude: u16(rom, off + 5),
    angle: rom[off + 7].int,
    compression: u16(rom, off + 8),
    freqAccel: s16(rom, off + 10),
    ampAccel: s16(rom, off + 12),
    speed: rom[off + 14].int,
    compAccel: s16(rom, off + 15))

proc decodeLayer*(rom: seq[uint8], layerIdx: int): BattleBgLayer =
  ## Decode one layer-table entry: CHR + arrangement + palette + animation.
  result.id = layerIdx
  if layerIdx <= 0 or layerIdx >= LayerCount:
    raise newException(ValueError, "Background layer must be 1..326.")
  let off = LayerTableFile + layerIdx * LayerEntrySize
  if off + LayerEntrySize > rom.len:
    raise newException(ValueError, "Truncated background layer table.")
  result.gfxIdx = rom[off + 0].int
  result.palIdx = rom[off + 1].int
  result.bpp = rom[off + 2].int
  result.palCycleType = rom[off + 3].int
  result.cycle1Start = rom[off + 4].int
  result.cycle1End = rom[off + 5].int
  result.cycle2Start = rom[off + 6].int
  result.cycle2End = rom[off + 7].int
  result.palCycleSpeed = rom[off + 8].int
  var scrollSlots, distortSlots: array[4, int]
  for i in 0 ..< 4:
    scrollSlots[i] = rom[off + 9 + i].int
    if scrollSlots[i] >= ScrollCount:
      raise newException(ValueError, "Invalid background scroll index.")
    let di = rom[off + 13 + i].int
    if di >= DistortCount: raise newException(ValueError, "Invalid background distortion index.")
    distortSlots[i] = di
  # $C2CBB9 starts at slot 0/counter 1, increments before loading, and a
  # zero index wraps to slot 0. Preserve that startup order, including gaps.
  if scrollSlots[0] > 0:
    var slot = if scrollSlots[1] > 0: 1 else: 0
    var visited: set[0..3]
    while slot notin visited:
      visited.incl(slot)
      let segment = loadScrollSegment(rom, scrollSlots[slot])
      result.scroll.add segment
      if segment.duration == 0: break
      slot = (slot + 1) mod 4
      if scrollSlots[slot] == 0: slot = 0
  elif scrollSlots[1] > 0:
    raise newException(ValueError, "Background scroll chain has no initial slot.")
  if distortSlots[0] > 0:
    var slot = if distortSlots[1] > 0: 1 else: 0
    var visited: set[0..3]
    while slot notin visited:
      visited.incl(slot)
      let segment = loadDistortSegment(rom, distortSlots[slot])
      result.distort.add segment
      if segment.duration == 0: break
      slot = (slot + 1) mod 4
      if distortSlots[slot] == 0: slot = 0
  elif distortSlots[1] > 0:
    raise newException(ValueError, "Background distortion chain has no initial slot.")
  if result.bpp != 2 and result.bpp != 4:
    raise newException(ValueError, "Unsupported background bit depth.")
  if result.gfxIdx >= GfxCount: raise newException(ValueError, "Invalid background graphics index.")
  result.chr = decodeAt(rom, farPtrFileOff(rom, GfxPtrTableFile, result.gfxIdx))
  let arr = decodeAt(rom, farPtrFileOff(rom, ArrPtrTableFile, result.gfxIdx))
  if arr.len != ArrangementSide * ArrangementSide * 2:
    raise newException(ValueError, "Background arrangement must decode to 2048 bytes.")
  if result.chr.len == 0 or result.chr.len mod (result.bpp * 8) != 0:
    raise newException(ValueError, "Background CHR has an invalid tile length.")
  result.arrangement = newSeq[uint16](ArrangementSide * ArrangementSide)
  for i in 0 ..< result.arrangement.len:
    let entry = arr[i * 2].uint16 or (arr[i * 2 + 1].uint16 shl 8)
    if (entry.int and 1023) * result.bpp * 8 >= result.chr.len:
      raise newException(ValueError, "Background arrangement references a missing tile.")
    if (entry and 0x1C00) != 0:
      raise newException(ValueError, "Unsupported background arrangement palette selector.")
    result.arrangement[i] = entry
  result.palette = newSeq[ColorRGBA](16)
  if result.palIdx >= PalCount: raise newException(ValueError, "Invalid background palette index.")
  let poff = farPtrFileOff(rom, PalPtrTableFile, result.palIdx)
  if poff + 32 > rom.len: raise newException(ValueError, "Truncated background palette.")
  for i in 0 ..< 16:
    result.palette[i] = ppu.bgr555ToColor(uint16(u16(rom, poff + i * 2)))

proc loadBattleBg*(rom: seq[uint8], bgId: int): BattleBg =
  ## Resolve a background id and decode its layer(s).
  result.id = bgId
  (result.layerA, result.layerB) = bgLayerPair(rom, bgId)
  if result.layerA > 0 and result.layerA < LayerCount:
    result.layers.add decodeLayer(rom, result.layerA)
  if result.layerB > 0 and result.layerB < LayerCount:
    result.layers.add decodeLayer(rom, result.layerB)
  for i in 0 ..< 256:
    result.sine[i] = cast[int8](rom[SineTableFile + i]).int

proc sar8(v: int): int {.inline.} =
  ## Arithmetic >>8 matching the hardware's signed high-byte extraction.
  if v >= 0: v shr 8 else: -((-v + 255) shr 8)

proc segmentAt[T](segs: seq[T], frame: int): tuple[seg: T, local: int] =
  ## Walk duration-chained segments (duration 0 = hold forever); a fully
  ## finite chain loops.
  var total = 0
  for s in segs:
    if s.duration <= 0:
      total = 0
      break
    total += s.duration
  var f = frame
  if total > 0:
    f = frame mod total
  for s in segs:
    if s.duration <= 0 or f < s.duration:
      return (s, f)
    f -= s.duration
  (segs[^1], f)

proc positiveMod(value, modulus: int64): int64 =
  ## Wrap a signed value into a nonnegative coordinate interval.
  let remainder = value mod modulus
  if remainder < 0: remainder + modulus else: remainder

proc segmentDelta(segment: ScrollSegment, frames: int): tuple[x, y: int64] =
  ## Integrate a constant-acceleration segment modulo a 256-pixel 8.8 texture.
  const CoordinatePeriod = 256'i64 * 256
  let n = frames.int64
  var a = n
  var b = n + 1
  if (a and 1) == 0: a = a div 2
  else: b = b div 2
  let triangle = ((a mod CoordinatePeriod) * (b mod CoordinatePeriod)) mod CoordinatePeriod
  let count = n mod CoordinatePeriod
  result.x = positiveMod(segment.hVel.int64 * count + segment.hAccel.int64 * triangle, CoordinatePeriod)
  result.y = positiveMod(segment.vVel.int64 * count + segment.vAccel.int64 * triangle, CoordinatePeriod)

proc scrollOffsetAt*(segments: seq[ScrollSegment], frame: int): tuple[x, y: int] =
  ## Integrate segments without replaying earlier frames; retain wrapped texture coordinates.
  if frame < 0: raise newException(ValueError, "Negative background frame.")
  if segments.len == 0: return (0, 0)
  const CoordinatePeriod = 256'i64 * 256
  var duration = 0
  var finite = true
  var cycleX, cycleY = 0'i64
  for segment in segments:
    if segment.duration == 0:
      finite = false
      break
    duration += segment.duration
    let delta = segmentDelta(segment, segment.duration)
    cycleX = (cycleX + delta.x) mod CoordinatePeriod
    cycleY = (cycleY + delta.y) mod CoordinatePeriod
  var remaining = frame
  var x, y = 0'i64
  if finite and duration > 0:
    let cycles = (frame div duration).int64 mod CoordinatePeriod
    x = (cycleX * cycles) mod CoordinatePeriod
    y = (cycleY * cycles) mod CoordinatePeriod
    remaining = frame mod duration
  for segment in segments:
    let count = if segment.duration == 0: remaining else: min(remaining, segment.duration)
    let delta = segmentDelta(segment, count)
    x = (x + delta.x) mod CoordinatePeriod
    y = (y + delta.y) mod CoordinatePeriod
    remaining -= count
    if remaining == 0: break
  (int(x div 256), int(y div 256))

type
  LineOffsets* = object
    ## Absolute BG scroll-register values for each scanline.
    dx*, dy*: seq[int]

proc distortionLines*(bg: BattleBg, segments: seq[DistortSegment], frame: int,
                      scrollX, scrollY, height: int): LineOffsets =
  ## Reproduce $C2CF29's wrapped updates and all four $C0AE5A HDMA branches.
  if frame < 0 or height < 0:
    raise newException(ValueError, "Negative background frame or scanline count.")
  result.dx = newSeq[int](height)
  result.dy = newSeq[int](height)
  for y in 0 ..< height:
    result.dx[y] = scrollX
    result.dy[y] = scrollY
  if segments.len == 0: return
  let
    current = segmentAt(segments, max(0, frame - 1))
    segment = current.seg
    updates = if frame == 0: 0 else: current.local + 1
    ticks = updates and 65535
    amplitude = ((segment.amplitude + segment.ampAccel * ticks) and 65535) shr 8
    frequency = (segment.frequency + segment.freqAccel * ticks) and 65535
    compression = (segment.compression + segment.compAccel * ticks) and 65535
    phase = (segment.angle + segment.speed * (updates and 255)) and 255
  if segment.kind notin 1..4:
    raise newException(ValueError, "Unsupported background distortion kind.")
  var
    angle = ((phase + (if segment.kind <= 2: scrollY else: 0)) and 255) shl 8
    vertical = (scrollY and 255) shl 8
  for y in 0 ..< height:
    let
      sine = bg.sine[(angle shr 8) and 255]
      wave = sar8(amplitude * sine)
      signedWave = if segment.kind in [2, 4] and (y and 1) != 0: -wave else: wave
    if segment.kind <= 2:
      result.dx[y] = (scrollX + signedWave) and 65535
    else:
      vertical = (vertical + compression) and 65535
      result.dy[y] = ((vertical shr 8) + signedWave) and 65535
    angle = (angle + frequency) and 65535

proc cycledPalette*(layer: BattleBgLayer, frame: int): seq[ColorRGBA] =
  ## Reproduce $C2C94F's countdown and phase-indexed palette copies.
  if frame < 0: raise newException(ValueError, "Negative background frame.")
  result = newSeq[ColorRGBA](layer.palette.len)
  for i, color in layer.palette: result[i] = color
  if layer.palCycleType == 0 or layer.palCycleSpeed <= 0: return
  let phase = max(0, frame - 1) div layer.palCycleSpeed
  for rangeIndex in 0 .. (if layer.palCycleType == 2: 1 else: 0):
    let
      lo = if rangeIndex == 0: layer.cycle1Start else: layer.cycle2Start
      hi = if rangeIndex == 0: layer.cycle1End else: layer.cycle2End
      count = hi - lo + 1
    if count <= 0 or lo < 0 or hi >= result.len:
      raise newException(ValueError, "Invalid background palette cycle range.")
    for i in 0 ..< count:
      let source = if layer.palCycleType == 3:
        block:
          let position = (i + phase mod (2 * count)) mod (2 * count)
          if position < count: position else: 2 * count - 1 - position
      else: (i - phase mod count + count) mod count
      result[lo + i] = layer.palette[lo + source]

proc chrPixel(chr: seq[uint8], tile, x, y, bpp: int): int =
  ## Planar tile pixel from the decoded CHR stream (low/high plane rows,
  ## planes 2/3 at +16 for 4bpp) — same layout ppu.tilePixel reads from VRAM.
  let bytesPerTile = bpp * 8
  let base = tile * bytesPerTile
  if base + bytesPerTile > chr.len:
    return 0
  let p0 = chr[base + y * 2].int
  let p1 = chr[base + y * 2 + 1].int
  var idx = ((p0 shr (7 - x)) and 1) or (((p1 shr (7 - x)) and 1) shl 1)
  if bpp >= 4:
    let p2 = chr[base + 16 + y * 2].int
    let p3 = chr[base + 16 + y * 2 + 1].int
    idx = idx or (((p2 shr (7 - x)) and 1) shl 2) or
          (((p3 shr (7 - x)) and 1) shl 3)
  idx

proc layerColorAt(layer: BattleBgLayer, pal: seq[ColorRGBA],
                  sx, sy: int): ColorRGBA =
  ## Sample the wrapped 256x256 arrangement at source pixel (sx, sy).
  var x = sx mod 256
  if x < 0: x += 256
  var y = sy mod 256
  if y < 0: y += 256
  let entry = layer.arrangement[(y shr 3) * ArrangementSide + (x shr 3)].int
  let tile = entry and 0x3FF
  var px = x and 7
  var py = y and 7
  if (entry and 0x4000) != 0: px = 7 - px
  if (entry and 0x8000) != 0: py = 7 - py
  let ci = chrPixel(layer.chr, tile, px, py, layer.bpp)
  if ci == 0: ColorRGBA(a: 0) else: pal[ci]

proc renderLayerLines(bg: BattleBg, layer: BattleBgLayer, frame: int,
                      width, height: int, output: var seq[ColorRGBA]) =
  ## Render one layer into reusable storage, with wrapped source coordinates.
  output.setLen(width * height)
  let (scx, scy) = scrollOffsetAt(layer.scroll, frame)
  let lines = distortionLines(bg, layer.distort, frame, scx, scy, height)
  let pal = cycledPalette(layer, frame)
  for y in 0 ..< height:
    let dx = if lines.dx.len > 0: lines.dx[y] else: 0
    let dy = if lines.dy.len > 0: lines.dy[y] else: 0
    let sy = y + dy
    for x in 0 ..< width:
      output[y * width + x] = layerColorAt(layer, pal, x + dx, sy)

proc renderInto*(bg: BattleBg, frame: int, image: Image,
                 workspace: var BackgroundWorkspace) =
  ## Render without battle UI, using black backdrop and original transparent-subscreen math.
  if frame < 0: raise newException(ValueError, "Negative background frame.")
  if image == nil: raise newException(ValueError, "Missing background output buffer.")
  if bg.layers.len == 0:
    image.fill(ColorRGBA(r: 0, g: 0, b: 0, a: 255))
    return
  renderLayerLines(bg, bg.layers[0], frame, image.width, image.height, workspace.layerA)
  if bg.layers.len == 1:
    for i, color in workspace.layerA:
      image.data[i] = ColorRGBA(r: color.r, g: color.g, b: color.b, a: 255)
    return
  renderLayerLines(bg, bg.layers[1], frame, image.width, image.height, workspace.layerB)
  for i, color in workspace.layerA:
    let secondary = workspace.layerB[i]
    image.data[i] = ppu.colorMathBlend(
      ColorRGBA(r: color.r, g: color.g, b: color.b, a: 255),
      ColorRGBA(r: secondary.r, g: secondary.g, b: secondary.b, a: 255),
      doSub = false, doHalf = secondary.a != 0)

proc renderFrame*(bg: BattleBg, frame: int,
                  width = ScreenW, height = ScreenH): Image =
  ## Allocate one background frame for exporters and headless checks.
  var workspace: BackgroundWorkspace
  result = newImage(width, height)
  renderInto(bg, frame, result, workspace)

proc isBlank*(img: Image): bool =
  ## True when every pixel matches the first (no visible content).
  if img.data.len == 0:
    return true
  let first = img.data[0]
  for p in img.data:
    if p != first:
      return false
  true
