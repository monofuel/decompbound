import
  decompbound/[adopted, asm_parse, cpu, rom_pipeline, snesbus]

const
  Caller = 0x1E00'u32
  Wram = 0x7E0000'u32
  Script = 0x7F4000'u32
  FrameWithWait = 0x80
  WaitOpcode = 0x06'u8

proc putWord(snes: SnesBus, address, value: int) =
  ## Seed a synthetic script-state or entity field.
  snes.bus.write8(Wram + address.uint32, (value and 255).uint8)
  snes.bus.write8(Wram + address.uint32 + 1, ((value shr 8) and 255).uint8)

proc word(snes: SnesBus, address: int): int =
  ## Read an interpreter result word.
  snes.bus.read16(Wram + address.uint32).int

proc tick(snes: SnesBus) =
  ## Execute one complete original fetch/dispatch tick.
  var
    cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x200, dbr: 0x7E)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != (Caller + 3).uint16:
    doAssert steps < 1000
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.s == 0x1FFF and cpu.d == 0x200 and cpu.dbr == 0x7E

proc checkFrame(snes: SnesBus, entity, state, frame, delay: int) =
  ## Verify frame writes use the entity offset while waits and cursors use the state offset.
  let stream = [(FrameWithWait or delay).uint8, frame.uint8, WaitOpcode, 2'u8,
    (FrameWithWait or 1).uint8, 0xFF'u8]
  for index, value in stream:
    snes.bus.write8(Script + index.uint32, value)
  snes.putWord(0x280, 0)
  snes.putWord(0x288, entity * 2)
  snes.putWord(0x28A, state * 2)
  snes.putWord(0x13FE + state * 2, 0x4000)
  snes.putWord(0x148A + state * 2, 0x7F)
  snes.putWord(0x1372 + state * 2, 0)
  for id in 0 ..< 30:
    snes.putWord(0x10F2 + id * 2, 0x1234)
  snes.tick()
  for id in 0 ..< 30:
    doAssert snes.word(0x10F2 + id * 2) ==
      (if id != entity: 0x1234 elif frame == 255: 0xFFFF else: frame)
  doAssert snes.word(0x284) == 0x15A2 + state * 16
  let
    cursor = if delay == 0: 0x4004 else: 0x4002
    remaining = if delay == 0: 1 else: delay - 1
  doAssert snes.word(0x13FE + state * 2) == cursor
  doAssert snes.word(0x1372 + state * 2) == remaining
  for countdown in countdown(remaining - 1, 0):
    snes.tick()
    doAssert snes.word(0x1372 + state * 2) == countdown
    doAssert snes.word(0x13FE + state * 2) == cursor
  if delay != 0:
    snes.tick()
    doAssert snes.word(0x13FE + state * 2) == 0x4004
    doAssert snes.word(0x1372 + state * 2) == 1
    snes.tick()
  snes.tick()
  doAssert snes.word(0x10F2 + entity * 2) == 0xFFFF
  doAssert snes.word(0x13FE + state * 2) == 0x4006
  doAssert snes.word(0x1372 + state * 2) == 0

proc checkPublishedFrame(snes: SnesBus, gold: seq[uint8], entity: int) =
  ## Follow script-installed callbacks through original OAM publication.
  let
    caller = Caller + 16
    code = assembleAsm(".a16\n.i16\nJSL $C088B1\nLDX $88\nJSR ($11A6,X)\nJSR $A0E3\nJSL $C08B26\n", caller)
    entityOffset = entity * 2
    table = 0x2FF5BB
    definition = 0x2F0000 + gold[table].int + (gold[table + 1].int shl 8)
  for index, value in code:
    snes.bus.write8(caller + index.uint32, value)
  snes.putWord(0x2E, 1)
  snes.putWord(0x103E + entityOffset, 0)
  snes.putWord(0x0B8E + entityOffset, 128)
  snes.putWord(0x0BCA + entityOffset, 112)
  var
    cpu = Cpu(pc: caller.uint16, s: 0x1FFF, d: 0x200, dbr: 0x7E)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != (caller + code.len.uint32).uint16:
    doAssert steps < 5000
    cpu.step(snes.bus)
    inc steps
  doAssert snes.word(0x0B16 + entityOffset) == 128
  doAssert snes.word(0x0B52 + entityOffset) == 112
  var
    record = 0
    expectedHigh: array[32, uint8]
  while true:
    let
      source = definition + record * 5
      x = 128 + cast[int8](gold[source + 3]).int
      y = 111 + cast[int8](gold[source]).int
      flags = gold[source + 4]
    doAssert record < 128 and gold[source] != 0x80
    doAssert x in 0 .. 255 and y in 0 .. 223
    for component, expected in [(x and 255).uint8, y.uint8, gold[source + 1], gold[source + 2]]:
      doAssert snes.bus.read8(Wram + (0x500 + record * 4 + component).uint32) == expected
    expectedHigh[record div 4] = expectedHigh[record div 4] or
      ((flags and 1) shl ((record mod 4) * 2 + 1))
    inc record
    if (flags and 0x80) != 0:
      break
  for index in 0 .. (record - 1) div 4:
    doAssert snes.bus.read8(Wram + 0x700 + index.uint32) == expectedHigh[index]
  doAssert snes.bus.read8(Wram + (0x501 + record * 4).uint32) == 0xE0
  doAssert snes.word(0x2C) == 1

proc checkOriginalLoop(snes: SnesBus, gold: seq[uint8], entity, state: int) =
  ## Execute selector zero directly from the ROM and verify its periodic graphics upload.
  let
    pointer = 0x0400D4
    start = gold[pointer].int or (gold[pointer + 1].int shl 8)
    bank = gold[pointer + 2].int
    uploadsBefore = snes.dmaTransfers
  snes.initHdma()
  snes.bus.write8(Wram + 0x0D, 0x80)
  snes.putWord(0x280, 0)
  snes.putWord(0x288, entity * 2)
  snes.putWord(0x28A, state * 2)
  snes.putWord(0x13FE + state * 2, start)
  snes.putWord(0x148A + state * 2, bank)
  snes.putWord(0x1372 + state * 2, 0)
  for value in snes.vram.mitems:
    value = 0x5A5A
  for iteration in 0 .. 25:
    snes.tick()
    doAssert snes.word(0x10F2 + entity * 2) == 0
    doAssert snes.word(0x112E + entity * 2) == 0xF5BB
    doAssert snes.word(0x116A + entity * 2) == 0xEF
    doAssert snes.word(0x11A6 + entity * 2) == 0xA0BB
    doAssert snes.word(0x11E2 + entity * 2) == 0xA0FA
    doAssert snes.word(0x13FE + state * 2) == 0xFFC5
    doAssert snes.word(0x1372 + state * 2) == 4 - iteration mod 5
    doAssert snes.dmaTransfers - uploadsBefore == (iteration div 5)
    for address in 0 ..< snes.vram.len:
      let expected = if iteration >= 5 and address in 0x4000 ..< 0x4100:
          gold[0x2FEFB7 + (address - 0x4000) * 2].uint16 or
            (gold[0x2FEFB8 + (address - 0x4000) * 2].uint16 shl 8)
        else: 0x5A5A'u16
      doAssert snes.vram[address] == expected
  doAssert not snes.dmaStorm
  snes.checkPublishedFrame(gold, entity)

proc main() =
  ## Require the local ROM and verify original bytes plus frame/wait execution.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
    code = assembleAsm(".a16\n.i16\nJSR $9506\n", Caller)
  doAssert actionScriptFetch().len == 82
  doAssert actionScriptFetch() == gold[ActionScriptFetchOffset ..< ActionScriptFetchOffset + 82]
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  for entity in [0, 5, 29]:
    for state in [0, 3, 69]:
      snes.checkOriginalLoop(gold, entity, state)
      for frame in 0 .. 255:
        for delay in 0 .. 15:
          snes.checkFrame(entity, state, frame, delay)

when isMainModule:
  main()
