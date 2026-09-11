import
  decompbound/[asm_parse, cpu, memmap, rom_pipeline, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  StepLimit = 30000

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

proc checkAnimation(gold: seq[uint8], owner, scriptId, direction: int) =
  ## Verify original script timing and alternating uploaded graphics on a fully spawned sprite.
  let
    snes = newSnesBus(gold)
    entityOffset = owner * 2
  discard snes.call("$C09282")
  discard snes.call("$C01A86")
  discard snes.call("$C01C11", 0x8000)
  snes.bus.write8(Wram + 0x0D, 0x80)
  snes.putWord(0x20E, 128)
  snes.putWord(0x210, 112)
  discard snes.call("$C01E49", 437, scriptId, owner)
  snes.putWord(0x280, 0)
  snes.putWord(0x288, entityOffset)
  snes.putWord(0x28A, 0)
  snes.putWord(0x1A42, owner)
  snes.putWord(0x2AF6 + entityOffset, direction)
  let
    uploadsBefore = snes.dmaTransfers
    resourcePointer = 0x2F133F + 437 * 4
    resource = snesToFile(gold[resourcePointer].uint32 or (gold[resourcePointer + 1].uint32 shl 8) or (gold[resourcePointer + 2].uint32 shl 16))
    directionOffset = 0xA60B + direction * 2
    entryIndex = gold[directionOffset].int + (gold[directionOffset + 1].int shl 8)
  var expectedVram = snes.vram
  let code = assembleAsm(".a16\n.i16\nJSR $9506\n", Caller)
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  for iteration in 0 ..< 66:
    snes.initHdma()
    var
      cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x200, dbr: 0x7E)
      steps = 0
    while cpu.pbr != 0 or cpu.pc != (Caller + 3).uint16:
      doAssert steps < 30000
      cpu.step(snes.bus)
      inc steps
    let
      phase = (iteration div 16) mod 2
      entry = resource + 9 + entryIndex * 4 + phase * 2
      encoded = gold[entry].int + (gold[entry + 1].int shl 8)
      source = snesToFile((gold[resource + 8].uint32 shl 16) or (encoded and 0xFFF0).uint32)
    doAssert snes.getWord(0x10F2 + entityOffset) == phase
    doAssert snes.getWord(0x2892) == phase
    doAssert snes.getWord(0x1372) == 15 - iteration mod 16
    doAssert snes.getWord(0x13FE) == (if phase == 0: 0xA1F5 else: 0xA1FD)
    doAssert snes.getWord(0x341A + entityOffset) == encoded
    doAssert snes.getWord(0x2BAA + entityOffset) == 0
    doAssert snes.dmaTransfers - uploadsBefore == (iteration div 16 + 1) * 3
    for row, destination in [0x4100, 0x4020, 0x4120]:
      for word in 0 ..< 32:
        let offset = source + row * 64 + word * 2
        expectedVram[destination + word] = gold[offset].uint16 or (gold[offset + 1].uint16 shl 8)
    doAssert snes.vram == expectedVram
    doAssert not snes.dmaStorm

proc main() =
  ## Sweep both original selector aliases, entity slots, and all eight directions.
  let gold = readGoldBaserom()
  for owner in [0, 5, 29]:
    for scriptId in [10, 11]:
      for direction in 0 .. 7:
        checkAnimation(gold, owner, scriptId, direction)

when isMainModule:
  main()
