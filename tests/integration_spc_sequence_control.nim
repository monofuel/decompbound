## Execute original and rebuilt sequence control against authored streams only.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  DispatchEntry = 0x0943'u16
  ByteEntry = 0x0882'u16
  ByteExit = 0x089E'u16
  WordEntry = 0x081A'u16
  WordExit = 0x0841'u16
  ZeroExit = 0x07EA'u16
  Guard = 0xA5'u8
  Counts = [0, 1, 2, 127, 255]
  StreamEdges = [0x4800, 0x48FF, 0xFFFE, 0xFFFF]
  TargetEdges = [0, 0x5000, 0x50FF, 0xFFFF]
  WordValues = [0, 1, 127, 128, 129, 255, 256, 0x80FF, 0xFFFF]

type Totals = object
  efCalls, byteCalls, dispatchCalls, wordFetchCalls, wordControlCalls: int
  replayContexts, nestedContexts: int

proc word(spc: Spc, address: int): int =
  ## Read a synthetic word with sixteen-bit address wrap.
  spc.ram[address and 65535].int or
    (spc.ram[(address + 1) and 65535].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Write authored little-endian state with address wrap.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address + 1) and 65535] = ((value shr 8) and 255).uint8

proc bytes(spc: var Spc, address: int, values: openArray[int]) =
  ## Install a tiny authored stream without extracted game data.
  for i, value in values:
    spc.ram[(address + i) and 65535] = value.uint8

proc stack(spc: var Spc) =
  ## Supply the caller's return and guards outside all expected native frames.
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E8] = Guard
  spc.ram[0x1F2] = Guard
  spc.sp = 0xEF

proc run(spc: var Spc, entry: uint16, stops: openArray[uint16], budget: int) =
  ## Run unmodified instructions with bounded stack use and no port accesses.
  var
    instructions = 0
    reads = 0
    writes = 0
  spc.readHook = proc(address: uint16): int =
    inc reads
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    inc writes
    false
  spc.pc = entry
  while spc.pc notin stops:
    doAssert instructions < budget, &"sequence control ${entry:04X} at ${spc.pc:04X}"
    doAssert spc.sp in 0xE9'u8 .. 0xF1'u8
    spc.step()
    inc instructions
  doAssert reads == 0 and writes == 0, "sequence control must not access I/O"
  doAssert not spc.stopped
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E8] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil

proc callEf(spc: var Spc, channel: int, totals: var Totals) =
  ## Enter EF through the original dispatcher and verify native stack balance.
  spc.stack()
  spc.x = channel.uint8
  spc.a = 0xEF
  spc.psw = PswH or PswV or PswI or PswB or PswC
  spc.run(DispatchEntry, [ReturnAddress], 60)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert (spc.psw and (PswH or PswV or PswI or PswB or PswP or PswC)) ==
    (PswH or PswV or PswI or PswB)
  inc totals.efCalls

proc checkEf(spc: var Spc, totals: var Totals) =
  ## Check all channel slots, wrapped operand cursors, counters and neighboring frames.
  for channel in countup(0, 14, 2):
    for stream in StreamEdges:
      for target in TargetEdges:
        for count in Counts:
          for i in 0 ..< 16:
            spc.ram[0x30 + i] = Guard
            spc.ram[0x80 + i] = Guard
            spc.ram[0x230 + i] = Guard
            spc.ram[0x240 + i] = Guard
          spc.bytes(stream, [target and 255, target shr 8, count])
          spc.putWord(0x30 + channel, stream)
          spc.callEf(channel, totals)
          doAssert spc.word(0x30 + channel) == target
          doAssert spc.word(0x240 + channel) == target
          doAssert spc.word(0x230 + channel) == ((stream + 3) and 65535)
          doAssert spc.ram[0x80 + channel].int == count
          doAssert spc.a.int == (target shr 8) and spc.y.int == count
          doAssert ((spc.psw and PswZ) != 0) == ((target shr 8) == 0)
          doAssert ((spc.psw and PswN) != 0) == (target >= 0x8000)
          for i in 0 ..< 16:
            if i notin [channel, channel + 1]:
              doAssert spc.ram[0x30 + i] == Guard
              doAssert spc.ram[0x230 + i] == Guard and spc.ram[0x240 + i] == Guard
            if i != channel: doAssert spc.ram[0x80 + i] == Guard

