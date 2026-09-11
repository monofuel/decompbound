import
  decompbound/[asm_parse, cpu, memmap, rom_pipeline, snesbus]

const
  Wram = 0x7E0000'u32
  Pool = 0x467E'u32
  PoolSize = 0x380
  DirectPage = 0x1000'u16
  Caller = 0x1E00'u32
  StepLimit = 20000

proc putWord(snes: SnesBus, address: uint32, value: int) =
  ## Write a private WRAM word for a routine entry contract.
  snes.bus.write8(Wram + address, (value and 255).uint8)
  snes.bus.write8(Wram + address + 1, ((value shr 8) and 255).uint8)

proc runUntil(snes: SnesBus, cpu: var Cpu, bank: uint8, pc: uint16) =
  ## Execute original pool code to a specified return address.
  var steps = 0
  while cpu.pbr != bank or cpu.pc != pc:
    doAssert steps < StepLimit
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.d == DirectPage and cpu.dbr == 0x7E and cpu.s == 0x1FFF
  doAssert (cpu.p and (FlagM or FlagX)) == 0

proc call(snes: SnesBus, address: string, a = 0): uint16 =
  ## Call a pool helper using the same native, decimal-clear context.
  let code = assembleAsm(".a16\n.i16\nJSL " & address & "\n", Caller)
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  var cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: DirectPage, dbr: 0x7E, a: a.uint16)
  snes.runUntil(cpu, 0, (Caller + 4).uint16)
  cpu.a

proc checkSearch(snes: SnesBus, count, pattern: int) =
  ## Compare unmarked free-run discovery against record flags and the strict limit.
  let size = count * 10
  var before: array[PoolSize + 5, uint8]
  for index in 0 ..< before.len:
    before[index] = 0x39
    if index mod 5 == 4:
      let record = index div 5
      if (pattern < 5 and record >= [0, 1, 7, 100, 178][pattern]) or
          (pattern == 5 and record mod 11 != 3) or (pattern == 7 and record == 179):
        before[index] = 0xFF
    snes.bus.write8(Wram + Pool + index.uint32, before[index])
  var expected = 0xFF01
  for start in countup(0, PoolSize - 1, 5):
    if before[start + 4] != 0xFF:
      continue
    if start + size >= PoolSize:
      expected = 0xFF02
      break
    var free = true
    for offset in countup(start, start + size - 1, 5):
      if before[offset + 4] != 0xFF:
        free = false
    if free:
      expected = start
      break
  doAssert snes.call("$C01A9D", size) == expected.uint16
  doAssert snes.bus.read16(Wram + 0x4A6A) == size.uint16
  for index, value in before:
    doAssert snes.bus.read8(Wram + Pool + index.uint32) == value

proc checkResource(snes: SnesBus, gold: seq[uint8], resourceId: int) =
  ## Find space, build both real variants, release them, and find the same space again.
  let
    pointer = 0x2F133F + resourceId * 4
    resourceAddress = gold[pointer].uint32 or (gold[pointer + 1].uint32 shl 8) or
      (gold[pointer + 2].uint32 shl 16)
    resource = snesToFile(resourceAddress)
    layoutPointer = 0x042B0D + gold[resource + 2].int * 4
    layoutAddress = gold[layoutPointer].uint32 or (gold[layoutPointer + 1].uint32 shl 8) or
      (gold[layoutPointer + 2].uint32 shl 16)
    layout = snesToFile(layoutAddress)
    count = gold[layout].int
    size = count * 10
  snes.bus.write8(Wram + Pool - 1, 0x69)
  snes.bus.write8(Wram + Pool + PoolSize.uint32, 0x96)
  discard snes.call("$C01A86")
  for index in 0 ..< PoolSize:
    doAssert snes.bus.read8(Wram + Pool + index.uint32) == 0xFF
  for index in 0 ..< 15:
    snes.bus.write8(Wram + Pool + index.uint32, 0x39)
  let offset = snes.call("$C01A9D", size)
  doAssert offset == 15
  snes.putWord(0x100E, (layoutAddress and 0xFFFF).int)
  snes.putWord(0x1010, (layoutAddress shr 16).int)
  snes.putWord(0x1FFE, Caller.int - 1)
  var builder = Cpu(pbr: 0xC0, pc: 0x1D38, s: 0x1FFD, d: DirectPage,
    dbr: 0x7E, a: offset, y: gold[resource + 3].uint16)
  snes.runUntil(builder, 0xC0, Caller.uint16)
  doAssert snes.call("$C01A9D", size) == (15 + size).uint16
  discard snes.call("$C01B15", Pool.int + offset.int)
  for index in 0 ..< PoolSize:
    doAssert snes.bus.read8(Wram + Pool + index.uint32) ==
      (if index < 15: 0x39'u8 else: 0xFF'u8)
  doAssert snes.call("$C01A9D", size) == offset
  doAssert snes.bus.read8(Wram + Pool - 1) == 0x69
  doAssert snes.bus.read8(Wram + Pool + PoolSize.uint32) == 0x96

proc main() =
  ## Verify definition storage separately from the VRAM tile-slot pool.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
  for count in 1 .. 20:
    for pattern in 0 .. 7:
      snes.checkSearch(count, pattern)
  for resource in 0 ..< 464:
    snes.checkResource(gold, resource)

when isMainModule:
  main()
