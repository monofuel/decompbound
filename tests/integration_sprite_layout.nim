import
  decompbound/[adopted, cpu, rom_pipeline, snesbus]

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
  StepLimit = 2000

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
  snes.putWord(0x1FFE, ReturnPc.int - 1)
  var
    cpu = Cpu(pbr: 0xC0, pc: 0x1D38, s: 0x1FFD, d: DirectPage, dbr: 0x7E,
      a: AllocationOffset, x: slot.uint16, y: modifier.uint16)
    steps = 0
  while cpu.pbr != 0xC0 or cpu.pc != ReturnPc:
    doAssert steps < StepLimit
    cpu.step(snes.bus)
    inc steps
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

proc main() =
  ## Sweep layout sizes, tile allocation slots, and all layout attribute bytes.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
    builtCode = assembleAdoptedFile("buildSpriteDefinitions", 0x001D38)
  doAssert builtCode == gold[0x001D38 ..< 0x001DED]
  for count in Counts:
    for slot in Slots:
      for attribute in 0 ..< 256:
        for modifier in Modifiers:
          snes.checkLayout(gold, count, slot, attribute, modifier)

when isMainModule:
  main()
