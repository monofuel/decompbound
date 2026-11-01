import
  std/strformat,
  decompbound/[asm_parse, cpu, snesbus],
  ./engine/[original_cpu, rebuilt_rom]

const
  StreamBank = 0x7F0000'u32
  ByteTarget = 0x3000
  WordTarget = 0x3100
  Fields = [0x0E5E, 0x0E9A, 0x0ED6, 0x0F12, 0x0F4E, 0x0F8A, 0x0FC6, 0x1002]
  WordValues = [0, 1, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFF00, 0xFFFF]

proc expectedOperation(old, operand, operation, mask: int): int =
  ## Specify the logical operation or binary sum independently of dispatch instructions.
  case operation
  of 0: old and operand
  of 1: old or operand
  of 2: (old + operand) and mask
  of 3: old xor operand
  else: raise newException(ValueError, "Synthetic operation selector is invalid")

proc setup(snes: SnesBus, entity, state: int) =
  ## Install isolated synthetic stream and current-context fields.
  snes.putWord(DirectPage.int + 0x80, 0)
  snes.putWord(DirectPage.int + 0x82, 0x7F)
  snes.putWord(DirectPage.int + 0x88, entity * 2)
  snes.putWord(DirectPage.int + 0x8A, state * 2)

proc run(snes: SnesBus, cursor: int, bank: uint8): Cpu =
  ## Run one already installed handler trampoline, accepting the byte path's bank-zero return.
  result = Cpu(pbr: bank, pc: Caller.uint16, s: StackTop, d: DirectPage,
    dbr: 0x7E, y: cursor.uint16, p: FlagC or FlagV)
  snes.runUntil(result, 0, (Caller + 3).uint16)
  doAssert result.s == StackTop and result.d == DirectPage and result.dbr == 0x7E
  doAssert (result.p and (FlagM or FlagX or FlagD)) == 0

