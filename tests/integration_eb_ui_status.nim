import
  decompbound/[asm_parse, cpu, ds_companion, eb_ui_frame, eb_ui_status, party_sram,
    party_wram, rom_pipeline, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  ConditionsAddress = 0x1000
  InstructionLimit = 10000

proc original(machine: SnesBus, conditions: EbConditions, target: string,
    argument = ConditionsAddress, x = 1, y = 0): uint16 =
  ## Call one original condition selector with an authored isolated input block.
  let code = assembleAsm(".a16\n.i16\nJSL " & target & "\n", Caller)
  for index, value in code:
    machine.bus.write8(Wram + Caller + index.uint32, value)
  for index, value in conditions:
    machine.bus.write8(Wram + ConditionsAddress.uint32 + index.uint32, value)
  var
    state = Cpu(pbr: 0x7E, pc: Caller.uint16, s: 0x1FFF, d: 0x0200,
      dbr: 0x7E, a: argument.uint16, x: x.uint16, y: y.uint16)
    steps = 0
  while state.pbr != 0x7E or state.pc != (Caller + code.len.uint32).uint16:
    doAssert steps < InstructionLimit, "Original condition selector did not return"
    state.step(machine.bus)
    inc steps
  state.a

proc check(machine: SnesBus, tables: EbUiStatusTables, conditions: EbConditions) =
  ## Compare both native condition selectors to their independent ROM routines.
  doAssert tables.conditionIcon(conditions) == machine.original(conditions, "$C223D9")
  doAssert tables.conditionPalette(conditions) == machine.original(conditions, "$C22474").int

proc putWord(machine: SnesBus, address, value: int) =
  ## Write an authored word into the oracle machine's WRAM.
  machine.bus.write8(Wram + address.uint32, uint8(value and 255))
  machine.bus.write8(Wram + address.uint32 + 1, uint8(value shr 8))

proc word(machine: SnesBus, address: int): uint16 =
  ## Read an original routine's output word without reimplementing its behavior.
  machine.bus.read16(Wram + address.uint32)

proc checkFrames(rom: seq[uint8], tables: EbUiStatusTables, machine: SnesBus) =
  ## Compare every status-frame tile with the original full-window constructor.
  var labels: array[8, uint8]
  for index in 0 ..< labels.len: labels[index] = rom[0x03E3F8 + index]
  for count in 1 .. PlayableCharCount:
    for slot in 0 ..< count:
      for nameLength in [1, 4, 5]:
        for palette in [0, 0x0400, 0x0800, 0x0C00]:
          let
            id = count - slot
            base = PartyCharTableWram + (id - 1) * CharStride
            selected = slot mod 2 == 0
          machine.bus.write8(Wram + PartyCountWram, count.uint8)
          machine.bus.write8(Wram + PartyRosterWram + slot.uint32, id.uint8)
          machine.putWord(0x89CA, if selected: slot else: 0xFFFF)
          for index in 0 ..< CharStride:
            machine.bus.write8(Wram + (base + index).uint32, 0)
          for index in 0 ..< nameLength:
            machine.bus.write8(Wram + (base + index).uint32, uint8(0x71 + index))
          machine.putWord(base + CharHpDisplayOff, 123)
          machine.putWord(base + CharPpDisplayOff, 45)
          machine.putWord(base + CharHpFractionOff, 0x6101)
          machine.putWord(base + CharPpFractionOff, 0x9501)
          machine.putWord(base + CharUiPaletteOff, palette)
          var conditions: EbConditions
          if palette != 0:
            conditions[palette div 0x0400] = 1
          for index, value in conditions:
            machine.bus.write8(Wram + (base + CharConditionsOff + index).uint32, value)
          discard machine.original(conditions, "$C207B6", slot)
          var hp, pp: EbMeterTiles
          for index in 0 ..< hp.len:
            hp[index] = machine.word(0x8969 + slot * 24 + index * 2)
            pp[index] = machine.word(0x8975 + slot * 24 + index * 2)
          let
            native = composeEbStatus(tables, labels, id, nameLength, palette.uint16,
              conditions, hp, pp)
            column = 16 - count * 7 div 2 + slot * 7
            row = if selected: 18 else: 19
            start = 0x7DFE + row * 64 + column * 2
          for y in 0 ..< native.len:
            for x in 0 ..< native[y].len:
              doAssert native[y][x] == machine.word(start + y * 64 + x * 2),
                "Original status-frame tile mismatch at " & $x & "," & $y

proc checkGoodsLayout(machine: SnesBus) =
  ## Compare every Goods position with the original two-column menu layout routine.
  machine.putWord(0x8958, 2)
  machine.putWord(0x88E8, 0)
  machine.putWord(0x8650 + 0x0A, 22)
  machine.putWord(0x8650 + 0x0C, 14)
  machine.putWord(0x8650 + 0x10, 0)
  machine.putWord(0x8650 + 0x2B, 0)
  for index in 0 ..< CharInventoryLen:
    let entry = 0x89D4 + index * 0x2D
    machine.putWord(entry, 1)
    machine.putWord(entry + 2, if index + 1 < CharInventoryLen: index + 1 else: 0xFFFF)
    machine.putWord(entry + 6, 1)
    machine.putWord(entry + 0x13, 0x0071)
  discard machine.original(default(EbConditions), "$C451FA", 2, 0)
  for index in 0 ..< CharInventoryLen:
    let
      entry = 0x89D4 + index * 0x2D
      position = goodsItemPosition(index)
    doAssert position.x == 32 + 16 + machine.word(entry + 8).int * 8
    doAssert position.y == 8 + 8 + machine.word(entry + 0x0A).int * 16

proc checkGoodsFrame(machine: SnesBus) =
  ## Compare the Goods border and small-header placement with original $C107AF.
  machine.putWord(0x8650 + 6, 4)
  machine.putWord(0x8650 + 8, 1)
  machine.putWord(0x8650 + 0x0A, 22)
  machine.putWord(0x8650 + 0x0C, 14)
  machine.putWord(0x8650 + 0x35, 0x4000)
  machine.putWord(0x5E7A, 0xFFFF)
  for length in 1 .. 5:
    machine.bus.write8(Wram + 0x868B, 1)
    for index in 0 .. 5:
      machine.bus.write8(Wram + 0x868C + index.uint32,
        uint8(if index < length: 0x71 else: 0))
    let start = 0x7DFE + 64 + 4 * 2
    for row in 0 .. 15:
      for column in 0 .. 23: machine.putWord(start + row * 64 + column * 2, 0)
    discard machine.original(default(EbConditions), "$C107AF", 0)
    let native = composeEbGoodsFrame(length)
    for row in 0 ..< native.len:
      for column in 0 ..< native[row].len:
        if native[row][column] != 0:
          doAssert native[row][column] == machine.word(start + row * 64 + column * 2),
            "Original Goods frame mismatch at " & $column & "," & $row

proc main() =
  ## Verify every table entry and competing conditions against original execution.
  let
    rom = readGoldBaserom()
    tables = loadEbUiStatusTables(rom)
    machine = newSnesBus(rom)
  var conditions: EbConditions
  machine.check(tables, conditions)
  for group in 0 ..< conditions.len:
    for value in 1 .. conditions.len:
      conditions = default(EbConditions)
      conditions[group] = value.uint8
      machine.check(tables, conditions)
      for otherGroup in 0 ..< conditions.len:
        if otherGroup == group: continue
        conditions[otherGroup] = 1
        machine.check(tables, conditions)
        conditions[otherGroup] = 0
  checkFrames(rom, tables, machine)
  checkGoodsLayout(machine)
  checkGoodsFrame(machine)

main()