proc fetchByte(spc: var Spc, channel: int, totals: var Totals) =
  ## Stop the byte consumer before event handling or broader global processing.
  spc.x = channel.uint8
  spc.run(ByteEntry, [ByteExit, WordEntry], 7000)
  doAssert spc.sp == 0xEF and spc.x.int == channel
  inc totals.byteCalls

proc checkZero(spc: var Spc, totals: var Totals) =
  ## Distinguish empty count, final continuation and target reload at zero events.
  for channel in countup(0, 14, 2):
    for count in Counts:
      for targetStartsZero in [false, true]:
        spc.putWord(0x30 + channel, 0x6000)
        spc.putWord(0x240 + channel, 0x5000)
        spc.putWord(0x230 + channel, 0x7000)
        spc.ram[0x80 + channel] = count.uint8
        spc.bytes(0x6000, [0, 0xA4])
        spc.bytes(0x5000, [if targetStartsZero: 0 else: 0xB4, 0xC5])
        spc.bytes(0x7000, [0xC4])
        spc.stack()
        spc.psw = PswH or PswV or PswI or PswB or PswC
        spc.fetchByte(channel, totals)
        if count == 0:
          doAssert spc.pc == WordEntry and spc.word(0x30 + channel) == 0x6001
          doAssert spc.ram[0x80 + channel] == 0 and spc.a == 0 and spc.y == 0
        elif count == 1 or targetStartsZero:
          doAssert spc.pc == ByteExit and spc.a == 0xC4 and spc.y == 0xC4
          doAssert spc.word(0x30 + channel) == 0x7001 and spc.ram[0x80 + channel] == 0
        else:
          doAssert spc.pc == ByteExit and spc.a == 0xB4 and spc.y == 0xB4
          doAssert spc.word(0x30 + channel) == 0x5001
          doAssert spc.ram[0x80 + channel].int == count - 1
        doAssert spc.word(0x240 + channel) == 0x5000
        doAssert spc.word(0x230 + channel) == 0x7000
        doAssert (spc.psw and (PswH or PswV or PswI or PswB or PswC)) ==
          (PswH or PswV or PswI or PswB or PswC)

proc checkReplays(spc: var Spc, totals: var Totals) =
  ## Replay a real E7 command plus event through original fetch and dispatch paths.
  for channel in countup(0, 14, 2):
    for count in [0, 1, 2, 3, 255]:
      spc.putWord(0x30 + channel, 0x4800)
      spc.bytes(0x4800, [0, 0x50, count, 0xB4])
      spc.bytes(0x5000, [0xE7, 0x37, 0xA4, 0])
      spc.callEf(channel, totals)
      spc.stack()
      var
        commands = 0
        events = 0
      while true:
        doAssert commands <= 255 and events <= 255
        spc.fetchByte(channel, totals)
        if spc.pc == WordEntry: break
        if spc.a == 0xB4: break
        if spc.a == 0xE7:
          # Continue the actual BMI/CMP/CALL/BRA command path back to byte fetch.
          spc.run(ByteExit, [ByteEntry], 40)
          doAssert spc.sp == 0xEF and spc.x.int == channel
          doAssert spc.word(0x52) == 0x3700
          inc commands
          inc totals.dispatchCalls
        else:
          doAssert spc.a == 0xA4 and spc.y == 0xA4
          inc events
      let traversals = if count == 0: 1 else: count
      doAssert commands == traversals and events == traversals
      doAssert spc.ram[0x80 + channel] == 0
      if count == 0:
        doAssert spc.pc == WordEntry and spc.word(0x30 + channel) == 0x5004
      else:
        doAssert spc.pc == ByteExit and spc.a == 0xB4
        doAssert spc.word(0x30 + channel) == 0x4804
      inc totals.replayContexts

