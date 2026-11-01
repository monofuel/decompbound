import
  std/strformat,
  decompbound/[asm_parse, cpu, snesbus],
  ./engine/[original_cpu, rebuilt_rom]

const
  StreamBank = 0x7F0000'u32
  NativeTarget = 0x7E1D00'u32
  Counter = 0x1C00
  GuardByte = 0x5A'u8

proc setup(snes: SnesBus, state, depth: int) =
  ## Install stream/state pointers and a guarded byte-oriented software stack.
  snes.putWord(DirectPage.int + 0x80, 0)
  snes.putWord(DirectPage.int + 0x82, 0xA57F)
  snes.putWord(DirectPage.int + 0x84, 0x15A2 + state * 16)
  snes.putWord(DirectPage.int + 0x88, 10)
  snes.putWord(DirectPage.int + 0x8A, state * 2)
  snes.putWord(0x12E6 + state * 2, depth)
  for index in 0 ..< 32:
    snes.bus.write8(Wram + (0x15A2 + state * 16 + index).uint32, GuardByte)

proc wordOperand(snes: SnesBus, cursor, value: int) =
  ## Supply the two bytes actually touched by a long indexed word read.
  snes.putBytes(StreamBank + cursor.uint32,
    [(value and 255).uint8, (value shr 8).uint8])

proc checkLoopRecord(snes: SnesBus, state, depth, cursor, count, spill: int,
    fromWork: bool) =
  ## Check the three-byte record, its word-store spill and one width-sensitive decrement.
  snes.setup(state, depth)
  let
    countWord = count or (spill shl 8)
    body = (cursor + (if fromWork: 0 else: 1)) and 0xFFFF
    base = 0x15A2 + state * 16 + depth
  snes.wordOperand(cursor, countWord)
  snes.putWord(0x1516 + state * 2, countWord)
  let start = snes.call(if fromWork: "JSR $9620" else: "JSR $9603", y = cursor,
    status = FlagC or FlagV)
  doAssert start.y.int == body and start.x.int == state * 2
  doAssert snes.word(0x12E6 + state * 2) == depth + 3
  doAssert snes.word(base) == body and snes.word(base + 2) == countWord
  doAssert (start.p and (FlagC or FlagV)) == (FlagC or FlagV)
  let
    finishCursor = 0x4321
    remaining = (count - 1) and 255
    finish = snes.call("JSR $9627", y = finishCursor, status = FlagC or FlagV)
  doAssert finish.y.int == (if remaining == 0: finishCursor else: body)
  doAssert snes.word(0x12E6 + state * 2) == (if remaining == 0: depth else: depth + 3)
  doAssert snes.word(base + 2) == (remaining or (spill shl 8))
  doAssert (finish.p and (FlagM or FlagX)) == 0
  doAssert (finish.p and (FlagC or FlagV)) == (FlagC or FlagV)
  for index in 0 ..< 32:
    if index < depth or index >= depth + 4:
      doAssert snes.bus.read8(Wram + (0x15A2 + state * 16 + index).uint32) == GuardByte

proc checkFarRecord(snes: SnesBus, state, depth, cursor, target, bank, adjacent: int) =
  ## Verify three-byte banked returns read the current spill byte rather than saved metadata.
  snes.setup(state, depth)
  let base = 0x15A2 + state * 16 + depth
  snes.wordOperand(cursor, target)
  snes.wordOperand((cursor + 2) and 0xFFFF, bank or 0xB600)
  let started = snes.call("JSR $9685", y = cursor, status = FlagC or FlagV)
  doAssert started.y.int == target and snes.word(0x12E6 + state * 2) == depth + 3
  doAssert snes.word(base) == ((cursor + 3) and 0xFFFF)
  doAssert snes.word(base + 2) == 0xA57F
  doAssert snes.word(DirectPage.int + 0x82) == (bank or 0xB600)
  snes.bus.write8(Wram + (base + 3).uint32, adjacent.uint8)
  let returned = snes.call("JSR $96AA", y = 0x1234, status = FlagC or FlagV)
  doAssert returned.y.int == ((cursor + 3) and 0xFFFF)
  doAssert snes.word(0x12E6 + state * 2) == depth
  doAssert snes.word(DirectPage.int + 0x82) == (0x7F or (adjacent shl 8))
  doAssert (returned.p and (FlagC or FlagV)) == (FlagC or FlagV)

proc fetch(snes: SnesBus) =
  ## Execute a deliberately long but bounded complete interpreter tick.
  snes.putBytes(Caller, assembleAsm(".a16\n.i16\nJSR $9506\n", Caller))
  var
    state = Cpu(pc: Caller.uint16, s: StackTop, d: DirectPage, dbr: 0x7E)
    steps = 0
  while state.pbr != 0 or state.pc != (Caller + 3).uint16:
    doAssert steps < 200000, "A synthetic finite loop failed to reach its WAIT"
    state.step(snes.bus)
    inc steps
  doAssert state.s == StackTop and state.d == DirectPage and state.dbr == 0x7E

