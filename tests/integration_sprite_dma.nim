import
  decompbound/[asm_parse, cpu, memmap, rom_pipeline, snesbus]

const
  Caller = 0x1E00'u32
  SourceOffset = 0x4000
  Wram = 0x7E0000'u32
  Destinations = [0x6000, 0x6080, 0x60F0, 0x6100, 0x6180, 0x61F0, 0x6200, 0x62F0]
  Sizes = [32, 64, 128, 256]
  Sentinel = 0x5A5A'u16
  StepLimit = 6000
  FrameResources = [0, 7, 15, 16, 27, 40, 41, 44, 49, 50, 145, 177,
    203, 204, 205, 206, 209, 252, 437]

proc putWord(snes: SnesBus, address: uint32, value: int) =
  ## Write a synthetic WRAM word.
  snes.bus.write8(Wram + address, (value and 255).uint8)
  snes.bus.write8(Wram + address + 1, ((value shr 8) and 255).uint8)

proc sourceByte(index: int): uint8 =
  ## Give every source position a deterministic synthetic pattern.
  ((index * 37 + 11) and 255).uint8

proc runUntil(snes: SnesBus, cpu: var Cpu, bank: uint8, pc: uint16) =
  ## Execute original transfer code to a known return or fragment boundary.
  var steps = 0
  while cpu.pbr != bank or cpu.pc != pc:
    doAssert steps < StepLimit, "Unexpected wait in nonblocking transfer case"
    cpu.step(snes.bus)
    inc steps

proc checkTransfer(snes: SnesBus, destination, size, sourceBank, head: int,
    immediate: bool) =
  ## Compare queued and direct transfers against the sprite row-placement rule.
  for value in snes.vram.mitems:
    value = Sentinel
  for i in 0 ..< size:
    snes.bus.write8((sourceBank.uint32 shl 16) + SourceOffset.uint32 + i.uint32, sourceByte(i))
  snes.bus.write8(Wram + 0x0D, (if immediate: 0x80'u8 else: 0'u8))
  snes.bus.write8(Wram, head.uint8)
  snes.bus.write8(Wram + 1, head.uint8)
  snes.bus.write8(Wram + 0x91, 0)
  snes.putWord(0x92, size)
  snes.putWord(0x94, SourceOffset)
  snes.bus.write8(Wram + 0x96, sourceBank.uint8)
  snes.putWord(0x97, destination)
  snes.putWord(0x99, 0)
  let
    transfers = snes.dmaTransfers
    words = size div 2
    firstWords = min(words, 0x100 - (destination and 255))
    split = firstWords < words
    segments = if split: 2 else: 1
  var cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x0200, dbr: 0x7E)
  snes.runUntil(cpu, 0, (Caller + 4).uint16)
  doAssert cpu.s == 0x1FFF and cpu.d == 0x0200 and cpu.dbr == 0x7E
  doAssert snes.bus.read16(Wram + 0x92) == size.uint16
  doAssert snes.bus.read16(Wram + 0x94) == SourceOffset
  var nextDestination = destination + 0x100
  if (destination and 0x100) != 0:
    nextDestination = destination + ((size + 32) div 64) * 32
    if (nextDestination and 0x100) != 0:
      nextDestination -= 0x100
  doAssert snes.bus.read16(Wram + 0x97) == nextDestination.uint16
  if not immediate:
    doAssert snes.dmaTransfers == transfers
    for value in snes.vram:
      doAssert value == Sentinel
    doAssert snes.bus.read8(Wram) == ((head + segments * 8) and 255).uint8
    doAssert snes.bus.read16(Wram + 0x99) == size.uint16
    for segment in 0 ..< segments:
      let
        queue = Wram + (0x400 + ((head + segment * 8) and 255)).uint32
        length = if segment == 0: firstWords * 2 else: size - firstWords * 2
        source = SourceOffset + (if segment == 0: 0 else: firstWords * 2)
        target = if segment == 0: destination else: destination + firstWords + 0x100
      doAssert snes.bus.read8(queue) == 0
      doAssert snes.bus.read16(queue + 1) == length.uint16
      doAssert snes.bus.read16(queue + 3) == source.uint16
      doAssert snes.bus.read8(queue + 5) == sourceBank.uint8
      doAssert snes.bus.read16(queue + 6) == target.uint16
    var interrupt = Cpu(pbr: 0xC0, pc: 0x8238, s: 0x1FFF)
    snes.runUntil(interrupt, 0xC0, 0x8278)
    doAssert snes.bus.read8(Wram + 1) == snes.bus.read8(Wram)
  doAssert snes.dmaTransfers == transfers + segments
  for address in 0 ..< snes.vram.len:
    let relative = address - destination
    var sourceWord = -1
    if relative >= 0 and relative < firstWords:
      sourceWord = relative
    elif split and relative >= firstWords + 0x100 and relative < words + 0x100:
      sourceWord = relative - 0x100
    let expected = if sourceWord < 0: Sentinel else:
      sourceByte(sourceWord * 2).uint16 or (sourceByte(sourceWord * 2 + 1).uint16 shl 8)
    doAssert snes.vram[address] == expected

