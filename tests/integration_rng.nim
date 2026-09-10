import
  std/strformat,
  decompbound/[adopted, asm_parse, cpu, rng_oracle, rom_pipeline, snesbus]

const
  RngRoutineLen = 56
  SeedAddress = 0x7E0024'u32
  CallerAddress = 0x0200'u16
  ReturnAddress = CallerAddress + 4
  InitialStack = 0x1FFF'u16
  StepLimit = 64
  BoundaryWords = [0x0000'u16, 0x0001, 0x007F, 0x0080, 0x00FF,
    0x0100, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]

proc writeSeed(snes: SnesBus, seed: uint32) =
  ## Install a synthetic seed in the RAM accessed by the original routine.
  for i in 0 ..< 4:
    snes.bus.write8(SeedAddress + i.uint32, uint8((seed shr (8 * i)) and 0xFF))

proc readSeed(snes: SnesBus): uint32 =
  ## Read the resulting little-endian seed through the SNES bus.
  for i in 0 ..< 4:
    result = result or (snes.bus.read8(SeedAddress + i.uint32).uint32 shl (8 * i))

proc execute(snes: SnesBus, seed: uint32, status: uint8): Cpu =
  ## Call the ROM routine in native mode and check its return contract.
  writeSeed(snes, seed)
  result = Cpu(pc: CallerAddress, s: InitialStack, p: status,
    x: 0x005A, y: 0x00A5)
  var steps = 0
  while result.pbr != 0 or result.pc != ReturnAddress:
    doAssert steps < StepLimit, "RNG call did not return"
    result.step(snes.bus)
    inc steps
  doAssert result.s == InitialStack
  doAssert result.p == status
  doAssert result.x == 0x005A and result.y == 0x00A5
  doAssert result.d == 0 and result.dbr == 0

proc checkStep(snes: SnesBus, seed: uint32, status: uint8) =
  ## Compare the pure oracle with the original CPU instructions and multiplier.
  let
    predicted = advanceSeed(seed)
    actual = execute(snes, seed, status)
    observedSeed = readSeed(snes)
  doAssert observedSeed == predicted.seed and actual.a == predicted.value.uint16,
    &"seed={seed:08X} P={status:02X}: got {observedSeed:08X}/{actual.a:04X}, " &
      &"expected {predicted.seed:08X}/{predicted.value:02X}"
  let product = (seed and 0xFF) * ((seed shr 16) and 0xFF)
  doAssert actual.a == uint16((product shr 4) and 0xFF),
    "Return byte must equal product bits 4 through 11"

proc main() =
  ## Verify assembly identity and binary-mode arithmetic without a saved game.
  let
    gold = readGoldBaserom()
    curated = earthboundRandom()
    snes = newSnesBus(gold)
    caller = assembleAsm(".a16\n.i16\nJSL $C08E9A\n", CallerAddress.uint32)
  doAssert curated.len == RngRoutineLen
  doAssert curated == gold[RngAdvanceOffset ..< RngAdvanceOffset + RngRoutineLen]
  for i, value in caller:
    snes.bus.write8(CallerAddress.uint32 + i.uint32, value)

  for loByte in 0 .. 255:
    for hiByte in 0 .. 255:
      checkStep(snes, seedFromWords(loByte.uint16, hiByte.uint16), 0)
  for lo in BoundaryWords:
    for hi in BoundaryWords:
      for status in 0 .. 255:
        if (status.uint8 and FlagD) == 0:
          checkStep(snes, seedFromWords(lo, hi), status.uint8)

  discard execute(snes, 0, FlagD)
  doAssert readSeed(snes) != advanceSeed(0).seed,
    "Decimal mode must not be mistaken for the binary oracle contract"

when isMainModule:
  main()
