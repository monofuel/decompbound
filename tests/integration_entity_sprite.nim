import
  decompbound/[asm_parse, cpu, rom_pipeline, snesbus]

const
  InitCaller = 0x0200'u32
  ProducerCaller = 0x0210'u32
  PublishCaller = 0x0220'u32
  PointerCaller = 0x0230'u32
  CallbackCaller = 0x0240'u32
  Operands = 0x7F6000'u32
  Wram = 0x7E0000'u32
  TableAddress = 0x4000
  DefinitionAddress = 0x5000
  QueueBases = [0x2404, 0x2506, 0x2608, 0x270A]
  StackTop = 0x1FFF'u16
  StepLimit = 1000
  Tile = 0xA7'u8
  Attributes = 0xD3'u8
  SpecialFrames = [127, 128, 255, 256]

proc putWord(snes: SnesBus, address: uint32, value: int) =
  ## Write a synthetic little-endian word to a chosen RAM bank.
  snes.bus.write8(address, (value and 255).uint8)
  snes.bus.write8(address + 1, ((value shr 8) and 255).uint8)

proc run(snes: SnesBus, caller: uint32, length: int, a = 0, x = 0,
    y = 0, expectedY = -1) =
  ## Execute a synthetic caller into the original ROM with native binary widths.
  var
    cpu = Cpu(pc: caller.uint16, s: StackTop, dbr: 0x7E,
      a: a.uint16, x: x.uint16, y: y.uint16)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != (caller + length.uint32).uint16:
    doAssert steps < StepLimit
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.s == StackTop and cpu.d == 0 and cpu.dbr == 0x7E
  if expectedY >= 0:
    doAssert cpu.y == expectedY.uint16

proc checkProducer(snes: SnesBus, bank, entity, frame, group: int) =
  ## Follow a selected frame pointer through enqueue and OAM publication.
  let
    base = bank.uint32 shl 16
    entityOffset = entity * 2
    selectedPointer = DefinitionAddress + frame * 5
    queue = Wram + QueueBases[group].uint32
  snes.putWord(Wram + 0x2E, 1)
  snes.run(InitCaller, 4)
  snes.putWord(Wram + 0x80, Operands.int and 0xFFFF)
  snes.bus.write8(Wram + 0x82, (Operands shr 16).uint8)
  snes.putWord(Wram + 0x88, entityOffset)
  snes.putWord(Wram + (0x116A + entityOffset).uint32, 0x5A00)
  snes.putWord(Operands, TableAddress)
  snes.bus.write8(Operands + 2, bank.uint8)
  snes.putWord(Operands + 3, 0xA0FA)
  snes.run(PointerCaller, 3, expectedY = 3)
  snes.run(CallbackCaller, 3, y = 3, expectedY = 5)
  doAssert snes.bus.read16(Wram + (0x112E + entityOffset).uint32) == TableAddress
  doAssert snes.bus.read16(Wram + (0x116A + entityOffset).uint32) == (0x5A00 + bank).uint16
  doAssert snes.bus.read16(Wram + (0x11E2 + entityOffset).uint32) == 0xA0FA
  snes.putWord(Wram + (0x10F2 + entityOffset).uint32, frame)
  snes.putWord(base + (TableAddress + frame * 2).uint32, selectedPointer)
  snes.putWord(Wram + (0x103E + entityOffset).uint32, group)
  snes.putWord(Wram + (0x0B8E + entityOffset).uint32, 40 + entity)
  snes.putWord(Wram + (0x0BCA + entityOffset).uint32, 80 + entity)
  snes.bus.write8(Wram + 0x0C, 0x5A)
  snes.bus.write8(base + selectedPointer.uint32, 255)
  snes.bus.write8(base + selectedPointer.uint32 + 1, Tile)
  snes.bus.write8(base + selectedPointer.uint32 + 2, Attributes)
  snes.bus.write8(base + selectedPointer.uint32 + 3, 254)
  snes.bus.write8(base + selectedPointer.uint32 + 4, 0x81)
  snes.run(ProducerCaller, 3, x = entityOffset)
  doAssert snes.bus.read16(queue) == selectedPointer.uint16
  doAssert snes.bus.read16(queue + 0x40) == (40 + entity).uint16
  doAssert snes.bus.read16(queue + 0x80) == (80 + entity).uint16
  doAssert snes.bus.read16(queue + 0xC0) == (0x5A00 + bank).uint16
  doAssert snes.bus.read16(Wram + 0x96) == selectedPointer.uint16
  for other in 0 ..< 4:
    doAssert snes.bus.read16(Wram + (QueueBases[other] + 0x100).uint32) ==
      (if other == group: 2'u16 else: 0'u16)
  snes.run(PublishCaller, 4)
  doAssert snes.bus.read8(Wram + 0x500) == (38 + entity).uint8
  doAssert snes.bus.read8(Wram + 0x501) == (78 + entity).uint8
  doAssert snes.bus.read8(Wram + 0x502) == Tile
  doAssert snes.bus.read8(Wram + 0x503) == Attributes
  doAssert snes.bus.read8(Wram + 0x505) == 0xE0
  doAssert snes.bus.read8(Wram + 0x700) == 2
  doAssert snes.bus.read16(Wram + 3) == 0x504

proc main() =
  ## Sweep entity offsets, frame indices, queue groups, and definition banks.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
  for mapping in [(0x1C, 0x9B4D), (0x22, 0x9BE4)]:
    let offset = 0x9558 + mapping[0] * 2
    doAssert gold[offset].int + (gold[offset + 1].int shl 8) == mapping[1]
  for entry in [(InitCaller, "JSL $C088B1"),
      (ProducerCaller, "JSR $A0E3"), (PublishCaller, "JSL $C08B26"),
      (PointerCaller, "JSR $9B4D"), (CallbackCaller, "JSR $9BE4")]:
    let code = assembleAsm(".a16\n.i16\n" & entry[1] & "\n", entry[0])
    for i, value in code:
      snes.bus.write8(entry[0] + i.uint32, value)
  for bank in [0x7E, 0x7F]:
    for entity in 0 ..< 30:
      for group in 0 ..< 4:
        for frame in 0 ..< 32:
          snes.checkProducer(bank, entity, frame, group)
        for frame in SpecialFrames:
          snes.checkProducer(bank, entity, frame, group)

when isMainModule:
  main()
