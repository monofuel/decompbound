import
  std/strformat,
  decompbound/[asm_parse, cpu, snesbus],
  ./engine/rebuilt_rom

const
  InitCaller = 0x1E00'u32
  CallbackCaller = 0x1E10'u32
  PublishCaller = 0x1E20'u32
  Wram = 0x7E0000'u32
  DefinitionBank = 0x7F0000'u32
  DefinitionBase = 0x5000
  AlternateOffset = 0x100
  DirectPage = 0x0200'u16
  Counts = [(0, 1), (1, 0), (1, 1), (2, 3), (3, 2), (4, 4)]
  StepLimit = 2000

proc putWord(snes: SnesBus, address: uint32, value: int) =
  ## Write a synthetic word without coupling to emulated instructions.
  snes.bus.write8(address, (value and 255).uint8)
  snes.bus.write8(address + 1, ((value shr 8) and 255).uint8)

proc run(snes: SnesBus, caller: uint32, length: int, entityOffset = 0) =
  ## Execute original code with a separate entity scratch direct page.
  var
    cpu = Cpu(pc: caller.uint16, s: 0x1FFF, dbr: 0x7E, d: DirectPage,
      x: entityOffset.uint16)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != (caller + length.uint32).uint16:
    doAssert steps < StepLimit
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.s == 0x1FFF and cpu.d == DirectPage and cpu.dbr == 0x7E

