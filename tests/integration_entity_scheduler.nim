import
  decompbound/[adopted, asm_parse, cpu, rom_pipeline, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  Entities = [0, 5, 29]
  States = [0, 3, 69]
  ExtraStates = [1, 4, 68]
  NativeCallback = 0x1B00
  SecondaryCallback = 0x1B10
  PositionCallback = 0x1B20
  FinalCallback = 0x1B30

type
  EventKind = enum
    NoEvent, ScriptTick, FarCallback, Secondary, Position, AfterEntities
  Event = tuple[kind: EventKind, id: int]

proc putWord(snes: SnesBus, address, value: int) =
  ## Seed a synthetic scheduler field.
  snes.bus.write8(Wram + address.uint32, (value and 255).uint8)
  snes.bus.write8(Wram + address.uint32 + 1, ((value shr 8) and 255).uint8)

proc word(snes: SnesBus, address: int): int =
  ## Read a scheduler result field.
  snes.bus.read16(Wram + address.uint32).int

proc run(snes: SnesBus): seq[Event] =
  ## Execute both original scheduler passes while observing synthetic callback entry points.
  var
    cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x300, dbr: 0x7E)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != (Caller + 4).uint16:
    doAssert steps < 10000
    var event: Event = (NoEvent, -1)
    if cpu.pbr == 0x80:
      case cpu.pc.int
      of 0x9506: event = (ScriptTick, snes.word(0x1A46))
      of SecondaryCallback: event = (Secondary, snes.word(0x1A42))
      of PositionCallback: event = (Position, snes.word(0x1A42))
      of FinalCallback: event = (AfterEntities, -1)
      else: discard
    elif cpu.pbr == 0x7E and cpu.pc == NativeCallback:
      event = (FarCallback, snes.word(0x1A42))
    if event.kind != NoEvent:
      doAssert snes.word(0x0A60) == 1 and cpu.d == 0x200
      result.add event
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.s == 0x1FFF and cpu.d == 0x300 and cpu.dbr == 0x7E

proc checkPasses(snes: SnesBus, flags, chains: int) =
  ## Compare observed execution order to two independent ordered passes over synthetic entities.
  snes.putWord(0x0A50, Entities[0] * 2)
  snes.putWord(0x0A60, 0)
  snes.putWord(0x0A5E, FinalCallback)
  var expected: seq[Event]
  for index, entity in Entities:
    let
      bits = (flags shr (index * 2)) and 3
      extra = (chains and (1 shl index)) != 0
      state = States[index]
    snes.putWord(0x0A9E + entity * 2, if index == Entities.high: 0xFFFF else: Entities[index + 1] * 2)
    snes.putWord(0x10B6 + entity * 2, 0x7E or (bits shl 14))
    snes.putWord(0x107A + entity * 2, NativeCallback)
    snes.putWord(0x121E + entity * 2, SecondaryCallback)
    snes.putWord(0x11A6 + entity * 2, PositionCallback)
    snes.putWord(0x0ADA + entity * 2, state * 2)
    snes.putWord(0x125A + state * 2, if extra: ExtraStates[index] * 2 else: 0xFFFF)
    snes.putWord(0x125A + ExtraStates[index] * 2, 0xFFFF)
    snes.putWord(0x1372 + state * 2, 1)
    snes.putWord(0x1372 + ExtraStates[index] * 2, 1)
    if (bits and 1) == 0:
      expected.add (ScriptTick, state)
      if extra:
        expected.add (ScriptTick, ExtraStates[index])
    if (bits and 2) == 0:
      expected.add (FarCallback, entity)
  for index, entity in Entities:
    if ((flags shr (index * 2)) and 1) == 0:
      expected.add (Secondary, entity)
    expected.add (Position, entity)
  expected.add (AfterEntities, -1)
  doAssert snes.run() == expected
  doAssert snes.word(0x0A60) == 0
  for index, state in States:
    let executes = ((flags shr (index * 2)) and 1) == 0
    doAssert snes.word(0x1372 + state * 2) == (if executes: 0 else: 1)
    doAssert snes.word(0x1372 + ExtraStates[index] * 2) ==
      (if executes and (chains and (1 shl index)) != 0: 0 else: 1)

