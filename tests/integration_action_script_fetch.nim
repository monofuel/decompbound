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
