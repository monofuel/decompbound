import
  decompbound/[asm_parse, cpu, eb_ui_meters, rom_pipeline, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u16
  CallerBank = 0xC2'u8
  DirectPage = 0x0200
  ConditionsAddress = 0x1000
  StepLimit = 10000
  Fractions = [0, 0x2FFF, 0x3000, 0x63FF, 0x6400, 0x97FF, 0x9800,
    0xCBFF, 0xCC00, 0xFFFF]

proc putWord(machine: SnesBus, address, value: int) =
  ## Initialize a generated register parameter or condition in isolated WRAM.
  machine.bus.write8(Wram + address.uint32, uint8(value and 255))
  machine.bus.write8(Wram + address.uint32 + 1, uint8(value shr 8))

proc original(machine: SnesBus, value, fraction, slot: int, pp, hidden: bool): array[6, uint16] =
  ## Execute the original HP or PP helper through an authored bank-local caller.
  let
    instruction = if pp: "JSR $0F26" else: "JSR $0F08"
    code = assembleAsm(".a16\n.i16\n" & instruction & "\n", Caller.uint32)
  for index, byte in code:
    machine.bus.mem[(CallerBank.int shl 16) + Caller.int + index] = byte
  machine.putWord(DirectPage + 0x0E, fraction)
  machine.bus.write8(Wram + ConditionsAddress + 4, uint8(ord(hidden)))
  var
    state = Cpu(pbr: CallerBank, pc: Caller, dbr: 0x7E, d: DirectPage, s: 0x1FFF,
      a: slot.uint16, x: uint16(if pp: ConditionsAddress else: value),
      y: uint16(if pp: value else: fraction))
    steps = 0
  while state.pbr != CallerBank or state.pc != Caller + code.len.uint16:
    doAssert steps < StepLimit, "Original meter helper did not return"
    state.step(machine.bus)
    inc steps
  let address = (if pp: PpMeterWordsBase else: MeterWordsBase) + slot * SlotStride
  for index in 0 ..< result.len:
    result[index] = machine.bus.read16(Wram + (address + index * 2).uint32)

proc main() =
  ## Verify every displayed number and digit-phase boundary against both helpers.
  let
    rom = readGoldBaserom()
    machine = newSnesBus(rom)
  for value in 0 .. MaxMeterValue:
    for fraction in Fractions:
      let expected = ebMeterWords(value, fraction)
      doAssert machine.original(value, fraction, value mod 4, false, false) == expected
      doAssert machine.original(value, fraction, value mod 4, true, false) == expected
  for value in [0, 9, 99, 999]:
    for fraction in Fractions:
      doAssert machine.original(value, fraction, 0, true, true) == ebPpHideWords()

main()
