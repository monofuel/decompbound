import
  decompbound/[adopted, asm_parse, cpu, rom_pipeline, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  EntityCount = 30
  StateCount = 70
  EndOfList = 0xFFFF

proc putWord(snes: SnesBus, address, value: int) =
  ## Seed a synthetic linked-list field.
  snes.bus.write8(Wram + address.uint32, (value and 255).uint8)
  snes.bus.write8(Wram + address.uint32 + 1, ((value shr 8) and 255).uint8)

proc word(snes: SnesBus, address: int): int =
  ## Read a linked-list field.
  snes.bus.read16(Wram + address.uint32).int

proc remove(snes: SnesBus, entity: int) =
  ## Execute the original entity-removal entry with native 16-bit registers.
  var
    cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x200, dbr: 0x7E,
      a: entity.uint16, y: 0x1234)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != (Caller + 4).uint16:
    doAssert steps < 10000
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.s == 0x1FFF and cpu.d == 0x200 and cpu.dbr == 0x7E
  doAssert cpu.y == 0x1234 and cpu.a == (entity * 2).uint16

proc checkRemoval(snes: SnesBus, entity, position, chainLength, nextRelation, ordering: int) =
  ## Verify active-list splicing and whole-chain return against synthetic list models.
  let
    offset = entity * 2
    other = ((entity + 1) mod EntityCount) * 2
    third = ((entity + 2) mod EntityCount) * 2
    active = case position
      of 0: @[offset]
      of 1: @[offset, other, third]
      of 2: @[other, offset, third]
      else: @[other, third, offset]
    current = if nextRelation == 0: offset else: other
  var
    remaining: seq[int]
    free: seq[int]
    states: seq[int]
  for index in 0 ..< StateCount:
    states.add (if ordering == 0: index * 2 else: ((index * 31 + 17) mod StateCount) * 2)
  for entry in active:
    if entry != offset:
      remaining.add entry
  for id in 0 ..< EntityCount:
    if id * 2 notin active:
      free.add id * 2
  for index, entry in active:
    snes.putWord(0x0A9E + entry, if index + 1 < active.len: active[index + 1] else: EndOfList)
    snes.putWord(0x0A62 + entry, 7)
  for index, entry in free:
    snes.putWord(0x0A9E + entry, if index + 1 < free.len: free[index + 1] else: EndOfList)
  snes.putWord(0x0A50, active[0])
  snes.putWord(0x0A52, free[0])
  snes.putWord(0x0A56, current)
  snes.putWord(0x0ADA + offset, if chainLength == 0: EndOfList else: states[0])
  snes.putWord(0x0A54, if chainLength == StateCount: EndOfList else: states[chainLength])
  for index, state in states:
    snes.putWord(0x125A + state,
      if index + 1 == chainLength or index + 1 == StateCount: EndOfList else: states[index + 1])
  snes.remove(entity)
  doAssert snes.word(0x0A50) == (if remaining.len == 0: EndOfList else: remaining[0])
  doAssert snes.word(0x0A52) == offset
  doAssert snes.word(0x0A9E + offset) == free[0]
  for index, entry in remaining:
    doAssert snes.word(0x0A9E + entry) ==
      (if index + 1 < remaining.len: remaining[index + 1] else: EndOfList)
    doAssert snes.word(0x0A62 + entry) == 7
  for index, entry in free:
    doAssert snes.word(0x0A9E + entry) ==
      (if index + 1 < free.len: free[index + 1] else: EndOfList)
  let successor = if position in [1, 2]: third else: EndOfList
  let expectedNext = if position == 1: other else: successor
  doAssert snes.word(0x0A56) == (if nextRelation == 0: expectedNext else: current)
  doAssert snes.word(0x0A62 + offset) == EndOfList
  doAssert snes.word(0x107A + offset) == 0x943B
  doAssert snes.word(0x10B6 + offset) == 0xC0
  doAssert snes.word(0x0ADA + offset) == (if chainLength == 0: EndOfList else: states[0])
  doAssert snes.word(0x0A54) == states[0]
  for index, state in states:
    doAssert snes.word(0x125A + state) ==
      (if index + 1 == StateCount: EndOfList else: states[index + 1])
  var before: seq[uint8]
  for address in 0x0A50 .. 0x1515:
    before.add snes.bus.read8(Wram + address.uint32)
  snes.remove(entity)
  for index, value in before:
    doAssert snes.bus.read8(Wram + (0x0A50 + index).uint32) == value

proc main() =
  ## Sweep every entity slot, list position, script-chain length, and saved-next relation.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
    code = assembleAsm(".a16\n.i16\nJSL $C09C35\n", Caller)
  doAssert assembleAdoptedFile("entityListLifecycle", 0x9C35) == gold[0x9C35 ..< 0x9CD7]
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  for entity in 0 ..< EntityCount:
    for position in 0 .. 3:
      for chainLength in 0 .. StateCount:
        for nextRelation in 0 .. 1:
          for ordering in 0 .. 1:
            snes.checkRemoval(entity, position, chainLength, nextRelation, ordering)

when isMainModule:
  main()
