import
  std/[sequtils, strformat],
  decompbound/[asm_parse, cpu, snesbus],
  ./engine/[original_cpu, rebuilt_rom]

const
  StreamBank = 0x7F0000'u32
  NativeTarget = 0x7E1D00'u32
  StackGuard = 0x5AA5
  ReturnStub = 0x1C80

proc setup(snes: SnesBus, state, depth = 0, value = 0) =
  ## Install synthetic VM registers with a guarded per-state software stack.
  let offset = state * 2
  snes.putWord(DirectPage.int + 0x80, 0)
  snes.putWord(DirectPage.int + 0x82, 0x7F)
  snes.putWord(DirectPage.int + 0x84, 0x15A2 + offset * 8)
  snes.putWord(DirectPage.int + 0x88, 10)
  snes.putWord(DirectPage.int + 0x8A, offset)
  snes.putWord(0x12E6 + offset, depth)
  snes.putWord(0x1516 + offset, value)
  for index in countup(0, 30, 2):
    snes.putWord(0x15A2 + offset * 8 + index, StackGuard)

proc operand(snes: SnesBus, cursor, value: int) =
  ## Write a word at the exact long-indexed read address, including its bank carry.
  snes.putBytes(StreamBank + cursor.uint32,
    [(value and 255).uint8, ((value shr 8) and 255).uint8])

proc checkJumpsAndStack(snes: SnesBus, state, cursor, target: int) =
  ## Verify near/far jumps, unchecked software pushes, and nonempty returns.
  snes.setup(state)
  snes.operand(cursor, target)
  var result = snes.call("JSR $9649", y = cursor)
  doAssert result.y.int == target and snes.word(DirectPage.int + 0x82) == 0x7F
  for bank in [0, 0x7E, 0xC4, 0xFF]:
    snes.setup(state)
    snes.operand(cursor, target)
    snes.operand((cursor + 2) and 0xFFFF, bank or 0xA500)
    result = snes.call("JSR $964D", y = cursor)
    doAssert result.x.int == target and result.y.int == target
    doAssert snes.word(DirectPage.int + 0x82) == (bank or 0xA500)
  for depth in [0, 2, 14, 16]:
    snes.setup(state, depth)
    snes.operand(cursor, target)
    result = snes.call("JSR $9658", y = cursor)
    let address = 0x15A2 + state * 16 + depth
    doAssert snes.word(address) == ((cursor + 2) and 0xFFFF)
    doAssert snes.word(0x12E6 + state * 2) == depth + 2
    doAssert result.y.int == target
    result = snes.call("JSR $966F", y = 0x4321)
    doAssert result.y.int == ((cursor + 2) and 0xFFFF)
    doAssert snes.word(0x12E6 + state * 2) == depth
    doAssert snes.word(DirectPage.int + 0x82) == 0x7F
    for index in countup(0, 30, 2):
      if index != depth:
        doAssert snes.word(0x15A2 + state * 16 + index) == StackGuard

proc checkBranches(snes: SnesBus, state, value, cursor, target: int) =
  ## Check full-word zero predicates and same-bank cursor replacement.
  for entry in [0x995D, 0x996B]:
    snes.setup(state, value = value)
    snes.operand(cursor, target)
    let
      result = snes.call(&"JSR ${entry:04X}", y = cursor)
      taken = if entry == 0x995D: value == 0 else: value != 0
    doAssert result.y.int == (if taken: target else: (cursor + 2) and 0xFFFF)
    doAssert snes.word(DirectPage.int + 0x82) == 0x7F

proc checkSwitch(snes: SnesBus, state, count, value, cursor, depth: int,
    callVariant: bool) =
  ## Check unsigned table bounds, exact end cursor and optional return-address push.
  snes.setup(state, depth, value)
  snes.putBytes(StreamBank + cursor.uint32, [count.uint8])
  let tableCursor = (cursor + 1) and 0xFFFF
  for index in 0 ..< count:
    snes.operand((tableCursor + index * 2) and 0xFFFF, 0x6000 + index * 7)
  let
    result = snes.call(if callVariant: "JSR $999E" else: "JSR $9979", y = cursor)
    selected = value < count
    endCursor = (tableCursor + count * 2) and 0xFFFF
    pushed = callVariant and selected
  doAssert result.y.int == (if selected: 0x6000 + value * 7 else: endCursor)
  doAssert snes.word(0x12E6 + state * 2) == depth + (if pushed: 2 else: 0)
  for index in countup(0, 30, 2):
    let expected = if pushed and index == depth: endCursor else: StackGuard
    doAssert snes.word(0x15A2 + state * 16 + index) == expected

