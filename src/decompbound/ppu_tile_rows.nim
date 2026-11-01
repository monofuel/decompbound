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
    valid: bool
  PpuTileRowCache* = object
    rows: array[PpuRowCacheEntries, CachedPlanarRow]

proc decodeTileRow*(cache: var PpuTileRowCache,
    vram: ptr array[PlanarVramWords, uint16], rowAddress, bpp: int,
    indices: var PlanarRowIndices) {.inline.} =
  ## Reuse indices only when all current plane words match, including after direct VRAM writes.
  if bpp notin [2, 4, 8]:
    raise newException(ValueError, "Planar tile rows require 2, 4 or 8 bits per pixel.")
  let address = rowAddress and VramWordMask
  var planes = vram[][address].uint64
  if bpp >= 4:
    planes = planes or (vram[][(address + PlanePairStride) and VramWordMask].uint64 shl 16)
  if bpp == 8:
    planes = planes or (vram[][(address + PlanePairStride * 2) and VramWordMask].uint64 shl 32) or
      (vram[][(address + PlanePairStride * 3) and VramWordMask].uint64 shl 48)
  let
    slot = (address xor (address shr CacheIndexBits)) and CacheMask
    row = addr cache.rows[slot]
  if not row.valid or row.planes != planes:
    # Unused plane pairs are zero, so equal keys decode identically across bit depths and machines.
    for x in 0..<RowPixels:
      var index = ((planes shr (7 - x)) and 1) or
        (((planes shr (15 - x)) and 1) shl 1)
      if bpp >= 4:
        index = index or (((planes shr (23 - x)) and 1) shl 2) or
          (((planes shr (31 - x)) and 1) shl 3)
      if bpp == 8:
        index = index or (((planes shr (39 - x)) and 1) shl 4) or
          (((planes shr (47 - x)) and 1) shl 5) or
          (((planes shr (55 - x)) and 1) shl 6) or
          (((planes shr (63 - x)) and 1) shl 7)
      row.indices[x] = index.uint8
    row.planes = planes
    row.valid = true
  indices = row.indices
