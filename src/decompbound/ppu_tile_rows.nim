const
  PpuRowCacheEntries* {.intdefine.} = 1024
  PlanarVramWords* = 0x8000
  VramWordMask = PlanarVramWords - 1
  PlanePairStride = 8
  RowPixels = 8
  CacheMask = PpuRowCacheEntries - 1
  CacheIndexBits = block:
    var bits = 0
    var size = PpuRowCacheEntries
    while size > 1:
      inc bits
      size = size shr 1
    bits

static:
  doAssert PpuRowCacheEntries > 0 and
    (PpuRowCacheEntries and CacheMask) == 0,
    "PPU row cache size must be a positive power of two."

type
  PlanarRowIndices* = array[RowPixels, uint8]
  CachedPlanarRow = object
    planes: uint64
    indices: PlanarRowIndices
  PpuTileRowCache* = object
    rows: array[PpuRowCacheEntries, CachedPlanarRow]

proc decodeTileRow*(cache: var PpuTileRowCache,
    vram: ptr array[PlanarVramWords, uint16], rowAddress, bpp: int,
    indices: var PlanarRowIndices) {.inline.} =
  ## Reuse indices only when all current plane words match, including after direct VRAM writes.
  if bpp notin [2, 4, 8]:
    raise newException(ValueError, "Planar tile rows require 2, 4 or 8 bits per pixel.")
  let address = rowAddress and VramWordMask
  let plane01 = vram[][address]
  var plane23, plane45, plane67: uint16
  if bpp >= 4:
    plane23 = vram[][(address + PlanePairStride) and VramWordMask]
  if bpp == 8:
    plane45 = vram[][(address + PlanePairStride * 2) and VramWordMask]
    plane67 = vram[][(address + PlanePairStride * 3) and VramWordMask]
  let
    planes = plane01.uint64 or (plane23.uint64 shl 16) or
      (plane45.uint64 shl 32) or (plane67.uint64 shl 48)
    slot = (address xor (address shr CacheIndexBits)) and CacheMask
    row = addr cache.rows[slot]
  if row.planes != planes:
    # Unused plane pairs are zero, so equal keys decode identically across bit depths and machines.
    # A zero-initialized entry already represents the all-zero row exactly.
    for x in 0..<RowPixels:
      var index = 0
      if ((plane01 shr (7 - x)) and 1) != 0: index = index or 1
      if ((plane01 shr (15 - x)) and 1) != 0: index = index or 2
      if bpp >= 4:
        if ((plane23 shr (7 - x)) and 1) != 0: index = index or 4
        if ((plane23 shr (15 - x)) and 1) != 0: index = index or 8
      if bpp == 8:
        if ((plane45 shr (7 - x)) and 1) != 0: index = index or 0x10
        if ((plane45 shr (15 - x)) and 1) != 0: index = index or 0x20
        if ((plane67 shr (7 - x)) and 1) != 0: index = index or 0x40
        if ((plane67 shr (15 - x)) and 1) != 0: index = index or 0x80
      row.indices[x] = index.uint8
    row.planes = planes
  indices = row.indices
