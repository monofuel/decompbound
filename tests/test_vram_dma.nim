import
  decompbound/[cpu, snesbus]

const
  SourceBank = 0x7F'u8
  SourceBase = 0x7F0000
  DmaEnable = 0x420B'u32
  VramLowPort = 0x18'u8
  WordTransferMode = 1'u8
  IncrementAfterHigh = 0x80'u8
  TranslatedAddressMode = 0x04'u8
  FullTransferBytes = 48 * 1024
  TranslatedTransferBytes = 24 * 1024
  LowByte = 0x5A'u8
  HighByte = 0xA5'u8
  ExpectedWord = 0xA55A'u16

proc checkTransfer(size: int, vmain: uint8) =
  ## Execute a large legal DMA through MMIO and verify every VRAM word.
  let snes = newSnesBus(@[])
  for offset in 0 ..< size:
    snes.bus.mem[SourceBase + offset] = if offset mod 2 == 0: LowByte else: HighByte
  snes.bus.write8(0x2115, vmain)
  snes.dmaRegs[0] = WordTransferMode
  snes.dmaRegs[1] = VramLowPort
  snes.dmaRegs[4] = SourceBank
  snes.dmaRegs[5] = (size and 255).uint8
  snes.dmaRegs[6] = (size shr 8).uint8
  snes.bus.write8(DmaEnable, 1)
  for word in 0 ..< size div 2:
    doAssert snes.vram[word] == ExpectedWord
  doAssert snes.vram[size div 2] == 0
  doAssert snes.dmaRegs[5] == 0 and snes.dmaRegs[6] == 0

checkTransfer(FullTransferBytes, IncrementAfterHigh)
checkTransfer(TranslatedTransferBytes, IncrementAfterHigh or TranslatedAddressMode)