proc checkRemovalDuringPass(snes: SnesBus, victimIndex: int) =
  ## Remove a current or upcoming entity from a native callback and verify traversal resumes safely.
  let
    victim = Entities[victimIndex]
    removalCode = assembleAsm(".a16\n.i16\nLDA #" & $victim &
      "\nJSL $C09C35\nRTL\n", NativeCallback.uint32)
  for index, value in removalCode:
    snes.bus.write8(Wram + NativeCallback.uint32 + index.uint32, value)
  snes.putWord(0x0A50, Entities[0] * 2)
  snes.putWord(0x0A52, 2)
  snes.putWord(0x0A9E + 2, 0xFFFF)
  snes.putWord(0x0A5E, FinalCallback)
  snes.putWord(0x0A54, 20)
  snes.putWord(0x125A + 20, 0xFFFF)
  snes.putWord(0x0A60, 0)
  var expected: seq[Event]
  for index, entity in Entities:
    snes.putWord(0x0A9E + entity * 2, if index == Entities.high: 0xFFFF else: Entities[index + 1] * 2)
    snes.putWord(0x121E + entity * 2, SecondaryCallback)
    snes.putWord(0x11A6 + entity * 2, PositionCallback)
    snes.putWord(0x0A62 + entity * 2, 7)
    snes.putWord(0x10B6 + entity * 2, 0x7E)
    snes.putWord(0x107A + entity * 2, NativeCallback)
    snes.putWord(0x0ADA + entity * 2, States[index] * 2)
    snes.putWord(0x125A + States[index] * 2, 0xFFFF)
    snes.putWord(0x1372 + States[index] * 2, 1)
    if index == 0 or index != victimIndex:
      expected.add (ScriptTick, States[index])
      expected.add (FarCallback, entity)
  for index, entity in Entities:
    if index != victimIndex:
      expected.add (Secondary, entity)
      expected.add (Position, entity)
  expected.add (AfterEntities, -1)
  doAssert snes.run() == expected
  doAssert snes.word(0x0A60) == 0
  doAssert snes.word(0x0A52) == victim * 2
  doAssert snes.word(0x0A9E + victim * 2) == 2
  doAssert snes.word(0x0A54) == States[victimIndex] * 2
  doAssert snes.word(0x125A + States[victimIndex] * 2) == 20
  doAssert snes.word(0x0A62 + victim * 2) == 0xFFFF

proc main() =
  ## Sweep callback flags and attached-state chains, then verify empty and locked entry.
  let
    gold = readGoldBaserom()
    snes = newSnesBus(gold)
  doAssert assembleAdoptedFile("scheduleEntities", 0x9466) == gold[0x9466 ..< 0x9506]
  for entry in [(Caller.int, "JSL $C09466"), (NativeCallback, "RTL"),
      (SecondaryCallback, "RTS"), (PositionCallback, "RTS"), (FinalCallback, "RTS")]:
    let code = assembleAsm(".a16\n.i16\n" & entry[1] & "\n", entry[0].uint32)
    for index, value in code:
      snes.bus.write8(Wram + entry[0].uint32 + index.uint32, value)
  for flags in 0 ..< 64:
    for chains in 0 ..< 8:
      snes.checkPasses(flags, chains)
  for victimIndex in 0 .. Entities.high:
    snes.checkRemovalDuringPass(victimIndex)
  snes.putWord(0x0A50, 0xFFFF)
  doAssert snes.run().len == 0
  doAssert snes.word(0x0A60) == 0
  for lock in [1, 0xFFFF]:
    snes.putWord(0x0A60, lock)
    snes.putWord(0x0A50, 0)
    doAssert snes.run().len == 0
    doAssert snes.word(0x0A60) == lock

when isMainModule:
  main()
