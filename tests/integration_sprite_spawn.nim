import
  decompbound/[asm_parse, cpu, memmap, rom_pipeline, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  Sentinel = 0x5A5A'u16
  StepLimit = 30000
  NativeCallOpcode = 0x42'u8
  RemoveEntityOpcode = 0'u8
  CleanupTarget = 0xC020F1'u32
  SyntheticScript = 0x7F4000'u32

proc putWord(snes: SnesBus, address, value: int) =
  ## Seed a synthetic spawn input or hardware shadow.
  snes.bus.write8(Wram + address.uint32, (value and 255).uint8)
  snes.bus.write8(Wram + address.uint32 + 1, ((value shr 8) and 255).uint8)

proc getWord(snes: SnesBus, address: int): int =
  ## Read a constructed entity field.
  snes.bus.read16(Wram + address.uint32).int

proc call(snes: SnesBus, address: string, a = 0, x = 0, y = 0): Cpu =
  ## Execute an original routine through its full return with disjoint scratch.
  let code = assembleAsm(".a16\n.i16\nJSL " & address & "\n", Caller)
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  result = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x200, dbr: 0x7E,
    a: a.uint16, x: x.uint16, y: y.uint16)
  var steps = 0
  while result.pbr != 0 or result.pc != (Caller + 4).uint16:
    doAssert steps < StepLimit, "Unexpected wait during initialized sprite spawn"
    result.step(snes.bus)
    inc steps
  doAssert result.s == 0x1FFF and result.d == 0x200 and result.dbr == 0x7E
  doAssert (result.p and (FlagM or FlagX)) == 0

proc pointer(gold: seq[uint8], offset: int): int =
  ## Resolve a real metadata pointer without embedding extracted bytes.
  snesToFile(gold[offset].uint32 or (gold[offset + 1].uint32 shl 8) or
    (gold[offset + 2].uint32 shl 16))

proc runCleanupScript(snes: SnesBus, entity: int) =
  ## Execute a synthetic native-cleanup call followed by entity removal through the VM.
  let
    stream = [NativeCallOpcode, (CleanupTarget and 255).uint8,
      ((CleanupTarget shr 8) and 255).uint8, (CleanupTarget shr 16).uint8, RemoveEntityOpcode]
    code = assembleAsm(".a16\n.i16\nJSR $9506\n", Caller)
  for index, value in stream:
    snes.bus.write8(SyntheticScript + index.uint32, value)
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  snes.putWord(0x280, 0)
  snes.putWord(0x288, entity * 2)
  snes.putWord(0x28A, 0)
  snes.putWord(0x13FE, (SyntheticScript and 0xFFFF).int)
  snes.putWord(0x148A, (SyntheticScript shr 16).int)
  snes.putWord(0x1372, 0)
  snes.putWord(0x1516, 0)
  snes.putWord(0x1A42, entity)
  var
    cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x200, dbr: 0x7E)
    steps = 0
    dispatches = 0
  while cpu.pbr != 0 or cpu.pc != (Caller + 3).uint16:
    doAssert steps < StepLimit
    if cpu.pbr == 0 and cpu.pc == 0x952E:
      inc dispatches
      if dispatches == 1:
        doAssert snes.getWord(0x0A50) == entity * 2
        doAssert snes.getWord(0x0A62 + entity * 2) == 0
        doAssert snes.getWord(0x2CD6 + entity * 2) == 0xFFFF
    cpu.step(snes.bus)
    inc steps
  doAssert dispatches == 2
  doAssert cpu.s == 0x1FFF and cpu.d == 0x200 and cpu.dbr == 0x7E
  doAssert snes.getWord(0x13FE) == (SyntheticScript and 0xFFFF).int + stream.len
  doAssert snes.getWord(0x1372) == 0xFFFE
  doAssert snes.getWord(0x0A58) == 0xFFFF