proc checkNested(spc: var Spc, totals: var Totals) =
  ## Prove a second EF overwrites the sole target/count/continuation frame.
  for channel in countup(0, 14, 2):
    for outerCount in [1, 2, 255]:
      spc.putWord(0x30 + channel, 0x4800)
      spc.bytes(0x4800, [0, 0x50, outerCount, 0xC4])
      spc.bytes(0x5000, [0xEF, 0, 0x51, 1, 0xB4])
      spc.bytes(0x5100, [0])
      spc.callEf(channel, totals)
      spc.stack()
      spc.fetchByte(channel, totals)
      doAssert spc.pc == ByteExit and spc.a == 0xEF and spc.y == 0xEF
      doAssert spc.word(0x30 + channel) == 0x5001
      spc.run(ByteExit, [ByteEntry], 70)
      doAssert spc.sp == 0xEF and spc.x.int == channel
      inc totals.efCalls
      inc totals.dispatchCalls
      doAssert spc.word(0x30 + channel) == 0x5100
      doAssert spc.word(0x240 + channel) == 0x5100
      doAssert spc.word(0x230 + channel) == 0x5004
      doAssert spc.ram[0x80 + channel] == 1
      spc.fetchByte(channel, totals)
      doAssert spc.pc == ByteExit and spc.a == 0xB4
      doAssert spc.word(0x30 + channel) == 0x5005 and spc.ram[0x80 + channel] == 0
      inc totals.nestedContexts

