import
  std/unittest,
  decompbound/[cpu, save_state]

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

  test "ordinary mode-one rendering observes port uploads, palettes, state import and reset":
    let hardware = newSnesBus(newSeq[uint8](0x10000))
    defer:
      hardware.bus.readHook = nil
      hardware.bus.writeHook = nil
      hardware.apu.spc.readHook = nil
      hardware.apu.spc.writeHook = nil
    var cpuState = hardware.resetCpu()
    hardware.nmitimen = 0x80
    let image = newImage(ScreenWidth, ScreenHeight)
    hardware.ppuRegs[0] = 15
    hardware.ppuRegs[5] = 9
    hardware.ppuRegs[0x2C] = 1
    hardware.ppuRegs[0x0B] = 1
    for row in 0..<8: hardware.vram[0x1000 + row] = 0x00FF
    hardware.cgram[1] = 0x001F
    hardware.cgram[2] = 0x03E0
    let original = serializeState(hardware, cpuState)
    hardware.renderScanline(image, 0)
    doAssert image[0, 0] == toRgbx(bgr555ToColor(0x001F))
    hardware.bus.write8(0x002115, 0x80)
    hardware.bus.write8(0x002116, 0)
    hardware.bus.write8(0x002117, 0x10)
    hardware.bus.write8(0x002118, 0)
    hardware.renderScanline(image, 0)
    doAssert image[0, 0] == rgbx(0, 0, 0, 255)
    hardware.bus.write8(0x002119, 0xFF)
    hardware.renderScanline(image, 0)
    doAssert image[0, 0] == toRgbx(bgr555ToColor(0x03E0))
    hardware.cgram[2] = 0x7C00
    hardware.renderScanline(image, 0)
    doAssert image[0, 0] == toRgbx(bgr555ToColor(0x7C00))
    deserializeState(original, hardware, cpuState)
    hardware.renderScanline(image, 0)
    doAssert image[0, 0] == toRgbx(bgr555ToColor(0x001F))
    hardware.apu.spc.readHook = nil
    hardware.apu.spc.writeHook = nil
    discard hardware.softReset()
    hardware.ppuRegs[0] = 15
    hardware.ppuRegs[5] = 9
    hardware.ppuRegs[0x2C] = 1
    hardware.ppuRegs[0x0B] = 1
    hardware.vram[0x1000] = 0xFFFF
    hardware.cgram[3] = 0x7FFF
    hardware.renderScanline(image, 0)
    doAssert image[0, 0] == rgbx(255, 255, 255, 255)