proc checkSpawn(snes: SnesBus, gold: seq[uint8], resourceId, scriptId, owner: int) =
  ## Verify full spawning against independent resource and allocation formulas.
  let
    resource = gold.pointer(0x2F133F + resourceId * 4)
    layoutId = gold[resource + 2].int
    layout = gold.pointer(0x042B0D + layoutId * 4)
    count = gold[layout].int
    firstGroup = gold[layout + 1].int
    width = gold[resource + 1].int shr 4
    height = gold[resource].int
    slots = ((width + 1) div 2) * ((height + 1) div 2)
    entity = if owner == 0xFFFF: 0 else: owner
    entityOffset = entity * 2
    clears = width mod 2 != 0 or height mod 2 != 0
  discard snes.call("$C09282")
  discard snes.call("$C01A86")
  discard snes.call("$C01C11", 0x8000)
  snes.initHdma()
  snes.putWord(0x436C, 0)
  for address in countup(0x0A38, 0x0A48, 2):
    snes.putWord(address, 0)
  snes.bus.write8(Wram + 0x0D, 0x80)
  snes.putWord(0x20E, 128)
  snes.putWord(0x210, 112)
  for value in snes.vram.mitems:
    value = Sentinel
  let cpu = snes.call("$C01E49", resourceId, scriptId, owner)
  doAssert cpu.a == entity.uint16
  doAssert snes.getWord(0x0A50) == entityOffset
  doAssert snes.getWord(0x0A9E + entityOffset) == 0xFFFF
  doAssert snes.getWord(0x0ADA + entityOffset) == 0
  doAssert snes.getWord(0x0A62 + entityOffset) == scriptId
  doAssert snes.getWord(0x103E + entityOffset) == 1
  let layoutWord = 0x042AEB + layoutId * 2
  doAssert snes.getWord(0x332A + entityOffset) ==
    gold[layoutWord].int + (gold[layoutWord + 1].int shl 8)
  for address in [0x0B16, 0x0B8E]:
    doAssert snes.getWord(address + entityOffset) == 128
  for address in [0x0B52, 0x0BCA]:
    doAssert snes.getWord(address + entityOffset) == 112
  let scriptPointer = 0x0400D4 + scriptId * 3
  doAssert snes.getWord(0x13FE) == gold[scriptPointer].int + (gold[scriptPointer + 1].int shl 8)
  doAssert snes.getWord(0x148A) == gold[scriptPointer + 2].int
  for pair in [(0x112E, 0x467E), (0x116A, 0x7E), (0x2916, count * 5),
      (0x2952, 0), (0x298E, 0x4000 + (if height mod 2 != 0: 0x100 else: 0)),
      (0x2A7E, gold[resource + 1].int * 2), (0x2ABA, height),
      (0x2A42, gold[resource + 8].int), (0x2A06, 0xEF),
      (0x29CA, (resource + 9) and 0xFFFF), (0x2CD6, resourceId),
      (0x2B6E, layoutId), (0x2BE6, (firstGroup shl 8) or (count - firstGroup))]:
    doAssert snes.getWord(pair[0] + entityOffset) == pair[1]
  for index, address in [0x3366, 0x33A2, 0x33DE, 0x1A4A]:
    doAssert snes.getWord(address + entityOffset) == gold[resource + 4 + index].int
  for address in [0x2D4E, 0x2D12, 0x2C9A, 0x289E]:
    doAssert snes.getWord(address + entityOffset) == 0xFFFF
  for address in [0x2BAA, 0x2DC6, 0x2D8A, 0x2C5E, 0x2B32, 0x2AF6, 0x28DA]:
    doAssert snes.getWord(address + entityOffset) == 0
  for slot in 0 ..< 88:
    doAssert snes.bus.read8(Wram + 0x4A00 + slot.uint32) ==
      (if slot < slots: (entity or 0x80).uint8 else: 0'u8)
  for record in 0 ..< count * 2:
    let
      source = layout + 2 + record * 5
      tile = 0x04303C + (record mod count) * 2
      expected = [gold[source], gold[tile],
        ((gold[source + 2].int and 0xFE) or gold[resource + 3].int or gold[tile + 1].int).uint8,
        gold[source + 3], gold[source + 4]]
    for component, value in expected:
      doAssert snes.bus.read8(Wram + 0x467E + (record * 5 + component).uint32) == value
  for address in 0 ..< snes.vram.len:
    let
      relative = address - 0x4000
      slot = (relative div 0x200) * 8 + (relative mod 0x100) div 0x20
      cleared = clears and relative >= 0 and slot < slots
    doAssert snes.vram[address] == (if cleared: 0'u16 else: Sentinel)
  doAssert not snes.dmaStorm
  let
    cleanupTag = ((resourceId mod 16) shl 12) or resourceId
    effectId = if (resourceId div 16) mod 2 == 0: 0xE1 else: 0xE0
    counter = resourceId mod 3
    beforeVram = snes.vram
    transfers = snes.dmaTransfers
  snes.putWord(0x2C9A + entityOffset, cleanupTag)
  snes.putWord(0x2D12 + entityOffset, effectId)
  snes.putWord(0x4A5C, counter)
  snes.putWord(0x4A60, Sentinel.int)
  if scriptId == 0:
    snes.runCleanupScript(entity)
  else:
    discard snes.call("$C02140", entity)
  doAssert snes.getWord(0x4A5C) ==
    (if (cleanupTag and 0xF000) == 0x8000: (counter - 1) and 0xFFFF else: counter)
  doAssert snes.getWord(0x4A60) == (if effectId == 0xE1: 0 else: Sentinel.int)
  doAssert snes.getWord(0x2CD6 + entityOffset) == 0xFFFF
  doAssert snes.getWord(0x2C9A + entityOffset) == 0xFFFF
  for offset in 0 ..< 0x380:
    doAssert snes.bus.read8(Wram + 0x467E + offset.uint32) == 0xFF
  for slot in 0 ..< 88:
    doAssert snes.bus.read8(Wram + 0x4A00 + slot.uint32) == 0
  doAssert snes.vram == beforeVram and snes.dmaTransfers == transfers
  doAssert snes.getWord(0x0A50) == 0xFFFF
  doAssert snes.getWord(0x0A52) == entityOffset
  doAssert snes.getWord(0x0A54) == 0
  doAssert snes.getWord(0x0A62 + entityOffset) == 0xFFFF
  let respawn = snes.call("$C01E49", resourceId, scriptId, owner)
  doAssert respawn.a == entity.uint16
  doAssert snes.getWord(0x0A50) == entityOffset
  doAssert snes.getWord(0x0ADA + entityOffset) == 0
  doAssert snes.getWord(0x112E + entityOffset) == 0x467E
  doAssert snes.getWord(0x2952 + entityOffset) == 0
  doAssert snes.getWord(0x2CD6 + entityOffset) == resourceId

proc main() =
  ## Cover every resource, automatic/specific entity allocation, and separate script IDs.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
  for resource in 0 ..< 464:
    for owner in [0xFFFF, 5, 29]:
      for scriptId in [0, 7]:
        snes.checkSpawn(gold, resource, scriptId, owner)

when isMainModule:
  main()