proc checkResourceEntry(snes: SnesBus, gold: seq[uint8], resourceId,
    entryIndex: int, immediate: bool) =
  ## Follow real entry flags and graphics source selection through a short DMA.
  let
    pointer = 0x2F133F + resourceId * 4
    resourceAddress = gold[pointer].uint32 or (gold[pointer + 1].uint32 shl 8) or
      (gold[pointer + 2].uint32 shl 16)
    resource = snesToFile(resourceAddress)
    entryAddress = resourceAddress + 9 + (entryIndex * 2).uint32
    entryOffset = snesToFile(entryAddress)
    entry = gold[entryOffset].int or (gold[entryOffset + 1].int shl 8)
    sourceAddress = (gold[resource + 8].uint32 shl 16) or (entry and 0xFFF0).uint32
    source = snesToFile(sourceAddress)
  doAssert source >= 0 and source + 32 <= gold.len
  snes.putWord(0x200, 1)
  snes.putWord(0x202, (entryAddress and 0xFFFF).int)
  snes.bus.write8(Wram + 0x204, (entryAddress shr 16).uint8)
  snes.putWord(0x2A42, gold[resource + 8].int)
  snes.putWord(0, 0)
  snes.putWord(0x99, 0)
  snes.putWord(0x92, 32)
  snes.putWord(0x97, 0x6000)
  snes.bus.write8(Wram + 0x0D, (if immediate: 0x80'u8 else: 0'u8))
  for value in snes.vram.mitems:
    value = Sentinel
  var cpu = Cpu(pc: 0x1E10, s: 0x1FFF, d: 0x200, dbr: 0x7E)
  snes.runUntil(cpu, 0, 0x1E14)
  doAssert snes.bus.read16(Wram + 0x341A) == entry.uint16
  doAssert snes.bus.read16(Wram + 0x94) == (entry and 0xFFF0).uint16
  doAssert snes.bus.read8(Wram + 0x96) == gold[resource + 8]
  if not immediate:
    var interrupt = Cpu(pbr: 0xC0, pc: 0x8238, s: 0x1FFF)
    snes.runUntil(interrupt, 0xC0, 0x8278)
  for address in 0 ..< snes.vram.len:
    let expected = if address >= 0x6000 and address < 0x6010:
      gold[source + (address - 0x6000) * 2].uint16 or
        (gold[source + (address - 0x6000) * 2 + 1].uint16 shl 8)
      else: Sentinel
    doAssert snes.vram[address] == expected

