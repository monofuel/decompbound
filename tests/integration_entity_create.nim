import
  decompbound/[asm_parse, cpu, rom_pipeline, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  EntityCount = 30
  StateCount = 70
  Sentinel = 0x5A5A
  StepLimit = 10000
  ScriptIds = [0, 1, 2, 3, 7, 15, 23, 31]
  TemplateFields = [0x0E5E, 0x0E9A, 0x0ED6, 0x0F12, 0x0F4E, 0x0F8A, 0x0FC6, 0x1002]

proc putWord(snes: SnesBus, address: int, value: int) =
  ## Seed a synthetic entity-system field.
  snes.bus.write8(Wram + address.uint32, (value and 255).uint8)
  snes.bus.write8(Wram + address.uint32 + 1, ((value shr 8) and 255).uint8)

proc getWord(snes: SnesBus, address: int): int =
  ## Read an entity-system result word.
  snes.bus.read16(Wram + address.uint32).int

proc create(snes: SnesBus, scriptId, x, y: int): Cpu =
  ## Execute the complete original constructor without executing its installed script.
  result = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x300, dbr: 0x7E,
    a: scriptId.uint16, x: x.uint16, y: y.uint16)
  var steps = 0
  while result.pbr != 0 or result.pc != (Caller + 4).uint16:
    doAssert steps < StepLimit
    result.step(snes.bus)
    inc steps
  doAssert result.s == 0x1FFF and result.d == 0x300 and result.dbr == 0x7E
  doAssert (result.p and (FlagM or FlagX)) == 0

proc checkCreate(snes: SnesBus, gold: seq[uint8], entity, state, scriptId,
    position: int, active: bool) =
  ## Check list removal/appending, template fields, and original script-pointer installation.
  let
    firstActive = (entity + 1) mod EntityCount
    secondActive = (entity + 2) mod EntityCount
    x = if position == 0: 128 else: 0xFF00
    y = if position == 0: 112 else: 0x8000
    entityOffset = entity * 2
    stateOffset = state * 2
  var free: seq[int]
  for id in 0 ..< EntityCount:
    if not active or id notin [firstActive, secondActive]:
      free.add id * 2
  for address in countup(0x0A38, 0x1514, 2):
    snes.putWord(address, Sentinel)
  for index, offset in free:
    snes.putWord(0x0A9E + offset, if index + 1 < free.len: free[index + 1] else: 0xFFFF)
  snes.putWord(0x0A50, if active: firstActive * 2 else: 0xFFFF)
  if active:
    snes.putWord(0x0A9E + firstActive * 2, secondActive * 2)
    snes.putWord(0x0A9E + secondActive * 2, 0xFFFF)
  snes.putWord(0x0A52, free[0])
  snes.putWord(0x0A54, stateOffset)
  for id in 0 ..< StateCount:
    snes.putWord(0x125A + id * 2, if id + 1 < StateCount: (id + 1) * 2 else: 0xFFFF)
  snes.putWord(0x0A4C, entity)
  snes.putWord(0x0A4E, entity + 1)
  for index in 0 ..< TemplateFields.len:
    snes.putWord(0x0A38 + index * 2, 0x1234 + index * 0x111)
  snes.putWord(0x0A48, 0x3456)
  snes.putWord(0x0A4A, 3)
  let cpu = snes.create(scriptId, x, y)
  doAssert cpu.a == entity.uint16 and (cpu.p and FlagC) == 0
  doAssert snes.getWord(0x0A4C) == entityOffset
  doAssert snes.getWord(0x0A4E) == entityOffset + 2
  var remaining: seq[int]
  for offset in free:
    if offset != entityOffset:
      remaining.add offset
  doAssert snes.getWord(0x0A52) == remaining[0]
  for index, offset in remaining:
    doAssert snes.getWord(0x0A9E + offset) ==
      (if index + 1 < remaining.len: remaining[index + 1] else: 0xFFFF)
  doAssert snes.getWord(0x0A50) == (if active: firstActive * 2 else: entityOffset)
  if active:
    doAssert snes.getWord(0x0A9E + firstActive * 2) == secondActive * 2
    doAssert snes.getWord(0x0A9E + secondActive * 2) == entityOffset
  doAssert snes.getWord(0x0A9E + entityOffset) == 0xFFFF
  doAssert snes.getWord(0x0A54) == (if state + 1 < StateCount: stateOffset + 2 else: 0xFFFF)
  doAssert snes.getWord(0x0ADA + entityOffset) == stateOffset
  doAssert snes.getWord(0x125A + stateOffset) == 0xFFFF
  doAssert snes.getWord(0x0A62 + entityOffset) == scriptId
  for index, address in TemplateFields:
    doAssert snes.getWord(address + entityOffset) == 0x1234 + index * 0x111
  for address in [0x0B8E, 0x0B16]:
    doAssert snes.getWord(address + entityOffset) == x
  for address in [0x0BCA, 0x0B52]:
    doAssert snes.getWord(address + entityOffset) == y
  doAssert snes.getWord(0x0C06 + entityOffset) == 0x3456
  doAssert snes.getWord(0x103E + entityOffset) == 3
  for address in [0x0C42, 0x0C7E, 0x0CBA]:
    doAssert snes.getWord(address + entityOffset) == 0x8000
  for pair in [(0x121E, 0x9FC8), (0x11A6, 0xA023), (0x11E2, 0xA3A4),
      (0x107A, 0x943B), (0x10B6, 0x00C0), (0x10F2, 0xFFFF)]:
    doAssert snes.getWord(pair[0] + entityOffset) == pair[1]
  for address in [0x0DAA, 0x0CF6, 0x0DE6, 0x0D32, 0x0E22, 0x0D6E]:
    doAssert snes.getWord(address + entityOffset) == 0
  let pointer = 0x0400D4 + scriptId * 3
  doAssert snes.getWord(0x13FE + stateOffset) ==
    gold[pointer].int + (gold[pointer + 1].int shl 8)
  doAssert snes.getWord(0x148A + stateOffset) == gold[pointer + 2].int
  doAssert snes.getWord(0x1372 + stateOffset) == 0
  doAssert snes.getWord(0x12E6 + stateOffset) == 0

