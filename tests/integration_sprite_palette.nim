import
  decompbound/[asm_parse, cpu, rom_pipeline, snesbus]

const
  Caller = 0x1E00'u32
  Wram = 0x7E0000'u32
  PaletteBuffer = 0x0200'u32
  ObjPaletteFile = 0x030000
  Sentinel = 0x1234'u16
  StepLimit = 2000

proc runUntil(snes: SnesBus, cpu: var Cpu, bank: uint8, pc: uint16) =
  ## Execute original code up to a specified fragment boundary.
  var steps = 0
  while cpu.pbr != bank or cpu.pc != pc:
    doAssert steps < StepLimit
    cpu.step(snes.bus)
    inc steps

proc checkUpload(snes: SnesBus, request: int) =
  ## Check the request latch, original interrupt DMA, and untouched colors.
  for color in snes.cgram.mitems:
    color = Sentinel
  snes.bus.write8(Wram + 0x31, 0xA5)
  snes.bus.write8(Wram + 0x99, 7)
  snes.bus.write8(Wram + 0x9A, 0)
  var caller = Cpu(pc: Caller.uint16, s: 0x1FFF,
    a: (0xAB00 or request).uint16, p: FlagM)
  snes.runUntil(caller, 0, (Caller + 4).uint16)
  doAssert caller.a == (0xAB00 or request).uint16
  doAssert (caller.p and FlagM) == 0
  doAssert caller.s == 0x1FFF
  doAssert snes.bus.read8(Wram + 0x30) == request.uint8
  let
    transfers = snes.dmaTransfers
    first = if request == 16: 128 else: 0
    count = if request == 0: 0 elif request == 24: 256 else: 128
  var interrupt = Cpu(pbr: 0xC0, pc: 0x81C8, s: 0x1FFF, p: FlagX)
  snes.runUntil(interrupt, 0xC0, 0x81F7)
  doAssert snes.bus.read8(Wram + 0x30) == 0
  doAssert snes.bus.read8(Wram + 0x31) == 0xA5
  doAssert snes.bus.read16(Wram + 0x99) == (7 + count * 2).uint16
  doAssert snes.dmaTransfers == transfers + (if count == 0: 0 else: 1)
  for index in 0 ..< 256:
    let expected = if index >= first and index < first + count:
      snes.bus.read16(Wram + PaletteBuffer + (index * 2).uint32)
    else: Sentinel
    doAssert snes.cgram[index] == expected
  interrupt.pc = 0x81C8
  snes.runUntil(interrupt, 0xC0, 0x81F7)
  doAssert snes.dmaTransfers == transfers + (if count == 0: 0 else: 1)

proc main() =
  ## Verify synthetic palette ranges and the original baseline OBJ palette copy.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
    code = assembleAsm(".a16\n.i16\nJSL $C0856B\n", Caller)
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  for pattern in 0 ..< 16:
    for index in 0 ..< 256:
      let color = ((index * 113 + pattern * 997) and 0x7FFF).uint16
      snes.bus.write8(Wram + PaletteBuffer + (index * 2).uint32, (color and 255).uint8)
      snes.bus.write8(Wram + PaletteBuffer + (index * 2 + 1).uint32, (color shr 8).uint8)
    for request in [0, 8, 16, 24]:
      snes.checkUpload(request)
  snes.bus.write8(Wram + 0x2FF, 0x5A)
  snes.bus.write8(Wram + 0x400, 0xA5)
  var copy = Cpu(pbr: 0xC0, pc: 0xB55B, s: 0x1FFF, d: 0x1000, dbr: 0x7E)
  snes.runUntil(copy, 0xC0, 0xB56F)
  doAssert copy.s == 0x1FFF and copy.d == 0x1000 and copy.dbr == 0x7E
  for index in 0 ..< 256:
    doAssert snes.bus.read8(Wram + 0x300 + index.uint32) == gold[ObjPaletteFile + index]
  doAssert snes.bus.read8(Wram + 0x2FF) == 0x5A
  doAssert snes.bus.read8(Wram + 0x400) == 0xA5
  snes.checkUpload(16)

when isMainModule:
  main()
