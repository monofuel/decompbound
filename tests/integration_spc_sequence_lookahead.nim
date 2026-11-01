## Model speculative sequence scanning independently of the live sequence interpreter.
import
  std/[sets, strformat],
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  Decision = enum keepVoice, releaseVoice, repeatedState
  ScanState = tuple[base, index, remaining: int]
  Prediction = object
    decision: Decision
    scanned: bool
    gate, base, index, remaining: int
  PortWrite = tuple[address: uint16, value: uint8]
  Totals = object
    finite, cycles: int

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  Entry = 0x0CF7'u16
  Exit = 0x0D60'u16
  ReadEntry = 0x0D10'u16
  ReturnAddress = 0x1E00'u16
  Cursor = 0x4200
  RepeatTarget = 0x4400
  Continuation = 0x4500
  CallTarget = 0x4600
  Guard = 0xA5'u8
  GateEdges = [0, 1, 2, 3, 127, 128, 255]
  Masks = [0, 1, 0x55, 0x80, 0xFF]

proc word(spc: Spc, address: int): int =
  ## Read a structural word with sixteen-bit address wrap.
  spc.ram[address and 65535].int + spc.ram[(address + 1) and 65535].int * 256

proc putWord(spc: var Spc, address, value: int) =
  ## Install a synthetic structural word without CPU arithmetic.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address + 1) and 65535] = ((value shr 8) and 255).uint8

proc stream(spc: var Spc, address: int, bytes: openArray[int]) =
  ## Install a tiny authored stream with ordinary sixteen-bit address wrap.
  for index, value in bytes:
    spc.ram[(address + index) and 65535] = value.uint8

proc prepare(spc: var Spc, metadata: seq[uint8], channel, gate, countdown,
    remaining, mask, inhibit: int, cursor = Cursor) =
  ## Guard live fields and provide disjoint authored scan/return/target streams.
  for address in 0 .. 0xEF: spc.ram[address] = Guard
  for address in 0x200 .. 0x4BF: spc.ram[address] = Guard
  for address in Cursor .. Cursor + 255: spc.ram[address] = 0x80
  for index, value in metadata: spc.ram[0x0C21 + index] = value
  spc.stream(RepeatTarget, [0xC8])
  spc.stream(Continuation, [0xC9])
  spc.stream(CallTarget, [0xC8])
  spc.stream(0x8080, [0xC8])
  spc.putWord(0x30 + channel, cursor)
  spc.putWord(0x230 + channel, Continuation)
  spc.putWord(0x240 + channel, RepeatTarget)
  spc.ram[0x70 + channel] = countdown.uint8
  spc.ram[0x71 + channel] = gate.uint8
  spc.ram[0x80 + channel] = remaining.uint8
  spc.ram[0x47] = mask.uint8
  spc.ram[0x1A] = inhibit.uint8
  spc.putWord(0x14, 0x6AC3)
  spc.ram[0x17] = 0x5A
  spc.iplEnabled = false

proc predict(spc: Spc, channel: int): Prediction =
  ## Specify a finite-state scanner, including eight-bit offsets and unchanged live call slots.
  result.gate = spc.ram[0x71 + channel].int
  result.base = spc.word(0x14)
  result.remaining = spc.ram[0x17].int
  if result.gate == 0: return
  dec result.gate
  if result.gate != 0 and spc.ram[0x70 + channel] != 2: return
  result.scanned = true
  result.base = spc.word(0x30 + channel)
  result.remaining = spc.ram[0x80 + channel].int
  var visited: HashSet[ScanState]
  while true:
    let state = (result.base, result.index, result.remaining)
    if state in visited:
      result.decision = repeatedState
      return
    doAssert visited.len < 4096, "fixture exceeds the modeled scan-state budget"
    visited.incl state
    var token = spc.ram[(result.base + result.index) and 65535].int
    if token == 0:
      if result.remaining == 0:
        result.decision = releaseVoice
        return
      dec result.remaining
      result.base = spc.word((if result.remaining == 0: 0x230 else: 0x240) + channel)
      result.index = 0
      continue
    while token < 128:
      result.index = (result.index + 1) and 255
      if (result.index and 128) != 0:
        result.decision = releaseVoice
        return
      token = spc.ram[(result.base + result.index) and 65535].int
    if token == 0xC8: return
    if token == 0xEF:
      let
        low = spc.ram[(result.base + ((result.index + 1) and 255)) and 65535].int
        high = spc.ram[(result.base + ((result.index + 2) and 255)) and 65535].int
      result.base = low + high * 256
      result.index = 0
    elif token < 0xE0:
      result.decision = releaseVoice
      return
    else:
      let width = spc.ram[0x0B41 + token].int
      result.index = (result.index + 1 + width) and 255