proc checkWordFetch(spc: var Spc, totals: var Totals) =
  ## Verify low/high return bytes, high-byte flags, both pages and cursor wrap.
  for page in [0, 256]:
    for stream in StreamEdges:
      for value in WordValues:
        for status in [0, 1, 0x5C, 0x5D]:
          for channel in countup(0, 14, 2):
            spc.putWord(stream, value)
            spc.putWord(page + 0x40, stream)
            spc.ram[page + 0x42] = Guard
            spc.ram[page + 0x3F] = Guard
            spc.stack()
            spc.x = channel.uint8
            spc.y = 0xA6
            spc.psw = status.uint8 or
              (if page == 0: 0'u8 else: PswP)
            let preserved = spc.psw and not (PswN or PswZ)
            spc.run(0x0750, [ReturnAddress], 15)
            doAssert spc.a.int == (value and 255) and spc.y.int == (value shr 8)
            doAssert spc.word(page + 0x40) == ((stream + 2) and 65535)
            doAssert spc.ram[page + 0x42] == Guard and spc.ram[page + 0x3F] == Guard
            doAssert spc.x.int == channel and spc.sp == 0xF1
            doAssert (spc.psw and not (PswN or PswZ)) == preserved
            doAssert ((spc.psw and PswZ) != 0) == ((value shr 8) == 0)
            doAssert ((spc.psw and PswN) != 0) == (value >= 0x8000)
            inc totals.wordFetchCalls

proc control(spc: var Spc, page, start, counter, mode, expectedPointer,
    expectedCounter, expectedMode, expectedX, expectedWord, expectedCarry: int,
    expectedExit: uint16, totals: var Totals, budget = 150) =
  ## Check one independently specified global-control outcome and preserved neighbors.
  spc.putWord(page + 0x40, start)
  spc.ram[page + 0x42] = counter.uint8
  spc.ram[page + 0x43] = Guard
  spc.ram[page + 0x1B] = mode.uint8
  spc.stack()
  spc.x = 0xC3
  spc.psw = PswH or PswV or PswI or PswB or PswC or
    (if page == 0: 0'u8 else: PswP)
  spc.run(WordEntry, [WordExit, ZeroExit], budget)
  doAssert spc.pc == expectedExit
  doAssert spc.word(page + 0x40) == expectedPointer
  doAssert spc.ram[page + 0x42].int == expectedCounter
  doAssert spc.ram[page + 0x1B].int == expectedMode
  doAssert spc.ram[page + 0x43] == Guard and spc.sp == 0xEF
  doAssert spc.x.int == expectedX
  doAssert spc.a.int == (expectedWord and 255)
  doAssert spc.y.int == (expectedWord shr 8)
  doAssert (spc.psw and PswC).int == expectedCarry
  doAssert ((spc.psw and PswZ) != 0) == (expectedWord == 0)
  doAssert ((spc.psw and PswN) != 0) == (expectedWord >= 0x8000)
  doAssert (spc.psw and (PswH or PswV or PswI or PswB or PswP)) ==
    (PswH or PswV or PswI or PswB or (if page == 0: 0'u8 else: PswP))
  inc totals.wordControlCalls

proc checkControls(spc: var Spc, totals: var Totals) =
  ## Exercise full-word exits, mode tokens, signed counter reloads and actual loops.
  for page in [0, 256]:
    for start in [0x5000, 0xFFFE, 0xFFFF]:
      for terminal in [0, 0x0100, 0x7FFF, 0x8000, 0xFFFF]:
        spc.putWord(start, terminal)
        spc.control(page, start, 0x35, 0x56, (start + 2) and 65535,
          0x35, 0x56, 0xC3, terminal, 1,
          (if terminal == 0: ZeroExit else: WordExit), totals)
      for lastMode in [0, 0x80]:
        spc.putWord(start, if lastMode == 0: 0x80 else: 0x81)
        spc.putWord(start + 2, if lastMode == 0: 0x81 else: 0x80)
        spc.putWord(start + 4, 0xAB34)
        spc.control(page, start, 0x35, 0x56, (start + 6) and 65535,
          0x35, lastMode, 0xC3, 0xAB34, 1, WordExit, totals)
    for token in 1 .. 255:
      if token in [128, 129]: continue
      for counter in 0 .. 255:
        spc.putWord(0x5000, token)
        spc.putWord(0x5002, 0x6000)
        spc.putWord(0x5004, 0x1234)
        spc.putWord(0x6000, 0xABCD)
        let
          decremented = (counter - 1) and 255
          remaining = if decremented >= 128: token else: decremented
          jumped = remaining != 0
        spc.control(page, 0x5000, counter, 0x56,
          (if jumped: 0x6002 else: 0x5006), remaining, 0x56, remaining,
          (if jumped: 0xABCD else: 0x1234), (if token >= 129: 1 else: 0),
          WordExit, totals)
    for count in [1, 2, 3, 127]:
      spc.putWord(0x5000, count)
      spc.putWord(0x5002, 0x5000)
      spc.putWord(0x5004, 0xABCD)
      spc.control(page, 0x5000, 0, 0x56, 0x5006, 0, 0x56, 0,
        0xABCD, 0, WordExit, totals, 6000)

proc main() =
  ## Exercise both the user's original driver and a fresh byte-identical rebuild.
  var totals: Totals
  for image in engineImages("bin/spc_sequence_control_extract"):
    var spc = newSpc()
    for i in 0 ..< DriverLength: spc.ram[DriverStart + i] = image[DriverPayload + i]
    spc.checkEf(totals)
    spc.checkZero(totals)
    spc.checkReplays(totals)
    spc.checkNested(totals)
    spc.checkWordFetch(totals)
    spc.checkControls(totals)
  echo &"SPC sequence control passed: {totals.efCalls} EF dispatch calls, " &
    &"{totals.byteCalls} byte-consumer entries, {totals.dispatchCalls} replay command " &
    &"dispatches, {totals.wordFetchCalls} direct word-fetch calls, " &
    &"{totals.wordControlCalls} global-control entries; " &
    &"{totals.replayContexts} replay and {totals.nestedContexts} nested contexts."

when isMainModule:
  main()
