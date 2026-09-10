import
  decompbound/[adopted, asm_parse, cpu, rom_pipeline, snesbus]

const
  RoutineOffset = 0x0088B1
  RoutineLength = 616
  CallerAddress = 0x0200'u32
  ReturnAddress = 0x0204'u16
  StackTop = 0x1FFF'u16
  WramBank = 0x7E0000'u32
  BufferBegin = 0x0500
  BufferEnd = 0x0B00
  LowTableSize = 512
  Sentinel = 0x5A'u8
  HiddenY = 0xE0'u8
  QueueCounts = [0x2504'u32, 0x2606, 0x2708, 0x280A]
  Selectors = [0'u16, 1, 2, 3, 0xFFFF]
  Accumulators = [0'u16, 0xFFFF, 0xA55A]
  StepLimit = 180

proc checkBuild(snes: SnesBus, selector, accumulator: uint16, status: uint8) =
  ## Verify both OAM buffers and register preservation against original code.
  for offset in BufferBegin ..< BufferEnd:
    snes.bus.write8(WramBank + offset.uint32, Sentinel)
  for address in QueueCounts:
    snes.bus.write8(WramBank + address, Sentinel)
    snes.bus.write8(WramBank + address + 1, Sentinel)
  snes.bus.write8(WramBank + 0x2E, (selector and 0xFF).uint8)
  snes.bus.write8(WramBank + 0x2F, (selector shr 8).uint8)
  snes.bus.write8(WramBank + 9, Sentinel)
  let
    base = if selector == 1: 0x0500 else: 0x0800
    initialY = if (status and FlagX) == 0: 0xBEEF'u16 else: 0xEF'u16
  var
    cpu = Cpu(pc: CallerAddress.uint16, s: StackTop, dbr: 0x7E,
      d: 0x1234, a: accumulator, y: initialY, p: status)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != ReturnAddress:
    doAssert steps < StepLimit
    cpu.step(snes.bus)
    inc steps
  for offset in BufferBegin ..< BufferEnd:
    let expected =
      if offset >= base and offset < base + LowTableSize and
          (offset - base) mod 4 == 1: HiddenY
      else: Sentinel
    doAssert snes.bus.read8(WramBank + offset.uint32) == expected
  for address in QueueCounts:
    doAssert snes.bus.read16(WramBank + address) == 0
  doAssert snes.bus.read16(WramBank + 3) == base.uint16
  doAssert snes.bus.read16(WramBank + 5) == (base + LowTableSize).uint16
  doAssert snes.bus.read16(WramBank + 7) == (base + LowTableSize).uint16
  doAssert snes.bus.read8(WramBank + 9) == Sentinel
  doAssert snes.bus.read8(WramBank + 10) == 0x80
  doAssert snes.bus.read16(WramBank + 0x2E) == selector
  doAssert cpu.s == StackTop and cpu.d == 0x1234 and cpu.dbr == 0x7E
  doAssert cpu.a == ((accumulator and 0xFF00) or HiddenY.uint16)
  doAssert cpu.x == (base + LowTableSize).uint16 and cpu.y == initialY
  doAssert (cpu.p and (FlagM or FlagX)) == 0
  let preserved = FlagC or FlagD or FlagV
  doAssert (cpu.p and preserved) == (status and preserved)

proc main() =
  ## Compare adopted assembly and run all selector/status cases on the gold ROM.
  let
    gold = readGoldBaserom()
    code = assembleAdoptedFile("initializeOamBuild", RoutineOffset)
    snes = newSnesBus(gold)
    caller = assembleAsm(".a16\n.i16\nJSL $C088B1\n", CallerAddress)
  doAssert code.len == RoutineLength
  doAssert code == gold[RoutineOffset ..< RoutineOffset + RoutineLength]
  for i, value in caller:
    snes.bus.write8(CallerAddress + i.uint32, value)
  for selector in Selectors:
    for accumulator in Accumulators:
      for status in 0 .. 255:
        checkBuild(snes, selector, accumulator, status.uint8)

when isMainModule:
  main()
