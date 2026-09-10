import
  decompbound/[adopted, cpu, memmap, rom_pipeline, snesbus]

const
  ReturnPc = 0x1E00'u16
  DirectPage = 0x0200'u16
  Layout = 0x7F4000'u32
  Output = 0x7E477E'u32
  AllocationOffset = 0x100
  TileMapOffset = 0x04303C
  Counts = [0, 1, 2, 4, 8]
  Slots = [0, 1, 7, 16, 31]
  Modifiers = [0, 1, 0x0E, 0x80, 0xFF]
  Sentinel = 0x5A'u8
  StepLimit = 6000
  ResourceTableOffset = 0x2F133F
  ResourceCount = 464
  LayoutTableOffset = 0x042B0D

proc runBuilder(snes: SnesBus, slot, modifier: int): Cpu =
  ## Execute the original builder with a synthetic same-bank return frame.
  snes.bus.write8(0x1FFE, ((ReturnPc - 1) and 255).uint8)
  snes.bus.write8(0x1FFF, ((ReturnPc - 1) shr 8).uint8)
  result = Cpu(pbr: 0xC0, pc: 0x1D38, s: 0x1FFD, d: DirectPage,
    dbr: 0x7E, a: AllocationOffset, x: slot.uint16, y: modifier.uint16)
  var steps = 0
  while result.pbr != 0xC0 or result.pc != ReturnPc:
    doAssert steps < StepLimit
    result.step(snes.bus)
    inc steps

proc putWord(snes: SnesBus, address: uint32, value: int) =
  ## Write a synthetic RAM word.
  snes.bus.write8(address, (value and 255).uint8)
  snes.bus.write8(address + 1, ((value shr 8) and 255).uint8)

proc checkLayout(snes: SnesBus, gold: seq[uint8], count, slot,
    attribute, modifier: int) =
  ## Compare two generated variants with an independent record-format model.
  snes.putWord(DirectPage.uint32 + 0x0E, Layout.int and 0xFFFF)
  snes.putWord(DirectPage.uint32 + 0x10, (Layout shr 16).int)
  snes.bus.write8(Layout, count.uint8)
  snes.bus.write8(Layout + 1, 0xA5)
  for i in 0 ..< count * 2:
    let source = Layout + 2 + (i * 5).uint32
    snes.bus.write8(source, (10 + i).uint8)
    snes.bus.write8(source + 1, 0xEE)
    snes.bus.write8(source + 2, attribute.uint8)
    snes.bus.write8(source + 3, (200 + i).uint8)
    snes.bus.write8(source + 4, (if i mod count == count - 1: 0x81'u8 else: 1'u8))
  for i in 0 ..< 82:
    snes.bus.write8(Output - 1 + i.uint32, Sentinel)
  let cpu = snes.runBuilder(slot, modifier)
  doAssert cpu.s == 0x1FFF and cpu.d == DirectPage and cpu.dbr == 0x7E
  doAssert cpu.x == (AllocationOffset + count * 10).uint16
  doAssert cpu.y == 2
  doAssert cpu.a == count.uint16
  doAssert (cpu.p and (FlagM or FlagX)) == 0
  doAssert snes.bus.read8(Output - 1) == Sentinel
  for offset in 0 ..< 81:
    var expected = Sentinel
    if offset < count * 10:
      let
        record = offset div 5
        component = offset mod 5
        tileOffset = TileMapOffset + 2 * (slot + record mod count)
      case component
      of 0: expected = (10 + record).uint8
      of 1: expected = gold[tileOffset]
      of 2: expected = ((attribute and 0xFE) or modifier or gold[tileOffset + 1].int).uint8
      of 3: expected = (200 + record).uint8
      of 4: expected = if record mod count == count - 1: 0x81'u8 else: 1'u8
      else: discard
    doAssert snes.bus.read8(Output + offset.uint32) == expected
  doAssert snes.bus.read8(Layout + 1) == 0xA5

proc checkResource(snes: SnesBus, gold: seq[uint8], resourceId, slot: int) =
  ## Check an original resource's layout without copying its payload into fixtures.
  let
    resourceEntry = ResourceTableOffset + resourceId * 4
    resourceAddress = gold[resourceEntry].uint32 or
      (gold[resourceEntry + 1].uint32 shl 8) or
      (gold[resourceEntry + 2].uint32 shl 16)
    resource = snesToFile(resourceAddress)
  doAssert resource >= 0 and resource + 4 <= gold.len
  let
    layoutEntry = LayoutTableOffset + gold[resource + 2].int * 4
    layoutAddress = gold[layoutEntry].uint32 or
      (gold[layoutEntry + 1].uint32 shl 8) or
      (gold[layoutEntry + 2].uint32 shl 16)
    layoutOffset = snesToFile(layoutAddress)
  doAssert layoutOffset >= 0 and layoutOffset + 2 <= gold.len
  let
    count = gold[layoutOffset].int
    modifier = gold[resource + 3].int
  doAssert gold[layoutOffset + 1].int <= count
  doAssert layoutOffset + 2 + count * 10 <= gold.len
  snes.putWord(DirectPage.uint32 + 0x0E, (layoutAddress and 0xFFFF).int)
  snes.putWord(DirectPage.uint32 + 0x10, (layoutAddress shr 16).int)
  for i in 0 ..< count * 10 + 2:
    snes.bus.write8(Output - 1 + i.uint32, Sentinel)
  let cpu = snes.runBuilder(slot, modifier)
  doAssert cpu.s == 0x1FFF and cpu.d == DirectPage and cpu.dbr == 0x7E
  doAssert cpu.a == count.uint16 and cpu.y == 2
  doAssert cpu.x == (AllocationOffset + count * 10).uint16
  for record in 0 ..< count * 2:
    let
      source = layoutOffset + 2 + record * 5
      tile = TileMapOffset + 2 * (slot + record mod count)
      expected = [gold[source], gold[tile],
        ((gold[source + 2].int and 0xFE) or modifier or gold[tile + 1].int).uint8,
        gold[source + 3], gold[source + 4]]
    for component, value in expected:
      doAssert snes.bus.read8(Output + (record * 5 + component).uint32) == value
  doAssert snes.bus.read8(Output - 1) == Sentinel
  doAssert snes.bus.read8(Output + (count * 10).uint32) == Sentinel

proc main() =
  ## Sweep layout sizes, tile allocation slots, and all layout attribute bytes.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
    builtCode = assembleAdoptedFile("buildSpriteDefinitions", 0x001D38)
  doAssert builtCode == gold[0x001D38 ..< 0x001DED]
  for resourceId in 0 ..< ResourceCount:
    for slot in [0, 16]:
      snes.checkResource(gold, resourceId, slot)
  for count in Counts:
    for slot in Slots:
      for attribute in 0 ..< 256:
        for modifier in Modifiers:
          snes.checkLayout(gold, count, slot, attribute, modifier)

when isMainModule:
  main()