proc checkExhaustion(snes: SnesBus, failure: int) =
  ## Verify carry distinguishes failure from successful entity zero without consuming lists.
  snes.putWord(0x0A50, 0xFFFF)
  snes.putWord(0x0A52, if failure == 0: 0xFFFF else: 0)
  snes.putWord(0x0A54, if failure == 1: 0xFFFF else: 0)
  snes.putWord(0x0A9E, 0xFFFF)
  snes.putWord(0x125A, 0xFFFF)
  snes.putWord(0x0A4C, if failure == 2: 1 else: 0)
  snes.putWord(0x0A4E, 30)
  var before: seq[uint8]
  for address in 0x0A50 .. 0x1515:
    before.add snes.bus.read8(Wram + address.uint32)
  let cpu = snes.create(1, 128, 112)
  doAssert cpu.a == 0 and (cpu.p and FlagC) != 0
  for index, value in before:
    doAssert snes.bus.read8(Wram + (0x0A50 + index).uint32) == value

proc main() =
  ## Sweep entity/state slots, script selectors, positions, active lists, and exhaustion.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
    code = assembleAsm(".a16\n.i16\nJSL $C09321\n", Caller)
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  for entity in 0 ..< EntityCount:
    for state in [0, 3, StateCount - 1]:
      for scriptId in ScriptIds:
        for position in 0 .. 1:
          for active in [false, true]:
            snes.checkCreate(gold, entity, state, scriptId, position, active)
  for failure in 0 .. 2:
    snes.checkExhaustion(failure)

when isMainModule:
  main()