proc installNative(snes: SnesBus) =
  ## Provide an authored RTL target that returns a value while clobbering X/Y.
  snes.putBytes(NativeTarget, assembleAsm("""
    .a16
    .i16
    EOR #$BEEF
    LDX #$1234
    LDY #$5678
    RTL
  """, NativeTarget))

proc checkNative(snes: SnesBus, state, cursor, value: int) =
  ## Check the real long trampoline, returned state value and word-sized bank overread.
  snes.setup(state, value = value)
  snes.operand(cursor, (NativeTarget and 0xFFFF).int)
  snes.operand((cursor + 2) and 0xFFFF, 0xA57E)
  let result = snes.call("JSR $993D", y = cursor)
  doAssert result.y.int == ((cursor + 3) and 0xFFFF) and result.x.int == state * 2
  doAssert snes.word(0x1516 + state * 2) == (value xor 0xBEEF)
  doAssert snes.word(0x0A5A) == (NativeTarget and 0xFFFF).int
  doAssert snes.word(0x0A5C) == 0xA57E

proc checkNestedScript(snes: SnesBus, state, depth: int) =
  ## Run complete nested calls/native return/unwind to a WAIT through the real fetch loop.
  snes.setup(state, value = 0x1234)
  snes.putWord(0x13FE + state * 2, 0x4000)
  snes.putWord(0x148A + state * 2, 0x7F)
  snes.putWord(0x1372 + state * 2, 0)
  snes.putBytes(StreamBank + 0x4000, [0x1A'u8, 0, 0x41, 6, 2])
  for level in 0 ..< depth:
    let address = 0x4100 + level * 0x10
    if level == depth - 1:
      snes.putBytes(StreamBank + address.uint32,
        [0x42'u8, 0, 0x1D, 0x7E, 0x1B])
    else:
      let target = address + 0x10
      snes.putBytes(StreamBank + address.uint32,
        [0x1A'u8, (target and 255).uint8, (target shr 8).uint8, 0x1B])
  snes.call("JSR $9506")
  doAssert snes.word(0x13FE + state * 2) == 0x4005
  doAssert snes.word(0x1372 + state * 2) == 1
  doAssert snes.word(0x12E6 + state * 2) == 0
  doAssert snes.word(0x1516 + state * 2) == (0x1234 xor 0xBEEF)

proc checkFarReturn(snes: SnesBus, state: int) =
  ## Prove GOSUB saves no bank and far-jump bank overread survives fetch-state saving.
  snes.setup(state)
  snes.putWord(0x13FE + state * 2, 0x4000)
  snes.putWord(0x148A + state * 2, 0x7F)
  snes.putWord(0x1372 + state * 2, 0)
  snes.putBytes(StreamBank + 0x4000, [0x1A'u8, 0, 0x41, 6, 9])
  snes.putBytes(StreamBank + 0x4100, [3'u8, 0, 0x50, 0x7E, 0xA6])
  snes.putBytes(Wram + 0x5000, [0x1B'u8])
  snes.putBytes(Wram + 0x4003, [6'u8, 2])
  snes.call("JSR $9506")
  doAssert snes.word(0x13FE + state * 2) == 0x4005
  doAssert snes.word(0x148A + state * 2) == 0xA67E
  doAssert snes.word(0x1372 + state * 2) == 1
  doAssert snes.word(0x12E6 + state * 2) == 0

proc checkNativeScript(snes: SnesBus, state, opcode: int) =
  ## Run every native-call alias with its actual packed-wait and bank-overread behavior.
  snes.setup(state, value = 0x1234)
  snes.putWord(0x13FE + state * 2, 0x4000)
  snes.putWord(0x148A + state * 2, 0x7F)
  snes.putWord(0x1372 + state * 2, 0)
  snes.putBytes(StreamBank + 0x4000, [opcode.uint8, 0, 0x1D, 0x7E, 6, 2])
  snes.call("JSR $9506")
  let inlineWait = if opcode >= 0x70: opcode and 15 else: 0
  doAssert snes.word(0x13FE + state * 2) == (if inlineWait == 0: 0x4006 else: 0x4004)
  doAssert snes.word(0x1372 + state * 2) == (if inlineWait == 0: 1 else: inlineWait - 1)
  doAssert snes.word(0x1516 + state * 2) == (0x1234 xor 0xBEEF)
  doAssert snes.word(0x0A5C) == 0x067E

proc seedChain(snes: SnesBus, entity, length: int) =
  ## Construct a real active entity with a valid synthetic used/free state partition.
  snes.call("JSL $C09282")
  snes.putWord(0x0A4C, entity)
  snes.putWord(0x0A4E, entity + 1)
  snes.call("JSL $C09321", a = 0)
  snes.putWord(0x0ADA + entity * 2, 0)
  for state in 0 .. 69:
    snes.putWord(0x125A + state * 2,
      if state == length - 1 or state == 69: 0xFFFF else: (state + 1) * 2)
    snes.putWord(0x1372 + state * 2, 2)
  snes.putWord(0x0A54, if length == 70: 0xFFFF else: length * 2)

proc checkDetach(snes: SnesBus, entity, length, selected, cursor: int,
    emptyReturn, throughFetch, savedMatches: bool) =
  ## Verify detach/free-list effects, empty RETURN's zero cursor, and last-state removal.
  snes.seedChain(entity, length)
  let
    offset = selected * 2
    oldFree = snes.word(0x0A54)
    next = if selected == length - 1: 0xFFFF else: offset + 2
    savedNext = if savedMatches: offset else: 0x5AA5
  snes.setup(selected)
  snes.putWord(DirectPage.int + 0x88, entity * 2)
  snes.putWord(0x0A58, savedNext)
  snes.putWord(0x1372 + offset, 0)
  let entry = if emptyReturn: "JSR $966F" else: "JSR $99C3"
  var returnedCursor: int
  if throughFetch:
    snes.putBytes(StreamBank + cursor.uint32, [if emptyReturn: 0x1B'u8 else: 0x0C'u8])
    snes.putWord(0x13FE + offset, cursor)
    snes.putWord(0x148A + offset, 0x7F)
    snes.call("JSR $9506")
    returnedCursor = snes.word(0x13FE + offset)
  else:
    returnedCursor = snes.call(entry, y = cursor).y.int
  let expectedCursor = if length == 1: offset elif emptyReturn: 0 else:
    (cursor + (if throughFetch: 1 else: 0)) and 0xFFFF
  doAssert returnedCursor == expectedCursor
  doAssert snes.word(0x1372 + offset) == (if throughFetch: 0xFFFE else: 0xFFFF)
  doAssert snes.word(0x0A54) == offset and snes.word(0x125A + offset) == oldFree
  if length == 1:
    doAssert snes.word(0x0A50) == 0xFFFF and snes.word(0x0A52) == entity * 2
    doAssert snes.word(0x0A62 + entity * 2) == 0xFFFF
    doAssert snes.word(0x0A58) == 0xFFFF
  else:
    doAssert snes.word(0x0A50) == entity * 2
    doAssert snes.word(0x0ADA + entity * 2) == (if selected == 0: next else: 0)
    if selected > 0:
      doAssert snes.word(0x125A + offset - 2) == next
    doAssert snes.word(0x0A58) == (if savedMatches: next else: savedNext)

proc checkSchedulerDetach(snes: SnesBus, selected: int) =
  ## Verify saved-next repair through the complete scheduler over all 70 state nodes.
  const Entity = 5
  snes.seedChain(Entity, 70)
  snes.putBytes(ReturnStub.uint32, assembleAsm("RTS\n", ReturnStub.uint32))
  snes.putWord(0x0A5E, ReturnStub)
  snes.putWord(0x1372 + selected * 2, 0)
  snes.putWord(0x13FE + selected * 2, 0x4000)
  snes.putWord(0x148A + selected * 2, 0x7F)
  snes.putBytes(StreamBank + 0x4000, [0x0C'u8])
  snes.call("JSL $C09466", directPage = 0x300)
  doAssert snes.word(0x0A60) == 0 and snes.word(0x0A50) == Entity * 2
  doAssert snes.word(0x0A54) == selected * 2
  for state in 0 .. 69:
    doAssert snes.word(0x1372 + state * 2) == (if state == selected: 0xFFFE else: 1)

proc checkHelperEntries(snes: SnesBus, entity, selected: int) =
  ## Check the predecessor and unlink-only entries without accidentally recycling a state.
  snes.seedChain(entity, 70)
  snes.setup(selected)
  let
    offset = selected * 2
    successor = if selected == 69: 0xFFFF else: offset + 2
    predecessor = if selected == 0: 0xFFFF else: offset - 2
    oldFree = snes.word(0x0A54)
    found = snes.call("JSR $9D3E", a = 0xBEEF, x = entity * 2, y = offset,
      status = FlagM or FlagC)
  doAssert found.x.int == predecessor and found.y.int == offset
  doAssert found.a.int == (if selected == 0: 0xBEEF else: offset)
  doAssert (found.p and FlagM) == 0
  doAssert snes.word(DirectPage.int - 2) == offset
  doAssert snes.word(0x0ADA + entity * 2) == 0 and snes.word(0x0A54) == oldFree
  snes.putWord(0x0A58, offset)
  let unlinked = snes.call("JSR $9D1F", x = entity * 2, y = offset)
  doAssert unlinked.x.int == entity * 2 and unlinked.y.int == offset
  doAssert unlinked.a.int == successor and snes.word(0x0A58) == successor
  doAssert snes.word(0x0A54) == oldFree and snes.word(0x125A + offset) == successor
  doAssert snes.word(0x0ADA + entity * 2) == (if selected == 0: successor else: 0)
  if selected > 0:
    doAssert snes.word(0x125A + predecessor) == successor

proc main() =
  ## Check control-flow contracts against original and rebuilt ROMs with synthetic scripts only.
  var cases = 0
  for image in engineImages("bin/action_control_extract"):
    let snes = newSnesBus(image)
    snes.installNative()
    for state in [0, 3, 69]:
      for cursor in [0x4000, 0xFFFE, 0xFFFF]:
        for target in [0, 0x1234, 0xFFFF]:
          snes.checkJumpsAndStack(state, cursor, target)
          inc cases
        for value in [0, 1, 0x7FFF, 0x8000, 0xFFFF]:
          snes.checkBranches(state, value, cursor, 0x5678)
          snes.checkNative(state, cursor, value)
          cases += 2
      for depth in 1 .. 8:
        snes.checkNestedScript(state, depth)
        inc cases
      snes.checkFarReturn(state)
      inc cases
      for opcode in @[0x42, 0x4C] & toSeq(0x70 .. 0x7F) & toSeq(0xF0 .. 0xFF):
        snes.checkNativeScript(state, opcode)
        inc cases
      for count in 0 .. 255:
        for value in [0, 1, max(count - 1, 0), count, count + 1, 255, 256, 0xFFFF]:
          for cursor in [0x4000, 0xFFFF]:
            for depth in [0, 14]:
              for callVariant in [false, true]:
                snes.checkSwitch(state, count, value, cursor, depth, callVariant)
                inc cases
    for entity in [0, 5, 29]:
      for selected in 0 .. 69:
        snes.checkHelperEntries(entity, selected)
        cases += 2
      for length in [1, 2, 3, 70]:
        for selected in [0, length div 2, length - 1].deduplicate():
          for emptyReturn in [false, true]:
            for throughFetch in [false, true]:
              for savedMatches in [false, true]:
                snes.checkDetach(entity, length, selected, 0x4000,
                  emptyReturn, throughFetch, savedMatches)
                inc cases
    for selected in [0, 2, 69]:
      snes.checkSchedulerDetach(selected)
      inc cases
  echo &"action control: {cases} original/rebuilt flow, stack, native-call and state-removal cases passed"

when isMainModule:
  main()
