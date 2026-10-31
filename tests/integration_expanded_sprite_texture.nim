import
  decompbound/[asm_parse, cpu, expanded_sprite_texture, memmap, rom_pipeline, snesbus]

const
  Caller = 0x1E20'u32
  StackTop = 0x1FFF'u16
  DirectPage = 0x0200'u16
  Wram = 0x7E0000'u32
  Sentinel = 0x5A5A'u16
  PriorEntry = 0xA5A5'u16
  StepLimit = 20000
  VramMask = 0x7FFF
  ResourceTable = 0x2F133F
  SlotTable = 0x042F8C
  FrameResources = [0, 7, 15, 16, 27, 40, 41, 44, 49, 50, 145, 177,
    203, 204, 205, 206, 209, 252, 437]
  EffectFlags = [0, 4, 8, 12]
  AllocationSlots = [0, 16]
  SyntheticList = 0x3000
  SyntheticGraphics = 0x3100

type
  MachineCopy = object
    wram: seq[uint8]
    vram: array[0x8000, uint16]
    oam: array[544, uint8]
    ppuRegs: array[0x100, uint8]
    dmaRegs: array[0x80, uint8]
    dmaTransfers: int
    dmaStorm: bool

proc putWord(snes: SnesBus, address, value: int) =
  ## Install one authored WRAM word.
  snes.bus.write8(Wram + address.uint32, (value and 255).uint8)
  snes.bus.write8(Wram + address.uint32 + 1, ((value shr 8) and 255).uint8)

proc getWord(snes: SnesBus, address: int): uint16 =
  ## Read one WRAM word through the public bus after original execution.
  snes.bus.read16(Wram + address.uint32)

proc captureMachine(snes: SnesBus): MachineCopy =
  ## Copy WRAM, VRAM, OAM, PPU shadows, and DMA counters for a freeze check.
  MachineCopy(wram: snes.bus.mem[Wram.int ..< 0x800000], vram: snes.vram,
    oam: snes.oam, ppuRegs: snes.ppuRegs, dmaRegs: snes.dmaRegs,
    dmaTransfers: snes.dmaTransfers, dmaStorm: snes.dmaStorm)

proc checkFrozen(snes: SnesBus, before: MachineCopy, label: string) =
  ## Fail if prepareSpriteTexture wrote memory or issued DMA.
  doAssert snes.bus.mem[Wram.int ..< 0x800000] == before.wram, label & " WRAM"
  doAssert snes.vram == before.vram, label & " VRAM"
  doAssert snes.oam == before.oam, label & " OAM"
  doAssert snes.ppuRegs == before.ppuRegs, label & " PPU"
  doAssert snes.dmaRegs == before.dmaRegs, label & " DMA regs"
  doAssert snes.dmaTransfers == before.dmaTransfers, label & " DMA count"
  doAssert snes.dmaStorm == before.dmaStorm, label & " DMA storm"

proc applyPatch(patch: SpriteTexturePatch, native: array[0x8000, uint16]): array[0x8000, uint16] =
  ## Overlay reconstructed words, falling back to native VRAM where the mask is clear.
  result = native
  doAssert patch.words.len == patch.present.len
  for index, seen in patch.present:
    if seen:
      result[(patch.firstWord + index) and VramMask] = patch.words[index]

proc fillVram(snes: SnesBus, value: uint16) =
  ## Paint every VRAM word with a sentinel before an original upload.
  for word in snes.vram.mitems:
    word = value

proc runOriginal(snes: SnesBus, entityOffset: int) =
  ## Execute original $C0A4C4 with Y holding the entity offset.
  var
    cpu = Cpu(pc: Caller.uint16, s: StackTop, d: DirectPage, dbr: 0x7E,
      y: entityOffset.uint16)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != (Caller + 4).uint16:
    doAssert steps < StepLimit, "original $C0A4C4 failed to return"
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.s == StackTop and cpu.d == DirectPage and cpu.dbr == 0x7E

