import
  decompbound/[adopted, asm_parse, cpu, memmap, rom_pipeline, snesbus]

const
  Caller = 0x1E00'u32
  Wram = 0x7E0000'u32
  SlotCount = 88
  Occupancy = 0x4A00'u32
  Sentinel = 0x5A5A'u16
  StepLimit = 20000
  Prefixes = [0, 7, 8, 15, 16, 70, 87, -1]

proc runUntil(snes: SnesBus, cpu: var Cpu, bank: uint8, pc: uint16) =
  ## Execute original allocation or queue code to a known boundary.
  var steps = 0
  while cpu.pbr != bank or cpu.pc != pc:
    doAssert steps < StepLimit
    cpu.step(snes.bus)
    inc steps

proc checkAllocation(snes: SnesBus, width, height, prefix, owner: int,
    immediate: bool, resourceId = -1) =
  ## Compare first-fit allocation and clearing with an independent slot model.
  let
    columns = (width + 1) div 2
    rows = (height + 1) div 2
    needed = columns * rows
    clears = width mod 2 != 0 or height mod 2 != 0
  var
    occupied: array[SlotCount, uint8]
    first = -1
  for index in 0 ..< SlotCount:
    occupied[index] = if (prefix >= 0 and index < prefix) or
        (prefix < 0 and index mod 11 == 3): 0x91'u8 else: 0'u8
    snes.bus.write8(Wram + Occupancy + index.uint32, occupied[index])
  for candidate in 0 .. SlotCount - needed:
    var available = true
    for index in candidate ..< candidate + needed:
      if occupied[index] != 0:
        available = false
    if available:
      first = candidate
      break
  snes.bus.write8(Wram + Occupancy - 1, 0x69)
  snes.bus.write8(Wram + Occupancy + SlotCount.uint32, 0x96)
  snes.initHdma()
  snes.bus.write8(Wram, 0)
  snes.bus.write8(Wram + 1, 0)
  snes.bus.write8(Wram + 0x99, 0)
  snes.bus.write8(Wram + 0x9A, 0)
  snes.bus.write8(Wram + 0x0D, (if immediate: 0x80'u8 else: 0'u8))
  for value in snes.vram.mitems:
    value = Sentinel
  let transfers = snes.dmaTransfers
  var cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x1000, dbr: 0x7E,
    a: width.uint16, x: height.uint16, y: owner.uint16)
  if resourceId < 0:
    snes.runUntil(cpu, 0, (Caller + 4).uint16)
  else:
    snes.bus.write8(Wram + 0x102B, (resourceId and 255).uint8)
    snes.bus.write8(Wram + 0x102C, (resourceId shr 8).uint8)
    snes.bus.write8(Wram + 0x1004, owner.uint8)
    snes.bus.write8(Wram + 0x1005, 0)
    cpu.pbr = 0xC0
    cpu.pc = 0x1EA0
    snes.runUntil(cpu, 0xC0, 0x1EB3)
    doAssert snes.bus.read16(Wram + 0x467A) == width.uint16
    doAssert snes.bus.read16(Wram + 0x467C) == height.uint16
  doAssert cpu.a == (if first < 0: 0xFF03'u16 else: first.uint16)
  doAssert cpu.d == 0x1000 and cpu.dbr == 0x7E and cpu.s == 0x1FFF
  doAssert (cpu.p and (FlagM or FlagX)) == 0
  for index in 0 ..< SlotCount:
    let expected = if first >= 0 and index >= first and index < first + needed:
      (owner or 0x80).uint8 else: occupied[index]
    doAssert snes.bus.read8(Wram + Occupancy + index.uint32) == expected
  doAssert snes.bus.read8(Wram + Occupancy - 1) == 0x69
  doAssert snes.bus.read8(Wram + Occupancy + SlotCount.uint32) == 0x96
  if not immediate:
    doAssert snes.dmaTransfers == transfers
    for value in snes.vram:
      doAssert value == Sentinel
    var interrupt = Cpu(pbr: 0xC0, pc: 0x8238, s: 0x1FFF)
    snes.runUntil(interrupt, 0xC0, 0x8278)
  var expected: array[0x8000, uint16]
  for value in expected.mitems:
    value = Sentinel
  if first >= 0 and clears:
    for slot in first ..< first + needed:
      let base = 0x4000 + (slot div 8) * 0x200 + (slot mod 8) * 0x20
      for row in 0 .. 1:
        for word in 0 ..< 32:
          expected[base + row * 0x100 + word] = 0
  doAssert snes.vram == expected
  let groups = if first < 0 or not clears: 0 else:
    (first + needed - 1) div 8 - first div 8 + 1
  doAssert snes.dmaTransfers == transfers + groups * 2
  doAssert not snes.dmaStorm

proc checkSlotCounts(snes: SnesBus) =
  ## Cover every supported count and occupied-prefix length directly.
  let code = assembleAsm(".a16\n.i16\nJSL $C01B96\n", Caller)
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  for count in 1 .. SlotCount:
    for prefix in 0 .. SlotCount:
      for owner in [0, 0x7F, 0xFF]:
        for index in 0 ..< SlotCount:
          snes.bus.write8(Wram + Occupancy + index.uint32,
            (if index < prefix: 0x91'u8 else: 0'u8))
        snes.bus.write8(Wram + Occupancy - 1, 0x69)
        snes.bus.write8(Wram + Occupancy + SlotCount.uint32, 0x96)
        let fits = prefix + count <= SlotCount
        var cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x1000, dbr: 0x7E,
          a: count.uint16, x: owner.uint16)
        snes.runUntil(cpu, 0, (Caller + 4).uint16)
        doAssert cpu.a == (if fits: prefix.uint16 else: 0xFF03'u16)
        doAssert cpu.d == 0x1000 and cpu.dbr == 0x7E and cpu.s == 0x1FFF
        doAssert (cpu.p and (FlagM or FlagX)) == 0
        for index in 0 ..< SlotCount:
          let expected = if index < prefix: 0x91'u8
            elif fits and index < prefix + count: (owner or 0x80).uint8
            else: 0'u8
          doAssert snes.bus.read8(Wram + Occupancy + index.uint32) == expected
        doAssert snes.bus.read8(Wram + Occupancy - 1) == 0x69
        doAssert snes.bus.read8(Wram + Occupancy + SlotCount.uint32) == 0x96

proc main() =
  ## Exercise odd/even dimensions, fragmented occupancy, boundaries, and DMA modes.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
    code = assembleAsm(".a16\n.i16\nJSL $C01C52\n", Caller)
  doAssert assembleAdoptedFile("allocateSpriteSlots", 0x001B96) == gold[0x001B96 ..< 0x001C11]
  snes.checkSlotCounts()
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  for width in 1 .. 8:
    for height in 1 .. 8:
      for prefix in Prefixes:
        for owner in [0, 0x7F, 0xFF]:
          for immediate in [false, true]:
            snes.checkAllocation(width, height, prefix, owner, immediate)
  for resourceId in 0 ..< 464:
    let
      pointer = 0x2F133F + resourceId * 4
      address = gold[pointer].uint32 or (gold[pointer + 1].uint32 shl 8) or
        (gold[pointer + 2].uint32 shl 16)
      resource = snesToFile(address)
      width = gold[resource + 1].int shr 4
      height = gold[resource].int
    for immediate in [false, true]:
      snes.checkAllocation(width, height, 7, 0x21, immediate, resourceId)

when isMainModule:
  main()