proc checkByte(snes: SnesBus, old, operand, operation: int, bank: uint8) =
  ## Check byte-width writes, operand overread, carry reset and the PBR transition.
  const Cursor = 0x4000
  snes.putWord(ByteTarget - 1, 0xA5)
  snes.putWord(ByteTarget, old or 0x5A00)
  snes.putBytes(StreamBank + Cursor, [0'u8, 0x30, operation.uint8, operand.uint8, 0xB7])
  let
    state = snes.run(Cursor, bank)
    expected = expectedOperation(old, operand, operation, 255)
  doAssert state.a.int == expected and state.x == 0 and state.y.int == Cursor + 4
  doAssert snes.word(ByteTarget) == (expected or 0x5A00)
  doAssert snes.bus.read8(Wram + (ByteTarget - 1).uint32) == 0xA5
  doAssert snes.word(DirectPage.int + 0x90) == (operand or 0xB700)
  doAssert snes.word(0x0A5C) == 0
  doAssert ((state.p and FlagC) != 0) == (operation == 2 and old + operand > 255)

proc checkWord(snes: SnesBus, entity, stateId, field, old, operand, operation,
    mode, cursor: int) =
  ## Check direct, template-indexed and state-value word targets with guarded neighbors.
  snes.setup(entity, stateId)
  let
    target = case mode
      of 0: WordTarget
      of 1: Fields[field] + entity * 2
      else: 0x1516 + stateId * 2
    entry = [0x9A9F, 0x9A87, 0x9A97][mode]
  var bytes: seq[uint8]
  case mode
  of 0: bytes.add [(target and 255).uint8, (target shr 8).uint8]
  of 1: bytes.add field.uint8
  else: discard
  bytes.add [operation.uint8, (operand and 255).uint8, (operand shr 8).uint8]
  snes.putBytes(StreamBank + cursor.uint32, bytes)
  snes.putWord(target - 2, 0xA55A)
  snes.putWord(target, old)
  snes.putWord(target + 2, 0x5AA5)
  let result = snes.call(&"JSR ${entry:04X}", y = cursor, status = FlagC or FlagV)
  doAssert snes.word(target) == expectedOperation(old, operand, operation, 0xFFFF)
  doAssert snes.word(target - 2) == 0xA55A and snes.word(target + 2) == 0x5AA5
  doAssert result.y.int == ((cursor + bytes.len) and 0xFFFF)
  doAssert result.x.int == operation * 2
  doAssert ((result.p and FlagC) != 0) == (operation == 2 and old + operand > 0xFFFF)

proc checkSetter(snes: SnesBus, entity, field, value: int) =
  ## Check the indexed setter's actual write and prove incoming carry adds no extra address byte.
  snes.setup(entity, 0)
  let target = Fields[field] + entity * 2
  snes.putWord(target - 2, 0xA55A)
  snes.putWord(target, value xor 0xFFFF)
  snes.putWord(target + 2, 0x5AA5)
  snes.putBytes(StreamBank + 0x4000, [field.uint8, (value and 255).uint8, (value shr 8).uint8])
  let state = snes.call("JSR $9AE2", y = 0x4000, status = FlagC)
  doAssert snes.word(target) == value and state.a.int == value and state.x.int == target
  doAssert state.y == 0x4003
  doAssert snes.word(target - 2) == 0xA55A and snes.word(target + 2) == 0x5AA5

proc checkScript(snes: SnesBus, mode, operation: int, programBank: uint8) =
  ## Execute a complete opcode/fetch/WAIT path, including the byte handler's mirror switch.
  const
    Entity = 5
    StateId = 3
    Cursor = 0x4000
    Operand = 0x80
    Old = 0xFF
  snes.setup(Entity, StateId)
  let
    opcode = [0x18, 0x0D, 0x14, 0x27, 0x0E][mode]
    target = case mode
      of 0: ByteTarget
      of 1: WordTarget
      of 2, 4: Fields[2] + Entity * 2
      else: 0x1516 + StateId * 2
  var script = @[opcode.uint8]
  case mode
  of 0, 1: script.add [(target and 255).uint8, (target shr 8).uint8]
  of 2, 4: script.add 2'u8
  else: discard
  if mode != 4:
    script.add operation.uint8
  script.add Operand.uint8
  if mode != 0:
    script.add 0'u8
  script.add [6'u8, 2]
  snes.putBytes(StreamBank + Cursor, script)
  snes.putWord(target, Old)
  snes.putWord(0x13FE + StateId * 2, Cursor)
  snes.putWord(0x148A + StateId * 2, 0x7F)
  snes.putWord(0x1372 + StateId * 2, 0)
  snes.putBytes(Caller, assembleAsm(".a16\n.i16\nJSR $9506\n", Caller))
  var state = Cpu(pbr: programBank, pc: Caller.uint16, s: StackTop,
    d: DirectPage, dbr: 0x7E)
  snes.runUntil(state, if mode == 0: 0'u8 else: programBank, (Caller + 3).uint16)
  doAssert state.s == StackTop and state.d == DirectPage
  doAssert snes.word(target) == (if mode == 4: Operand else:
    expectedOperation(Old, Operand, operation, if mode == 0: 255 else: 0xFFFF))
  doAssert snes.word(0x13FE + StateId * 2) == Cursor + script.len
  doAssert snes.word(0x1372 + StateId * 2) == 1

proc main() =
  ## Verify every byte-input pair, word boundary classes, field layout and interpreter integration.
  var cases = 0
  for image in engineImages("bin/action_operations_extract"):
    let snes = newSnesBus(image)
    snes.setup(5, 3)
    snes.putBytes(Caller, assembleAsm(".a16\n.i16\nJSR $9A5C\n", Caller))
    for old in 0 .. 255:
      for operand in 0 .. 255:
        for operation in 0 .. 3:
          snes.checkByte(old, operand, operation, if old mod 2 == 0: 0'u8 else: 0x80'u8)
          inc cases
    for entity in [0, 5, 29]:
      for state in [0, 3, 69]:
        for mode in 0 .. 2:
          for field in 0 .. (if mode == 1: 7 else: 0):
            for old in WordValues:
              for operand in WordValues:
                for operation in 0 .. 3:
                  snes.checkWord(entity, state, field, old, operand, operation, mode, 0x4000)
                  inc cases
    for entity in 0 .. 29:
      for field in 0 .. 7:
        for value in WordValues:
          snes.checkSetter(entity, field, value)
          inc cases
    for mode in 0 .. 4:
      for operation in 0 .. 3:
        for bank in [0'u8, 0x80'u8]:
          snes.checkScript(mode, operation, bank)
          inc cases
  echo &"action operations: {cases} original/rebuilt byte, word, field and dispatch cases passed"

when isMainModule:
  main()
