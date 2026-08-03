## VMAIN ($2115) address translation — event/dialogue VRAM DMA.
## ROM-free: pure remapping math + write-path deposit check.
## See docs/hard-problems.md (DMA-gap / VMAIN).

import
  std/strformat,
  decompbound/[cpu, snesbus]

proc setVmain(snes: SnesBus, v: uint8) =
  ## Write VMAIN through the MMIO path (same as the CPU).
  snes.bus.write8(0x2115'u32, v)

proc setVmadd(snes: SnesBus, vaddr: uint16) =
  ## Write VMADDL/H through MMIO.
  snes.bus.write8(0x2116'u32, uint8(vaddr and 0xFF))
  snes.bus.write8(0x2117'u32, uint8((vaddr shr 8) and 0xFF))

proc writeVramWord(snes: SnesBus, lo, hi: uint8) =
  ## 16-bit VRAM write via $2118 then $2119 (common DMA pattern).
  snes.bus.write8(0x2118'u32, lo)
  snes.bus.write8(0x2119'u32, hi)

block trans0Identity:
  ## Default: no remapping — address is VMADD as written.
  let snes = newSnesBus(newSeq[uint8](0x10000))
  setVmain(snes, 0x80)  # inc after high, step 1, trans=0
  setVmadd(snes, 0x1234)
  doAssert snes.translatedVramAddr() == 0x1234
  writeVramWord(snes, 0xAB, 0xCD)
  doAssert snes.vram[0x1234] == 0xCDAB,
    &"trans0 deposit: got {snes.vram[0x1234]:04X}"

block trans1EightBitRotate:
  ## bits 3-2 = 01: rotate low 8 bits left by 3.
  ## VMADD=0x0105 → low 0x05 → rot 0x28 → effective 0x0128.
  let snes = newSnesBus(newSeq[uint8](0x10000))
  setVmain(snes, 0x84)  # trans=1 (bits 3-2 = 01), inc after high
  setVmadd(snes, 0x0105)
  doAssert snes.translatedVramAddr() == 0x0128,
    &"trans1 map: got {snes.translatedVramAddr():04X} want 0128"
  writeVramWord(snes, 0x11, 0x22)
  doAssert snes.vram[0x0128] == 0x2211
  doAssert snes.vram[0x0105] == 0,
    "must not deposit at untranslated address"

block trans2NineBitRotate:
  ## bits 3-2 = 10: rotate low 9 bits left by 3.
  let snes = newSnesBus(newSeq[uint8](0x10000))
  setVmain(snes, 0x88)  # trans=2
  setVmadd(snes, 0x0105)
  let got = snes.translatedVramAddr()
  let low = 0x0105'u16 and 0x1FF
  let rot = ((low shl 3) or (low shr 6)) and 0x1FF
  let want = (0x0105'u16 and not 0x1FF'u16) or rot
  doAssert got == want, &"trans2: got {got:04X} want {want:04X}"

block trans3TenBitRotate:
  ## bits 3-2 = 11: rotate low 10 bits left by 3.
  let snes = newSnesBus(newSeq[uint8](0x10000))
  setVmain(snes, 0x8C)  # trans=3
  setVmadd(snes, 0x03FF)
  let low = 0x03FF'u16 and 0x3FF
  let rot = ((low shl 3) or (low shr 7)) and 0x3FF
  let want = (0x03FF'u16 and not 0x3FF'u16) or rot
  doAssert snes.translatedVramAddr() == want,
    &"trans3: got {snes.translatedVramAddr():04X} want {want:04X}"