proc checkFiniteLoop(snes: SnesBus, state, count: int, fromWork: bool) =
  ## Count real native invocations to prove zero represents 256 loop iterations.
  snes.setup(state, 0)
  snes.putWord(Counter, 0)
  snes.putWord(0x1516 + state * 2, count or 0xA500)
  snes.putWord(0x13FE + state * 2, 0x4000)
  snes.putWord(0x148A + state * 2, 0x7F)
  snes.putWord(0x1372 + state * 2, 0)
  var script = if fromWork: @[0x24'u8] else: @[1'u8, count.uint8]
  script.add [0x42'u8, 0, 0x1D, 0x7E, 2, 6, 2]
  snes.putBytes(StreamBank + 0x4000, script)
  snes.fetch()
  doAssert snes.word(Counter) == (if count == 0: 256 else: count)
  doAssert snes.word(0x13FE + state * 2) == 0x4000 + script.len
  doAssert snes.word(0x1372 + state * 2) == 1
  doAssert snes.word(0x12E6 + state * 2) == 0

proc checkNestedFar(snes: SnesBus, state, depth: int) =
  ## Traverse alternating stream banks and unwind every three-byte record.
  snes.setup(state, 0)
  snes.putWord(Counter, 0)
  snes.putWord(0x13FE + state * 2, 0x4000)
  snes.putWord(0x148A + state * 2, 0xA57F)
  snes.putWord(0x1372 + state * 2, 0)
  snes.putBytes(StreamBank + 0x4000, [4'u8, 0, 0x41, 0x7E, 6, 2])
  for level in 0 ..< depth:
    let
      address = 0x4100 + level * 0x20
      bank = if level mod 2 == 0: 0x7E else: 0x7F
      full = ((bank shl 16) or address).uint32
    if level == depth - 1:
      snes.putBytes(full, [0x42'u8, 0, 0x1D, 0x7E, 5])
    else:
      let target = address + 0x20
      snes.putBytes(full, [4'u8, (target and 255).uint8, (target shr 8).uint8,
        (bank xor 1).uint8, 5])
  snes.fetch()
  doAssert snes.word(Counter) == 1 and snes.word(0x12E6 + state * 2) == 0
  doAssert snes.word(0x13FE + state * 2) == 0x4006
  doAssert snes.word(0x148A + state * 2) == (if depth == 1: 0xA57F else: 0x047F)
  doAssert snes.word(0x1372 + state * 2) == 1

proc checkEmptyFar(snes: SnesBus, entity: int, survivor, throughFetch: bool) =
  ## Check empty banked returns share the same detach/last-state behavior as near returns.
  snes.call("JSL $C09282")
  snes.putWord(0x0A4C, entity)
  snes.putWord(0x0A4E, entity + 1)
  snes.call("JSL $C09321", a = 0)
  snes.putWord(0x0ADA + entity * 2, 2)
  snes.putWord(0x125C, if survivor: 0 else: 0xFFFF)
  snes.putWord(0x125A, if survivor: 0xFFFF else: 4)
  snes.putWord(0x0A54, if survivor: 4 else: 0)
  snes.setup(1, 0)
  snes.putWord(DirectPage.int + 0x88, entity * 2)
  var cursor: int
  if throughFetch:
    snes.putWord(0x13FE + 2, 0x4000)
    snes.putWord(0x148A + 2, 0x7F)
    snes.putWord(0x1372 + 2, 0)
    snes.putBytes(StreamBank + 0x4000, [5'u8])
    snes.fetch()
    cursor = snes.word(0x13FE + 2)
  else:
    cursor = snes.call("JSR $96AA", y = 0x1234).y.int
  doAssert cursor == (if survivor: 0 else: 2)
  doAssert snes.word(0x0A54) == 2
  doAssert snes.word(0x1372 + 2) == (if throughFetch: 0xFFFE else: 0xFFFF)
  doAssert snes.word(0x0A50) == (if survivor: entity * 2 else: 0xFFFF)

proc main() =
  ## Check counted-loop and banked-call records on original and freshly rebuilt code.
  var cases = 0
  for image in engineImages("bin/action_records_extract"):
    let snes = newSnesBus(image)
    snes.putBytes(NativeTarget, assembleAsm(".a16\n.i16\nINC $1C00\nRTL\n", NativeTarget))
    for state in [0, 3, 69]:
      for cursor in [0x4000, 0xFFFE, 0xFFFF]:
        for depth in [0, 3, 12, 15]:
          for count in 0 .. 255:
            for spill in [0, 0xA5, 0xFF]:
              for fromWork in [false, true]:
                snes.checkLoopRecord(state, depth, cursor, count, spill, fromWork)
                inc cases
          for bank in [0, 0x7E, 0xC4, 0xFF]:
            for adjacent in [0, 0x37, 0xFF]:
              snes.checkFarRecord(state, depth, cursor, 0x5678, bank, adjacent)
              inc cases
      for count in [0, 1, 2, 255]:
        for fromWork in [false, true]:
          snes.checkFiniteLoop(state, count, fromWork)
          inc cases
      for depth in 1 .. 5:
        snes.checkNestedFar(state, depth)
        inc cases
    for entity in [0, 5, 29]:
      for survivor in [false, true]:
        for throughFetch in [false, true]:
          snes.checkEmptyFar(entity, survivor, throughFetch)
          inc cases
  echo &"action records: {cases} original/rebuilt loop, banked-call and detach cases passed"

when isMainModule:
  main()