proc checkPriority(snes: SnesBus, first, second, flags, attribute, alternate: int,
    entity = 0, queue = -1, target = -1, retain = false) =
  ## Verify priority edits, queue ownership and emitted bytes with inactive effects.
  let
    pointer = DefinitionBase + alternate * AlternateOffset
    total = max(first + second, 1)
    group = if queue < 0: attribute mod 4 else: queue
    offset = entity * 2
    queueWord = if target < 0: group else:
      0x8000 or (if retain: 0x4000 else: 0) or target
    screenX = 32 + entity
    screenY = 64 + entity
  snes.putWord(Wram + 0x2E, 1)
  snes.run(InitCaller, 4)
  snes.putWord(Wram + DirectPage.uint32 + 0x88, offset)
  snes.putWord(Wram + DirectPage.uint32 + 0x8C, DefinitionBase)
  snes.putWord(Wram + DirectPage.uint32 + 0x8E, 0x5A7F)
  snes.putWord(Wram + (0x341A + offset).uint32, alternate)
  snes.putWord(Wram + (0x2916 + offset).uint32, AlternateOffset)
  snes.putWord(Wram + (0x2BAA + offset).uint32, flags)
  snes.putWord(Wram + (0x2BE6 + offset).uint32, second or (first shl 8))
  if target >= 0:
    doAssert target != entity, "Self references are checked at the resolution boundary"
    snes.putWord(Wram + (0x103E + target * 2).uint32, group)
  snes.putWord(Wram + (0x103E + offset).uint32, queueWord)
  snes.putWord(Wram + (0x0B16 + offset).uint32, screenX)
  snes.putWord(Wram + (0x0B52 + offset).uint32, screenY)
  snes.putWord(Wram + (0x2E7A + offset).uint32, 0)
  for offset in 0 ..< 0x200:
    snes.bus.write8(DefinitionBank + (DefinitionBase + offset).uint32, 0x5A)
  for i in 0 ..< total:
    let address = DefinitionBank + (pointer + i * 5).uint32
    snes.bus.write8(address, 0)
    snes.bus.write8(address + 1, i.uint8)
    snes.bus.write8(address + 2, attribute.uint8)
    snes.bus.write8(address + 3, i.uint8)
    snes.bus.write8(address + 4, (if i == total - 1: 0x81'u8 else: 1'u8))
  let before = block:
    var snapshot: array[512, uint8]
    for i in 0 ..< snapshot.len:
      snapshot[i] = snes.bus.read8(DefinitionBank + (DefinitionBase + i).uint32)
    snapshot
  snes.run(CallbackCaller, 3, offset)
  doAssert snes.bus.read16(Wram + 0x2400) == group.uint16
  doAssert snes.bus.read16(Wram + (0x103E + offset).uint32) ==
    (if target >= 0 and not retain: 0'u16 else: queueWord.uint16)
  if target >= 0:
    doAssert snes.bus.read16(Wram + (0x103E + target * 2).uint32) == group.uint16
  for queueIndex in 0 .. 3:
    let base = 0x2404 + queueIndex * 0x102
    doAssert snes.bus.read16(Wram + (base + 0x100).uint32) ==
      (if queueIndex == group: 2'u16 else: 0'u16)
    if queueIndex == group:
      doAssert snes.bus.read16(Wram + base.uint32) == pointer.uint16
      doAssert snes.bus.read16(Wram + (base + 0x40).uint32) == screenX.uint16
      doAssert snes.bus.read16(Wram + (base + 0x80).uint32) == screenY.uint16
      doAssert snes.bus.read16(Wram + (base + 0xC0).uint32) == 0x5A7F
  for offset in 0 ..< before.len:
    let relative = offset - alternate * AlternateOffset
    var expected = before[offset]
    if relative >= 0 and relative < (first + second) * 5 and relative mod 5 == 2:
      let
        groupBit = if relative div 5 < first: 2 else: 1
        priority = if (flags and groupBit) != 0: 0x20 else: 0x30
      expected = ((attribute and 0xCF) or priority).uint8
    doAssert snes.bus.read8(DefinitionBank + (DefinitionBase + offset).uint32) == expected
  doAssert snes.bus.read16(Wram + DirectPage.uint32 + 0x8C) == pointer.uint16
  snes.run(PublishCaller, 4)
  for i in 0 ..< total:
    let
      groupBit = if i < first: 2 else: 1
      priority = if (flags and groupBit) != 0: 0x20 else: 0x30
      address = Wram + (0x500 + i * 4).uint32
    doAssert snes.bus.read8(address) == (screenX + i).uint8
    doAssert snes.bus.read8(address + 1) == (screenY - 1).uint8
    doAssert snes.bus.read8(address + 2) == i.uint8
    let expectedAttribute = if first + second == 0: attribute else:
      (attribute and 0xCF) or priority
    doAssert snes.bus.read8(address + 3) == expectedAttribute.uint8
  doAssert snes.bus.read16(Wram + 3) == (0x500 + total * 4).uint16

proc checkResolutionBoundary(snes: SnesBus, entity, target, referred: int,
    retain: bool, direct = false) =
  ## Prove one-hop resolution, including unsafe self/chained references, before enqueue.
  let
    offset = entity * 2
    original = if direct: referred else:
      0x8000 or (if retain: 0x4000 else: 0) or target
    resolved = if direct or entity == target: original else: referred
  snes.putWord(Wram + DirectPage.uint32 + 0x88, offset)
  snes.putWord(Wram + (0x103E + target * 2).uint32, referred)
  snes.putWord(Wram + (0x103E + offset).uint32, original)
  var state = Cpu(pbr: 0xC0, pc: 0xA406, x: offset.uint16,
    s: 0x1FFF, dbr: 0x7E, d: DirectPage)
  var steps = 0
  while state.pc != 0xA42C:
    doAssert steps < StepLimit and state.pbr == 0xC0
    state.step(snes.bus)
    inc steps
  doAssert snes.bus.read16(Wram + 0x2400) == resolved.uint16
  doAssert snes.bus.read16(Wram + (0x103E + offset).uint32) ==
    (if retain or direct: original.uint16 else: 0'u16)
  doAssert state.x.int == offset and state.s == 0x1FFF

proc checkVariantBoundary(snes: SnesBus, entry: int) =
  ## Verify low-word variant wrapping and ignored entry bits before priority patching.
  snes.putWord(Wram + DirectPage.uint32 + 0x8C, 0xFFFC)
  snes.putWord(Wram + DirectPage.uint32 + 0x8E, 0x5A7F)
  snes.putWord(Wram + 0x341A, entry)
  snes.putWord(Wram + 0x2916, 8)
  var state = Cpu(pbr: 0xC0, pc: 0xA3A4, s: 0x1FFF, dbr: 0x7E, d: DirectPage)
  var steps = 0
  while state.pc != 0xA3B4:
    doAssert steps < StepLimit and state.pbr == 0xC0
    state.step(snes.bus)
    inc steps
  doAssert snes.bus.read16(Wram + DirectPage.uint32 + 0x8C) ==
    (if (entry and 1) == 0: 0xFFFC'u16 else: 4'u16)
  doAssert snes.bus.read16(Wram + DirectPage.uint32 + 0x8E) == 0x5A7F

proc checkPriorityIndexBoundary(snes: SnesBus, first, second: int) =
  ## Pin byte-index wrapping and signed loop termination before interpreting mutated definitions.
  const GuardByte = 0x5A'u8
  var expected: array[512, uint8]
  for index in 0 ..< expected.len:
    expected[index] = GuardByte
    snes.bus.write8(DefinitionBank + (DefinitionBase + index).uint32, GuardByte)
  var record = 0
  for group, count in [first, second]:
    let iterations = if count <= 128: count else: 0
    for index in 0 ..< iterations:
      let address = (2 + record * 5) mod 256
      expected[address] = (expected[address] and 0xCF) or
        (if group == 0: 0x20'u8 else: 0x30'u8)
      inc record
  snes.putWord(Wram + DirectPage.uint32 + 0x88, 0)
  snes.putWord(Wram + DirectPage.uint32 + 0x8C, DefinitionBase)
  snes.putWord(Wram + DirectPage.uint32 + 0x8E, 0x7F)
  snes.putWord(Wram + 0x341A, 0)
  snes.putWord(Wram + 0x2BAA, 2)
  snes.putWord(Wram + 0x2BE6, second or (first shl 8))
  var
    state = Cpu(pbr: 0xC0, pc: 0xA3A4, s: 0x1FFF, dbr: 0x7E, d: DirectPage)
    steps = 0
  while state.pc != 0xA3FB:
    doAssert steps < 10000 and state.pbr == 0xC0
    state.step(snes.bus)
    inc steps
  for index, value in expected:
    doAssert snes.bus.read8(DefinitionBank + (DefinitionBase + index).uint32) == value,
      &"priority count {first}/{second}, byte {index}"

proc main() =
  ## Preserve the attribute sweep and extend it to entity and indirect-queue contracts.
  var cases = 0
  for image in engineImages("bin/sprite_priority_extract"):
    let snes = newSnesBus(image)
    for entry in [(InitCaller, "JSL $C088B1"),
        (CallbackCaller, "JSR $A3A4"), (PublishCaller, "JSL $C08B26")]:
      let code = assembleAsm(".a16\n.i16\n" & entry[1] & "\n", entry[0])
      for i, value in code:
        snes.bus.write8(entry[0] + i.uint32, value)
    for counts in Counts:
      for flags in 0 ..< 4:
        for attribute in 0 ..< 256:
          for alternate in 0 .. 1:
            snes.checkPriority(counts[0], counts[1], flags, attribute, alternate)
            inc cases
    for entity in [0, 5, 22, 23, 29]:
      for group in 0 .. 3:
        snes.checkPriority(0, 0, 2, 0xA5, 0, entity, group)
        inc cases
        for alternate in 0 .. 1:
          snes.checkPriority(2, 3, 3, 0xA5, alternate, entity, group)
          inc cases
          for target in 0 .. 29:
            if target != entity:
              for retain in [false, true]:
                snes.checkPriority(2, 3, 3, 0xA5, alternate, entity, group, target, retain)
                inc cases
      for target in [entity, (entity + 1) mod 30, 63]:
        for referred in [0, 3, 0x8001, 0xC01D]:
          for retain in [false, true]:
            snes.checkResolutionBoundary(entity, target, referred, retain)
            inc cases
      for word in [4, 0x4001, 0x7FFF]:
        snes.checkResolutionBoundary(entity, entity, word, false, true)
        inc cases
    for first in [0, 1, 50, 51, 52, 127, 128, 129, 255]:
      for second in [0, 1, 50, 51, 52, 127, 128, 129, 255]:
        snes.checkPriorityIndexBoundary(first, second)
        inc cases
    for entry in [0, 1, 0xFFFE, 0xFFFF]:
      snes.checkVariantBoundary(entry)
      inc cases
  echo &"sprite priority/queue: {cases} original/rebuilt cases passed"

when isMainModule:
  main()
