import
  decompbound/[adopted, asm_parse, cpu, rom_pipeline, snesbus]

const
  Caller = 0x1E00'u32
  AllocateCaller = 0x1E10'u32
  Occupancy = 0x7E4A00'u32
  SlotCount = 88
  StepLimit = 10000

proc call(snes: SnesBus, caller: uint32, a, x: int): Cpu =
  ## Invoke an original pool routine with private direct-page scratch.
  result = Cpu(pc: caller.uint16, s: 0x1FFF, d: 0x1000, dbr: 0x7E,
    a: a.uint16, x: x.uint16)
  var steps = 0
  while result.pbr != 0 or result.pc != (caller + 4).uint16:
    doAssert steps < StepLimit
    result.step(snes.bus)
    inc steps
  doAssert result.s == 0x1FFF and result.d == 0x1000 and result.dbr == 0x7E
  doAssert (result.p and (FlagM or FlagX)) == 0

proc checkReplacement(snes: SnesBus, selector, replacement, pattern: int) =
  ## Sweep every possible input occupancy byte across three consecutive patterns.
  snes.bus.write8(Occupancy - 1, 0x69)
  snes.bus.write8(Occupancy + SlotCount.uint32, 0x96)
  for index in 0 ..< SlotCount:
    snes.bus.write8(Occupancy + index.uint32, ((index + pattern * SlotCount) and 255).uint8)
  let cpu = snes.call(Caller, selector, replacement)
  doAssert cpu.x == SlotCount and cpu.y == replacement.uint16
  for index in 0 ..< SlotCount:
    let
      original = (index + pattern * SlotCount) and 255
      matches = selector == 0x8000 or original == ((selector and 255) or 0x80)
      expected = if matches: replacement and 255 else: original
    doAssert snes.bus.read8(Occupancy + index.uint32) == expected.uint8
  doAssert snes.bus.read8(Occupancy - 1) == 0x69
  doAssert snes.bus.read8(Occupancy + SlotCount.uint32) == 0x96

proc checkReuse(snes: SnesBus, owner: int) =
  ## Free one owner, reuse its hole, then clear the pool and allocate it whole.
  discard snes.call(Caller, 0x8000, 0)
  doAssert snes.call(AllocateCaller, 4, owner).a == 0
  doAssert snes.call(AllocateCaller, 6, owner xor 1).a == 4
  discard snes.call(Caller, owner, 0)
  doAssert snes.call(AllocateCaller, 4, owner xor 0x40).a == 0
  for index in 0 ..< SlotCount:
    let expected = if index < 4: (owner xor 0x40) or 0x80
      elif index < 10: (owner xor 1) or 0x80 else: 0
    doAssert snes.bus.read8(Occupancy + index.uint32) == expected.uint8
  discard snes.call(Caller, 0x8000, 0)
  doAssert snes.call(AllocateCaller, SlotCount, owner).a == 0
  for index in 0 ..< SlotCount:
    doAssert snes.bus.read8(Occupancy + index.uint32) == (owner or 0x80).uint8

proc main() =
  ## Verify tag selection, replacement truncation, and allocation reuse.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
  doAssert assembleAdoptedFile("replaceSpriteSlotTags", 0x001C11) == gold[0x001C11 ..< 0x001C52]
  for entry in [(Caller, "JSL $C01C11"), (AllocateCaller, "JSL $C01B96")]:
    let code = assembleAsm(".a16\n.i16\n" & entry[1] & "\n", entry[0])
    for index, value in code:
      snes.bus.write8(entry[0] + index.uint32, value)
  for low in 0 .. 255:
    for high in [0, 1, 0x7F, 0x80, 0xFF]:
      for replacement in [0, 1, 0x7F, 0x80, 0xFF, 0x1234]:
        for pattern in 0 .. 2:
          snes.checkReplacement(low or (high shl 8), replacement, pattern)
  for owner in 0 .. 127:
    snes.checkReuse(owner)
    discard snes.call(Caller, 0x8000, 0)
    doAssert snes.call(AllocateCaller, 2, 0xFFFF).a == 0
    let otherOwner = if owner == 0: 1 else: 0
    doAssert snes.call(AllocateCaller, 3, otherOwner).a == 2
    doAssert snes.call(AllocateCaller, 4, 0xFFFF).a == 5
    var cpu = Cpu(pbr: 0xC0, pc: 0x1F61, s: 0x1FFF, d: 0x1000,
      dbr: 0x7E, a: owner.uint16)
    var steps = 0
    while cpu.pbr != 0xC0 or cpu.pc != 0x1F6C:
      doAssert steps < StepLimit
      cpu.step(snes.bus)
      inc steps
    for index in 0 ..< SlotCount:
      let expected = if index < 2 or index in 5 .. 8: owner or 0x80
        elif index < 5: otherOwner or 0x80 else: 0
      doAssert snes.bus.read8(Occupancy + index.uint32) == expected.uint8

when isMainModule:
  main()