proc check(spc: var Spc, channel: int, totals: var Totals) =
  ## Compare scan decisions, speculative state, live-field isolation and exact KOFF writes.
  let
    expected = spc.predict(channel)
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[0x200 .. 0x4BF]
    beforeMetadata = spc.ram[0x0C21 .. 0x0C40]
    beforeStream = spc.ram[Cursor .. Cursor + 255]
    initialStatus = PswI or PswB or PswH or PswV or PswC
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1EC] = Guard
  spc.ram[0x1F2] = Guard
  spc.pc = Entry
  spc.sp = 0xEF
  spc.x = channel.uint8
  spc.y = 0xC3
  spc.psw = initialStatus
  var
    writes: seq[PortWrite]
    reads, instructions: int
    visited: HashSet[ScanState]
    cycled = false
  spc.readHook = proc(address: uint16): int =
    inc reads
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    writes.add (address, value)
    false
  while spc.pc != Exit:
    doAssert instructions < 20000, &"lookahead fixture exceeded budget at ${spc.pc:04X}"
    doAssert spc.sp in 0xEC'u8 .. 0xEF'u8
    if spc.pc == ReadEntry:
      let state = (spc.word(0x14), spc.y.int, spc.ram[0x17].int)
      if state in visited:
        cycled = true
        break
      visited.incl state
    spc.step()
    inc instructions
  doAssert cycled == (expected.decision == repeatedState)
  doAssert not spc.stopped and reads == 0
  doAssert spc.sp == 0xEF and spc.x.int == channel
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  doAssert spc.ram[0x71 + channel].int == expected.gate
  doAssert spc.word(0x14) == expected.base
  doAssert spc.ram[0x17].int == expected.remaining
  let released = expected.decision == releaseVoice
  let emitted = released and (beforeDp[0x47] and beforeDp[0x1A]) == 0
  if emitted:
    doAssert writes == @[(0xF2'u16, 0x5C'u8), (0xF3'u16, beforeDp[0x47])]
  else: doAssert writes.len == 0
  if released:
    doAssert spc.a == beforeDp[0x47] and spc.y == 0x5C
    doAssert ((spc.psw and PswZ) != 0) == ((beforeDp[0x47] and beforeDp[0x1A]) == 0)
    doAssert ((spc.psw and PswN) != 0) == ((beforeDp[0x47] and beforeDp[0x1A]) >= 128)
  elif not cycled:
    if expected.scanned:
      doAssert spc.a == 0xC8 and spc.y.int == expected.index
      doAssert (spc.psw and (PswC or PswN or PswZ)) == (PswC or PswZ)
    else:
      doAssert spc.a.int == (if beforeDp[0x71 + channel] == 0: 0 else: 2)
      doAssert spc.y == 0xC3
      doAssert (spc.psw and (PswC or PswH or PswV)) ==
        (initialStatus and (PswC or PswH or PswV))
  for address in 0 .. 0xEF:
    if address notin [0x71 + channel, 0x14, 0x15, 0x17]:
      doAssert spc.ram[address] == beforeDp[address], &"lookahead changed DP ${address:02X}"
  doAssert spc.ram[0x200 .. 0x4BF] == beforeArrays
  doAssert spc.ram[0x0C21 .. 0x0C40] == beforeMetadata
  doAssert spc.ram[Cursor .. Cursor + 255] == beforeStream
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1EC] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil
  if cycled: inc totals.cycles
  else: inc totals.finite

proc matrices(spc: var Spc, metadata: seq[uint8], totals: var Totals) =
  ## Cover gates, every byte classification, metadata offsets and speculative repeat/call paths.
  for gate in 0 .. 255:
    for countdown in [0, 1, 2, 3, 255]:
      for token in [0, 0x80, 0xC8, 0xC9, 0xE0, 0xFF]:
        for mask in Masks:
          for inhibit in [0, 255]:
            let channel = ((gate + countdown + token) and 7) * 2
            spc.prepare(metadata, channel, gate, countdown, gate, mask, inhibit)
            spc.ram[Cursor] = token.uint8
            spc.check(channel, totals)
  for token in 0 .. 255:
    for channel in countup(0, 14, 2):
      spc.prepare(metadata, channel, 1, 9, 2, 1 shl (channel div 2), 0)
      spc.ram[Cursor] = token.uint8
      spc.check(channel, totals)
  for count in 0 .. 128:
    for terminal in [0x80, 0xC8, 0xC9]:
      spc.prepare(metadata, 6, 1, 9, 255, 8, 0)
      for index in 0 ..< count:
        spc.ram[Cursor + index] = (if index > 0 and index mod 3 == 0: 0 else: 1)
      spc.ram[Cursor + count] = terminal.uint8
      spc.check(6, totals)
  for command in 0xE0 .. 0xFE:
    if command == 0xEF: continue
    for width in [0, 1, 2, 3, 126, 127, 128, 244, 254, 255]:
      for offset in [0, 1, 63, 126]:
        let channel = ((command + width + offset) and 7) * 2
        spc.prepare(metadata, channel, 1, 9, 255, 1 shl (channel div 2), 0)
        spc.ram[0x0B41 + command] = width.uint8
        for index in 0 ..< offset: spc.ram[Cursor + index] = 1
        spc.ram[Cursor + offset] = command.uint8
        let destination = (offset + 1 + width) and 255
        if destination > offset: spc.ram[Cursor + destination] = 0xC8
        spc.check(channel, totals)
  for remaining in 0 .. 255:
    spc.prepare(metadata, 10, 1, 9, remaining, 32, 0)
    spc.stream(Cursor, [0])
    spc.stream(RepeatTarget, [0])
    spc.stream(Continuation, [0xC8])
    spc.check(10, totals)
    for callCount in [0, 1, 2, 255]:
      spc.prepare(metadata, 10, 1, 9, remaining, 32, 0)
      spc.stream(Cursor, [0xEF, CallTarget and 255, CallTarget shr 8, callCount, 0xC9])
      spc.stream(CallTarget, [0xEF, 0, 0x47, 255 - callCount, 0xC9])
      spc.stream(0x4700, [0])
      spc.stream(RepeatTarget, [0xC9])
      spc.stream(Continuation, [0xC8])
      spc.check(10, totals)
  for cursor in [0x40FF, 0xFFFE, 0xFFFF]:
    for token in [0x80, 0xC8, 0xC9, 0xEF]:
      spc.prepare(metadata, 12, 1, 9, 1, 64, 0, cursor)
      spc.stream(cursor, [token, CallTarget and 255, CallTarget shr 8, 255])
      spc.check(12, totals)
  for offset in [254, 255]:
    spc.prepare(metadata, 4, 1, 9, 255, 4, 0)
    spc.ram[Cursor] = 0xE0
    spc.ram[0x0C21] = (offset - 1).uint8
    spc.ram[Cursor + offset] = 0xEF
    if offset == 254:
      spc.ram[Cursor + 255] = 0x80
      spc.stream(0xE080, [0xC8])
    else:
      spc.ram[Cursor + 1] = 0x50
      spc.stream(0x50E0, [0xC8])
    spc.check(4, totals)
  spc.prepare(metadata, 0, 1, 9, 0, 1, 0)
  spc.stream(Cursor, [0xFF])
  spc.ram[Cursor + 245] = 1
  spc.ram[Cursor + 246] = 0xC8
  doAssert spc.predict(0).decision == releaseVoice
  spc.check(0, totals)
  # Four explicit cycles include unchanged original metadata and prefix index wrap.
  spc.prepare(metadata, 0, 1, 9, 0, 1, 0)
  spc.stream(Cursor, [0xEF, Cursor and 255, Cursor shr 8, 0])
  doAssert spc.predict(0).decision == repeatedState
  spc.check(0, totals)
  spc.prepare(metadata, 0, 1, 9, 0, 1, 0)
  spc.ram[Cursor] = 0xE4
  spc.ram[0x0B41 + 0xE4] = 254
  spc.ram[Cursor + 255] = 1
  doAssert spc.predict(0).decision == repeatedState
  spc.check(0, totals)
  spc.prepare(metadata, 0, 1, 9, 0, 1, 0)
  spc.stream(Cursor, [0xE0])
  spc.ram[0x0C21] = 255
  doAssert spc.predict(0).decision == repeatedState
  spc.check(0, totals)
  spc.prepare(metadata, 0, 1, 9, 0, 1, 0)
  doAssert spc.ram[0x0B41 + 0xE4] == 0
  for index in 0 .. 255: spc.ram[Cursor + index] = 0xE4
  spc.ram[Cursor + 256] = 0xC8
  doAssert spc.predict(0).decision == repeatedState
  spc.check(0, totals)

proc main() =
  ## Execute independent speculative-scan checks on original and freshly rebuilt driver images.
  var totals: Totals
  for image in engineImages("bin/spc_sequence_lookahead_extract"):
    var spc = newSpc()
    for index in 0 ..< DriverLength: spc.ram[DriverStart + index] = image[DriverPayload + index]
    let metadata = spc.ram[0x0C21 .. 0x0C3F]
    doAssert spc.ram[0x0C40] == 0xF4
    spc.matrices(metadata, totals)
  echo &"SPC lookahead passed: {totals.finite} finite scans/gates and {totals.cycles} repeated scan states across original/rebuilt images."

when isMainModule:
  main()
