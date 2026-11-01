import
  std/strformat,
  decompbound/[asm_parse, cpu, snesbus],
  ./engine/[original_cpu, rebuilt_rom]

const
  Entries = [0x9713, 0x9731, 0x974F, 0x976D, 0x9792, 0x97B7]
  IntegerFields = [0x0CF6, 0x0D32, 0x0D6E]
  FractionFields = [0x0DAA, 0x0DE6, 0x0E22]
  Guard = 0x5AA5
  StreamBank = 0x7F0000'u32
  EntityCount = 30
  InitialSteps = [0'u32, 0x7FFF8001'u32, 0xFFFFF001'u32]
  ReturnPc = (Caller + 3).uint16

proc putStep(snes: SnesBus, axis, entity: int, value: uint32) =
  ## Install one synthetic 16.16 step as its separate integer/fraction words.
  snes.putWord(IntegerFields[axis] + entity * 2, (value shr 16).int)
  snes.putWord(FractionFields[axis] + entity * 2, (value and 0xFFFF).int)

proc stepValue(snes: SnesBus, axis, entity: int): uint32 =
  ## Read the complete step independently of the handler's XBA-based conversion.
  (snes.word(IntegerFields[axis] + entity * 2).uint32 shl 16) or
    snes.word(FractionFields[axis] + entity * 2).uint32

proc checkHandler(snes: SnesBus, entryIndex, entity, operand, cursor: int,
    initial: uint32) =
  ## Check signed 8.8 scaling, modular addition, and the native stream cursor.
  let
    axis = entryIndex mod 3
    signedOperand = if operand < 0x8000: operand else: operand - 0x10000
    scaled = (signedOperand.int64 * 256) and 0xFFFFFFFF'i64
    expected = (scaled.uint64 + (if entryIndex < 3: 0'u64 else: initial.uint64)) and
      0xFFFFFFFF'u64
  snes.putStep(axis, entity, initial)
  snes.putWord(DirectPage.int + 0x88, entity * 2)
  snes.putWord(DirectPage.int + 0x80, 0)
  snes.putWord(DirectPage.int + 0x82, 0x7F)
  snes.putBytes(StreamBank + cursor.uint32,
    [(operand and 255).uint8, (operand shr 8).uint8])
  var state = Cpu(pc: Caller.uint16, d: DirectPage, dbr: 0x7E,
    s: StackTop, x: 0x1234, y: cursor.uint16,
    p: (if operand mod 2 == 0: FlagC else: FlagV))
  snes.runUntil(state, 0, ReturnPc)
  doAssert snes.stepValue(axis, entity) == expected.uint32,
    &"handler {Entries[entryIndex]:04X}, entity {entity}, operand {operand:04X}"
  doAssert state.x.int == entity * 2 and state.y.int == ((cursor + 2) and 0xFFFF)
  doAssert state.d == DirectPage and state.dbr == 0x7E and state.s == StackTop
  doAssert (state.p and (FlagM or FlagX or FlagD)) == 0
  doAssert snes.word(DirectPage.int + 0x90) == operand

proc checkScriptTick(snes: SnesBus, image: seq[uint8], opcode, operand: int) =
  ## Execute an actual dispatch alias followed by WAIT and then apply its XYZ motion.
  const
    Actor = 23
    StateOffset = 0
    ScriptAddress = 0x7F4000'u32
    PositionFields = [0x0B8E, 0x0BCA, 0x0C06]
    FractionPositions = [0x0C42, 0x0C7E, 0x0CBA]
  let
    tableOffset = if opcode < 0x70: 0x9558 + opcode * 2 else:
      0x95E2 + ((opcode and 0x70) shr 4) * 2
    target = image[tableOffset].int or (image[tableOffset + 1].int shl 8)
  var entryIndex = -1
  for index, entry in Entries:
    if entry == target:
      entryIndex = index
  doAssert entryIndex >= 0
  for axis in 0 .. 2:
    snes.putStep(axis, Actor, 0)
    snes.putWord(PositionFields[axis] + Actor * 2, 100 + axis * 10)
    snes.putWord(FractionPositions[axis] + Actor * 2, 0x8000)
  let script = [opcode.uint8, (operand and 255).uint8, (operand shr 8).uint8,
    6'u8, 2'u8]
  snes.putBytes(ScriptAddress, script)
  snes.putWord(DirectPage.int + 0x88, Actor * 2)
  snes.putWord(DirectPage.int + 0x8A, StateOffset)
  snes.putWord(DirectPage.int + 0x80, 0)
  snes.putWord(0x13FE + StateOffset, 0x4000)
  snes.putWord(0x148A + StateOffset, 0x7F)
  snes.putWord(0x1372 + StateOffset, 0)
  snes.call("JSR $9506")
  let
    inlineWait = if opcode >= 0x70: opcode and 15 else: 0
    firstCursor = if inlineWait > 0: 0x4003 else: 0x4005
    firstWait = if inlineWait > 0: inlineWait - 1 else: 1
  doAssert snes.word(0x13FE) == firstCursor and snes.word(0x1372) == firstWait
  let
    axis = entryIndex mod 3
    signedOperand = if operand < 0x8000: operand else: operand - 0x10000
    delta = (signedOperand.int64 * 256) and 0xFFFFFFFF'i64
  snes.call("JSR $A00C")
  for dimension in 0 .. 2:
    let expected = (((100 + dimension * 10).uint64 shl 16) + 0x8000'u64 +
      (if dimension == axis: delta.uint64 else: 0'u64)) and 0xFFFFFFFF'u64
    doAssert snes.word(PositionFields[dimension] + Actor * 2) == (expected shr 16).int
    doAssert snes.word(FractionPositions[dimension] + Actor * 2) == (expected and 0xFFFF).int
  snes.call("JSR $9506")
  doAssert snes.word(0x1372) == (if firstWait > 0: firstWait - 1 else: 1)
  doAssert snes.word(0x13FE) == (if firstWait > 0: firstCursor else: 0x4005)

proc main() =
  ## Sweep every operand on all six original/rebuilt handlers and verify interpreter integration.
  var
    directCases = 0
    scriptCases = 0
  for image in engineImages("bin/action_motion_extract"):
    let snes = newSnesBus(image)
    for entryIndex, entry in Entries:
      let axis = entryIndex mod 3
      snes.putBytes(Caller, assembleAsm(&".a16\n.i16\nJSR ${entry:04X}\n", Caller))
      for fields in [IntegerFields, FractionFields]:
        for field in fields:
          for slot in 0 ..< EntityCount:
            snes.putWord(field + slot * 2, Guard)
      for operand in 0 .. 0xFFFF:
        snes.checkHandler(entryIndex, 5, operand, 0x40, InitialSteps[entryIndex mod 3])
        inc directCases
      for slot in 0 ..< EntityCount:
        if slot != 5:
          doAssert snes.word(IntegerFields[axis] + slot * 2) == Guard
          doAssert snes.word(FractionFields[axis] + slot * 2) == Guard
      for entity in 0 ..< EntityCount:
        for operand in [0, 1, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFF00, 0xFFFF]:
          for initial in InitialSteps:
            snes.checkHandler(entryIndex, entity, operand, 0xFFFF, initial)
            inc directCases
      for otherAxis in 0 .. 2:
        if otherAxis != axis:
          for slot in 0 ..< EntityCount:
            doAssert snes.word(IntegerFields[otherAxis] + slot * 2) == Guard
            doAssert snes.word(FractionFields[otherAxis] + slot * 2) == Guard
    for opcode in 0 .. 255:
      if opcode in 77 ..< 0x70:
        continue
      let
        offset = if opcode < 0x70: 0x9558 + opcode * 2 else:
          0x95E2 + ((opcode and 0x70) shr 4) * 2
        target = image[offset].int or (image[offset + 1].int shl 8)
      if target in Entries:
        for operand in [0, 0x180, 0xFF80, 0x7FFF, 0x8000]:
          snes.checkScriptTick(image, opcode, operand)
          inc scriptCases
  echo &"action motion: {directCases} handler cases and {scriptCases} script/movement cases passed"

when isMainModule:
  main()