proc checkFullFrame(snes: SnesBus, gold: seq[uint8], resourceId,
    direction, phase, allocationSlot: int, immediate: bool) =
  ## Check normal full-frame selection and transfer using original resource sizes.
  let
    pointer = 0x2F133F + resourceId * 4
    resourceAddress = gold[pointer].uint32 or (gold[pointer + 1].uint32 shl 8) or
      (gold[pointer + 2].uint32 shl 16)
    resource = snesToFile(resourceAddress)
    segments = gold[resource].int
    size = gold[resource + 1].int * 2
    directionOffset = 0xA60B + direction * 2
    directionGroup = gold[directionOffset].int or (gold[directionOffset + 1].int shl 8)
    entryOffset = resource + 9 + directionGroup * 4 + phase * 2
    entry = gold[entryOffset].int or (gold[entryOffset + 1].int shl 8)
    source = snesToFile((gold[resource + 8].uint32 shl 16) or (entry and 0xFFF0).uint32)
    slotOffset = 0x042F8C + allocationSlot * 2
    destination = 0x4000 + gold[slotOffset].int + (gold[slotOffset + 1].int shl 8) +
      (if (segments and 1) != 0: 0x100 else: 0)
  doAssert source >= 0 and source + segments * size <= gold.len
  snes.putWord(0, 0)
  snes.putWord(0x99, 0)
  snes.putWord(0x2ABA, segments)
  snes.putWord(0x2A7E, size)
  snes.putWord(0x298E, destination)
  snes.putWord(0x29CA, ((resourceAddress + 9) and 0xFFFF).int)
  snes.putWord(0x2A06, (resourceAddress shr 16).int)
  snes.putWord(0x2A42, gold[resource + 8].int)
  snes.putWord(0x2AF6, direction)
  snes.putWord(0x2892, phase)
  snes.putWord(0x2BAA, 0)
  snes.bus.write8(Wram + 0x0D, (if immediate: 0x80'u8 else: 0'u8))
  for value in snes.vram.mitems:
    value = Sentinel
  var cpu = Cpu(pc: 0x1E20, s: 0x1FFF, d: 0x200, dbr: 0x7E)
  snes.runUntil(cpu, 0, 0x1E24)
  doAssert snes.bus.read16(Wram + 0x341A) == entry.uint16
  if not immediate:
    var interrupt = Cpu(pbr: 0xC0, pc: 0x8238, s: 0x1FFF)
    snes.runUntil(interrupt, 0xC0, 0x8278)
  var
    expected: array[0x8000, uint16]
    target = destination
  for value in expected.mitems:
    value = Sentinel
  for segment in 0 ..< segments:
    let firstWords = min(size div 2, 0x100 - (target and 255))
    for wordIndex in 0 ..< size div 2:
      let
        address = target + wordIndex + (if wordIndex >= firstWords: 0x100 else: 0)
        sourceOffset = source + segment * size + wordIndex * 2
      expected[address] = gold[sourceOffset].uint16 or (gold[sourceOffset + 1].uint16 shl 8)
    if (target and 0x100) == 0:
      target += 0x100
    else:
      target += ((size + 32) div 64) * 32
      if (target and 0x100) != 0:
        target -= 0x100
  doAssert snes.vram == expected
  doAssert snes.bus.read16(Wram + 0x97) == target.uint16

proc main() =
  ## Verify transfer splitting, queue wrap, and all affected VRAM words.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
    code = assembleAsm(".a16\n.i16\nJSL $C0A56E\n", Caller)
  for i, value in code:
    snes.bus.write8(Caller + i.uint32, value)
  let entryCode = assembleAsm(".a16\n.i16\nJSL $C0A53F\n", 0x1E10)
  for i, value in entryCode:
    snes.bus.write8(0x1E10 + i.uint32, value)
  let frameCode = assembleAsm(".a16\n.i16\nJSL $C0A4C4\n", 0x1E20)
  for i, value in frameCode:
    snes.bus.write8(0x1E20 + i.uint32, value)
  for resourceId in FrameResources:
    for direction in 0 ..< 8:
      for phase in 0 .. 1:
        for slot in [0, 16]:
          for immediate in [false, true]:
            snes.checkFullFrame(gold, resourceId, direction, phase, slot, immediate)
  for resourceId in [0, 44, 145, 437]:
    for entryIndex in 0 .. 1:
      for immediate in [false, true]:
        snes.checkResourceEntry(gold, resourceId, entryIndex, immediate)
  for destination in Destinations:
    for size in Sizes:
      for bank in [0x7E, 0x7F]:
        for head in [0, 0xF8]:
          for immediate in [false, true]:
            snes.checkTransfer(destination, size, bank, head, immediate)

when isMainModule:
  main()
