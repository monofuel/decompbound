import std/unittest

include ../src/decompbound/ppu

proc expectRow(cache: var PpuTileRowCache, machine: SnesBus, address, bpp: int) =
  ## Compare cached rows with the independent scalar decoder used by legacy drawing.
  var indices: PlanarRowIndices
  cache.decodeTileRow(addr machine.vram, address, bpp, indices)
  for x in 0..<8:
    doAssert indices[x].int == machine.tilePixel(address, 0, x, 0, bpp),
      "Tile row differed at address " & $address & ", bpp=" & $bpp & ", x=" & $x

suite "Native PPU tile row reuse":
  test "every two-bit plane word matches scalar decoding":
    let machine = SnesBus()
    var cache: PpuTileRowCache
    for word in 0..uint16.high.int:
      machine.vram[0] = word.uint16
      cache.expectRow(machine, 0, 2)
      cache.expectRow(machine, 0, 2)

  test "four and eight bit rows preserve each plane and wrapped VRAM addresses":
    let machine = SnesBus()
    var cache: PpuTileRowCache
    for address in [0, 7, 0x1000, 0x7FE8, 0x7FF8, 0x7FFF, 0x8000, -1]:
      for seed in 0..<256:
        for pair in 0..<4:
          let word = ((seed * (pair * 2 + 1)) xor (0xA55A shr pair)) and 0xFFFF
          machine.vram[(address + pair * 8) and 0x7FFF] = word.uint16
        for bpp in [2, 4, 8]:
          cache.expectRow(machine, address, bpp)
          cache.expectRow(machine, address, bpp)

  test "direct and byte-sized mutations cannot retain a stale row":
    let machine = SnesBus()
    var cache: PpuTileRowCache
    for bpp in [2, 4, 8]:
      for plane in 0..<bpp:
        for x in 0..<8:
          let
            address = (plane div 2) * 8
            mask = 1'u16 shl (7 - x + (plane mod 2) * 8)
          cache.expectRow(machine, 0, bpp)
          machine.vram[address] = machine.vram[address] xor mask
          cache.expectRow(machine, 0, bpp)

  test "collisions, machine switching and bit-depth changes retain exact indices":
    let
      first = SnesBus()
      second = SnesBus()
      collision = PpuRowCacheEntries + 1
    var cache: PpuTileRowCache
    for pair in 0..<4:
      first.vram[pair * 8] = (0x1357 + pair * 0x1111).uint16
      second.vram[pair * 8] = (0x8421 + pair * 0x1000).uint16
      first.vram[(collision + pair * 8) and 0x7FFF] = (0xFEDC - pair * 0x1111).uint16
    for turn in 0..<8:
      for bpp in [8, 2, 4, 2, 8]:
        cache.expectRow(first, 0, bpp)
        cache.expectRow(second, 0, bpp)
        cache.expectRow(first, collision, bpp)
        cache.expectRow(first, 0, bpp)
    for bpp in [0, 1, 3, 16]:
      var indices: PlanarRowIndices
      expect ValueError:
        cache.decodeTileRow(addr first.vram, 0, bpp, indices)