proc resourceFields(gold: seq[uint8], resourceId, direction, phase,
    allocationSlot: int): tuple[segments, size, destination, listOffset, listBank,
    graphicsBank, entry: int] =
  ## Derive live entity fields from local resource metadata, matching the DMA tests.
  let
    pointer = ResourceTable + resourceId * 4
    resourceAddress = gold[pointer].uint32 or (gold[pointer + 1].uint32 shl 8) or
      (gold[pointer + 2].uint32 shl 16)
    resource = snesToFile(resourceAddress)
    segments = gold[resource].int
    size = gold[resource + 1].int * 2
    directionOffset = snesToFile(0xC0A60B'u32) + direction * 2
    directionGroup = gold[directionOffset].int or (gold[directionOffset + 1].int shl 8)
    entryOffset = resource + 9 + directionGroup * 4 + (if phase != 0: 2 else: 0)
    entry = gold[entryOffset].int or (gold[entryOffset + 1].int shl 8)
    slotOffset = SlotTable + allocationSlot * 2
    destination = 0x4000 + gold[slotOffset].int + (gold[slotOffset + 1].int shl 8) +
      (if (segments and 1) != 0: 0x100 else: 0)
  (segments, size, destination, (resourceAddress.int + 9) and 0xFFFF,
    resourceAddress.int shr 16, gold[resource + 8].int, entry)

proc installEntity(snes: SnesBus, entityOffset, segments, size, destination, listOffset,
    listBank, graphicsBank, direction, phase, effectFlags: int) =
  ## Author the entity words original $C0A4C4 reads, plus the global phase word.
  snes.initHdma()
  snes.putWord(0, 0)
  snes.putWord(0x99, 0)
  snes.putWord(0x2ABA + entityOffset, segments)
  snes.putWord(0x2A7E + entityOffset, size)
  snes.putWord(0x298E + entityOffset, destination)
  snes.putWord(0x29CA + entityOffset, listOffset)
  snes.putWord(0x2A06 + entityOffset, listBank)
  snes.putWord(0x2A42 + entityOffset, graphicsBank)
  snes.putWord(0x2AF6 + entityOffset, direction)
  snes.putWord(0x2BAA + entityOffset, effectFlags)
  snes.putWord(0x341A + entityOffset, PriorEntry.int)
  snes.putWord(0x2892, phase)
  snes.bus.write8(Wram + 0x0D, 0x80)

proc checkCase(snes: SnesBus, gold: seq[uint8], entityOffset, resourceId, direction, phase,
    allocationSlot, effectFlags: int, label: string) =
  ## Compare helper output with original $C0A4C4 and prove the helper did not write.
  let fields = gold.resourceFields(resourceId, direction, phase, allocationSlot)
  snes.installEntity(entityOffset, fields.segments, fields.size, fields.destination,
    fields.listOffset, fields.listBank, fields.graphicsBank, direction, phase, effectFlags)
  snes.fillVram(Sentinel)
  let before = snes.captureMachine()
  let patch = prepareSpriteTexture(snes, entityOffset, phase)
  snes.checkFrozen(before, label)
  doAssert patch != nil, label & " patch"
  snes.runOriginal(entityOffset)
  let applied = patch.applyPatch(before.vram)
  for address in 0 ..< snes.vram.len:
    doAssert snes.vram[address] == applied[address],
      label & " VRAM " & $address & " actual " & $snes.vram[address] &
      " expected " & $applied[address]
  doAssert snes.getWord(0x341A + entityOffset) == patch.entry, label & " entry"

proc checkRealResources(snes: SnesBus, gold: seq[uint8]) =
  ## Cover representative resources, every direction, both phases, fill flags, and slots.
  for resourceId in FrameResources:
    for direction in 0 .. 7:
      for phase in 0 .. 1:
        for slot in AllocationSlots:
          for flags in EffectFlags:
            snes.checkCase(gold, 0, resourceId, direction, phase, slot, flags,
              "resource " & $resourceId & " dir " & $direction & " phase " & $phase &
              " slot " & $slot & " flags " & $flags)

proc checkEntityOffset(snes: SnesBus, gold: seq[uint8]) =
  ## Index entity arrays by a nonzero Y the way original $C0A4C4 does.
  const entityOffset = 2
  for direction in 0 .. 7:
    for phase in 0 .. 1:
      for slot in AllocationSlots:
        for flags in EffectFlags:
          snes.checkCase(gold, entityOffset, 437, direction, phase, slot, flags,
            "offset2 dir " & $direction & " phase " & $phase & " slot " & $slot &
            " flags " & $flags)

proc checkPhaseParameter(snes: SnesBus, gold: seq[uint8]) =
  ## Use the supplied phase even when $2892 holds a different live value.
  let fields = gold.resourceFields(437, 0, 0, 0)
  snes.installEntity(0, fields.segments, fields.size, fields.destination,
    fields.listOffset, fields.listBank, fields.graphicsBank, 0, 1, 0)
  snes.fillVram(Sentinel)
  let before = snes.captureMachine()
  let patch = prepareSpriteTexture(snes, 0, 0)
  snes.checkFrozen(before, "phase-param")
  doAssert patch != nil
  snes.putWord(0x2892, 0)
  snes.runOriginal(0)
  let applied = patch.applyPatch(before.vram)
  doAssert snes.vram == applied
  doAssert snes.getWord(0x341A) == patch.entry
  let phase0 = gold.resourceFields(437, 0, 0, 0).entry.uint16
  let phase1 = gold.resourceFields(437, 0, 1, 0).entry.uint16
  doAssert phase0 != phase1
  doAssert patch.entry == phase0

proc writeSyntheticWord(snes: SnesBus, bank, offset, value: int) =
  ## Store one little-endian word in authored WRAM, never ROM.
  let address = ((bank shl 16) or (offset and 0xFFFF)).uint32
  snes.bus.write8(address, (value and 255).uint8)
  snes.bus.write8(address + 1, ((value shr 8) and 255).uint8)

proc sourceByte(index: int): uint8 =
  ## Give every synthetic graphics position a deterministic pattern.
  ((index * 37 + 11) and 255).uint8

proc checkSynthetic(snes: SnesBus) =
  ## Exercise page-split placement, bit-1 fill bypass, and fill-consumed retention.
  const
    segments = 2
    size = 64
    destination = 0x60F0
  for i in 0 ..< size * segments:
    snes.bus.write8(Wram + (SyntheticGraphics + i).uint32, sourceByte(i))
  snes.writeSyntheticWord(0x7E, SyntheticList, 0x3100)
  snes.writeSyntheticWord(0x7E, SyntheticList + 2, 0x3140)
  snes.installEntity(0, segments, size, destination, SyntheticList, 0x7E, 0x7E, 0, 0, 12)
  snes.fillVram(Sentinel)
  var before = snes.captureMachine()
  var patch = prepareSpriteTexture(snes, 0, 0)
  snes.checkFrozen(before, "synthetic-fill")
  doAssert patch != nil
  snes.runOriginal(0)
  doAssert snes.vram == patch.applyPatch(before.vram)
  doAssert patch.entry == PriorEntry
  doAssert snes.getWord(0x341A) == PriorEntry
  snes.writeSyntheticWord(0x7E, SyntheticList, 0x3102)
  snes.installEntity(0, segments, size, destination, SyntheticList, 0x7E, 0x7E, 0, 0, 12)
  snes.fillVram(Sentinel)
  before = snes.captureMachine()
  patch = prepareSpriteTexture(snes, 0, 0)
  snes.checkFrozen(before, "synthetic-bit1")
  doAssert patch != nil
  snes.runOriginal(0)
  doAssert snes.vram == patch.applyPatch(before.vram)
  doAssert patch.entry == 0x3102'u16
  doAssert snes.getWord(0x341A) == 0x3102'u16

proc checkMalformed(snes: SnesBus) =
  ## Reject unsupported live metadata without touching MMIO or issuing DMA.
  snes.installEntity(0, 3, 64, 0x4100, 0x2104, 0, 0xD1, 0, 0, 0)
  snes.fillVram(Sentinel)
  var before = snes.captureMachine()
  doAssert prepareSpriteTexture(snes, 0, 0) == nil
  snes.checkFrozen(before, "mmio-list")
  snes.installEntity(0, 3, 64, 0x4100, 0x1A7F + 9, 0xEF, 0xD1, 8, 0, 0)
  before = snes.captureMachine()
  doAssert prepareSpriteTexture(snes, 0, 0) == nil
  snes.checkFrozen(before, "direction")
  snes.installEntity(0, 0, 64, 0x4100, 0x1A7F + 9, 0xEF, 0xD1, 0, 0, 0)
  before = snes.captureMachine()
  doAssert prepareSpriteTexture(snes, 0, 0) == nil
  snes.checkFrozen(before, "count")
  snes.installEntity(0, 3, 65, 0x4100, 0x1A7F + 9, 0xEF, 0xD1, 0, 0, 0)
  before = snes.captureMachine()
  doAssert prepareSpriteTexture(snes, 0, 0) == nil
  snes.checkFrozen(before, "odd-size")
  doAssert prepareSpriteTexture(snes, 1, 0) == nil
  snes.checkFrozen(before, "odd-offset")
  doAssert prepareSpriteTexture(snes, 60, 0) == nil
  snes.checkFrozen(before, "slot-range")

proc main() =
  ## Cross-check presentation reconstruction against original $C0A4C4.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
    code = assembleAsm(".a16\n.i16\nJSL $C0A4C4\n", Caller)
  for i, value in code:
    snes.bus.write8(Caller + i.uint32, value)
  snes.checkMalformed()
  snes.checkSynthetic()
  snes.checkPhaseParameter(gold)
  snes.checkEntityOffset(gold)
  snes.checkRealResources(gold)

when isMainModule:
  main()
