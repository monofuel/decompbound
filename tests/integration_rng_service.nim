import
  decompbound/[adopted, asm_parse, cpu, rng_oracle, rom_pipeline, snesbus]

const
  CallerAddress = 0x0200'u16
  ReturnAddress = CallerAddress + 4
  InitialStack = 0x1FFF'u16
  ServiceBank = 0xC1'u8
  LongerPath = 0x2DF2'u16
  RngBank = 0xC0'u8
  RngEntry = 0x8E9A'u16
  SeedAddress = 0x7E0024'u32
  FirstGate = 0x7E968C'u32
  SecondGate = 0x7E9622'u32
  SyntheticSeed = 0x56781234'u32
  NeighborSentinel = 0xA5'u8
  StepLimit = 80
  SetterInputs = [0x0000'u16, 0x00FF, 0xFF00, 0xA55A]

proc readSeed(snes: SnesBus): uint32 =
  ## Read the seed changed by the original service and RNG routines.
  for i in 0 ..< 4:
    result = result or (snes.bus.read8(SeedAddress + i.uint32).uint32 shl (8 * i))

proc checkGates(snes: SnesBus, first, second: uint8) =
  ## Check early exits and their byte-wide side effects using synthetic RAM.
  for i in 0 ..< 4:
    snes.bus.write8(SeedAddress + i.uint32,
      uint8((SyntheticSeed shr (8 * i)) and 0xFF))
  snes.bus.write8(FirstGate, first)
  snes.bus.write8(SecondGate, second)
  snes.bus.write8(FirstGate + 1, NeighborSentinel)
  snes.bus.write8(SecondGate + 1, NeighborSentinel)
  var
    cpu = Cpu(pc: CallerAddress, s: InitialStack, dbr: 0x7E,
      p: FlagM or FlagX or FlagC, x: 0x5A, y: 0xA5)
    steps = 0
    draws = 0
  while cpu.pbr != 0 or cpu.pc != ReturnAddress:
    if first == 0 and second == 0 and
        cpu.pbr == ServiceBank and cpu.pc == LongerPath:
      break
    doAssert steps < StepLimit, "Service failed to reach its selected exit"
    if cpu.pbr == RngBank and cpu.pc == RngEntry:
      inc draws
    cpu.step(snes.bus)
    inc steps
  doAssert draws == 1
  doAssert readSeed(snes) == advanceSeed(SyntheticSeed).seed
  doAssert snes.bus.read8(FirstGate) == 0
  doAssert snes.bus.read8(SecondGate) == second
  doAssert snes.bus.read8(FirstGate + 1) == NeighborSentinel
  doAssert snes.bus.read8(SecondGate + 1) == NeighborSentinel
  doAssert cpu.x == 0x5A and cpu.y == 0xA5 and cpu.dbr == 0x7E
  doAssert (cpu.p and (FlagM or FlagX)) == 0
  if first != 0 or second != 0:
    doAssert cpu.s == InitialStack
    doAssert cpu.a == (if first != 0: first.uint16 else: second.uint16)
  else:
    doAssert cpu.pbr == ServiceBank and cpu.pc == LongerPath

proc checkSetter(snes: SnesBus, value: uint8) =
  ## Verify byte writes and register/status contracts for both flag setters.
  for status in 0 .. 255:
    for accumulator in SetterInputs:
      let
        initialX = if (status.uint8 and FlagX) == 0: 0xBEEF'u16 else: 0xEF'u16
        initialY = if (status.uint8 and FlagX) == 0: 0xCAFE'u16 else: 0xFE'u16
      snes.bus.write8(SecondGate, NeighborSentinel)
      snes.bus.write8(SecondGate + 1, NeighborSentinel)
      var
        cpu = Cpu(pc: CallerAddress, s: InitialStack, dbr: 0x7E,
          d: 0x3456, a: accumulator, x: initialX, y: initialY, p: status.uint8)
        steps = 0
      while cpu.pbr != 0 or cpu.pc != ReturnAddress:
        doAssert steps < StepLimit
        cpu.step(snes.bus)
        inc steps
      doAssert snes.bus.read8(SecondGate) == value
      doAssert snes.bus.read8(SecondGate + 1) == NeighborSentinel
      doAssert cpu.s == InitialStack and cpu.d == 0x3456 and cpu.dbr == 0x7E
      doAssert cpu.x == initialX and cpu.y == initialY
      let cleared = FlagM or FlagX or FlagC
      if value == 0:
        doAssert cpu.a == accumulator
        doAssert cpu.p == (status.uint8 and not cleared)
      else:
        doAssert cpu.a == ((accumulator and 0xFF00) or 1)
        doAssert cpu.p == (status.uint8 and not (cleared or FlagN or FlagZ))

proc main() =
  ## Exercise every gate-byte pair without entering the unresolved service path.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
    caller = assembleAsm(".a16\n.i16\nJSL $C12DD5\n", CallerAddress.uint32)
  for i, value in caller:
    snes.bus.write8(CallerAddress.uint32 + i.uint32, value)
  for first in 0 .. 255:
    for second in 0 .. 255:
      checkGates(snes, first.uint8, second.uint8)

  for spec in [("clearServiceSuppression", 0x03E4CA, 10, 0'u8, "$C3E4CA"),
               ("setServiceSuppression", 0x03E4D4, 12, 1'u8, "$C3E4D4")]:
    let
      code = assembleAdoptedFile(spec[0], spec[1])
      setterCaller = assembleAsm(".a16\n.i16\nJSL " & spec[4] & "\n",
        CallerAddress.uint32)
    doAssert code.len == spec[2]
    doAssert code == gold[spec[1] ..< spec[1] + spec[2]]
    for i, value in setterCaller:
      snes.bus.write8(CallerAddress.uint32 + i.uint32, value)
    checkSetter(snes, spec[3])

when isMainModule:
  main()
