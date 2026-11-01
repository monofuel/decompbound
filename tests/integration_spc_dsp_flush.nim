## Independently specify ordered DSP publication, queue cleanup and feedback/settle state.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  PortWrite = tuple[address: uint16, value: uint8]
  Totals = object
    flushes, suppressed, directSkips, advances, chains: int

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  FlushEntry = 0x0546'u16
  SkipEntry = 0x0543'u16
  FlushExit = 0x0579'u16
  SkipExit = 0x05D8'u16
  AdvanceEntry = 0x05C6'u16
  AdvanceExit = 0x05CD'u16
  ReturnAddress = 0x1E00
  DspAddress = 0xF2'u16
  DspData = 0xF3'u16
  RegKeyOff = 0x5C'u8
  RegPitchModulation = 0x2D'u8
  RegNoise = 0x3D'u8
  RegKeyOn = 0x4C'u8
  RegFlags = 0x6C'u8
  RegEchoEnable = 0x4D'u8
  RegEchoFeedback = 0x0D'u8
  RegEchoRight = 0x3C'u8
  RegEchoLeft = 0x2C'u8
  ZeroWord = 0x0E
  FeedbackHigh = 0x18
  FeedbackLow = 0x19
  Mode = 0x1B
  QueuedOn = 0x45
  QueuedOff = 0x46
  Flags = 0x48
  Noise = 0x49
  EchoEnable = 0x4A
  PitchModulation = 0x4B
  Settle = 0x4C
  RequestedDelay = 0x4D
  EchoFeedback = 0x4E
  EchoLeft = 0x61
  EchoRight = 0x63
  Edges = [0, 1, 127, 128, 255]

proc word(spc: Spc, address: int): int =
  ## Read a synthetic little-endian word.
  spc.ram[address].int + spc.ram[address + 1].int * 256

proc prepare(spc: var Spc, settle, requested, feedback, seed, mode: int) =
  ## Distinguish every published field and guard all unrelated low RAM and stack bytes.
  for address in 0 .. 0x2FF:
    spc.ram[address] = ((address * 37 + seed * 19) and 255).uint8
  spc.ram[0x1F0] = (ReturnAddress and 255).uint8
  spc.ram[0x1F1] = (ReturnAddress shr 8).uint8
  spc.ram[ZeroWord] = 0
  spc.ram[ZeroWord + 1] = 0
  spc.ram[FeedbackHigh] = (feedback shr 8).uint8
  spc.ram[FeedbackLow] = (feedback and 255).uint8
  spc.ram[Mode] = mode.uint8
  spc.ram[QueuedOn] = ((seed * 37 + 11) and 255).uint8
  spc.ram[QueuedOff] = ((seed * 73 + 29) and 255).uint8
  spc.ram[Flags] = ((seed * 19 + 5) and 255).uint8
  spc.ram[Noise] = (seed xor 0xA5).uint8
  spc.ram[EchoEnable] = (seed xor 0x80).uint8
  spc.ram[PitchModulation] = (seed xor 0x5A).uint8
  spc.ram[Settle] = settle.uint8
  spc.ram[RequestedDelay] = requested.uint8
  spc.ram[EchoFeedback] = (seed xor 0x36).uint8
  spc.ram[EchoLeft] = ((seed * 43 + 7) and 255).uint8
  spc.ram[EchoRight] = ((seed * 61 + 3) and 255).uint8
  spc.sp = 0xEF
  spc.iplEnabled = false

proc execute(spc: var Spc, entry, stop: uint16, budget: int): seq[PortWrite] =
  ## Run untouched code with no hardware reads or physical audio device.
  var writes: seq[PortWrite]
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected hardware read ${address:04X}"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    writes.add (address, value)
    false
  spc.pc = entry
  var instructions = 0
  while spc.pc != stop:
    doAssert instructions < budget, &"DSP entry ${entry:04X} stalled at ${spc.pc:04X}"
    doAssert spc.sp == 0xEF
    spc.step()
    inc instructions
  doAssert not spc.stopped and spc.sp == 0xEF
  doAssert spc.word(0x1F0) == ReturnAddress
  spc.readHook = nil
  spc.writeHook = nil
  result = writes

proc appendWrite(writes: var seq[PortWrite], register, value: uint8) =
  ## Express a hardware transaction using named register roles rather than a copied ROM table.
  writes.add (DspAddress, register)
  writes.add (DspData, value)

proc expectedWrites(before: seq[uint8]): seq[PortWrite] =
  ## Specify publication order and gates without decoding the driver's descriptor arrays.
  result.appendWrite(RegKeyOff, before[QueuedOff])
  result.appendWrite(RegPitchModulation, before[PitchModulation])
  result.appendWrite(RegNoise, before[Noise])
  result.appendWrite(RegKeyOff, before[ZeroWord])
  result.appendWrite(RegKeyOn, before[QueuedOn])
  if (before[Settle] and 128) == 0:
    result.appendWrite(RegFlags, before[Flags])
    if before[Settle] == before[RequestedDelay]:
      result.appendWrite(RegEchoEnable, before[EchoEnable])
      result.appendWrite(RegEchoFeedback, before[EchoFeedback])
      result.appendWrite(RegEchoRight, before[EchoRight])
      result.appendWrite(RegEchoLeft, before[EchoLeft])

proc checkFlush(spc: var Spc, status: uint8, totals: var Totals) =
  ## Compare complete publication/cleanup and a mathematical feedback recurrence.
  let
    before = spc.ram[0 .. 0xEF]
    beforeStack = spc.ram[0x100 .. 0x1FF]
    beforeArrays = spc.ram[0x200 .. 0x2FF]
    active = before[Mode] == 0
    oldState = before[FeedbackHigh].int * 256 + before[FeedbackLow].int
    injectedBit = 1 xor (((before[FeedbackHigh] xor before[FeedbackLow]).int shr 1) and 1)
    nextState = (oldState shr 1) or (injectedBit shl 15)
  spc.x = 0xA6
  spc.y = 0xC3
  spc.a = 0x37
  spc.psw = status
  let writes = spc.execute(FlushEntry, (if active: FlushExit else: SkipExit), 200)
  if active:
    doAssert writes == expectedWrites(before)
    doAssert spc.ram[QueuedOn] == 0 and spc.ram[QueuedOff] == 0
    doAssert spc.ram[FeedbackHigh].int * 256 + spc.ram[FeedbackLow].int == nextState
    doAssert spc.a.int == ((before[FeedbackHigh] xor before[FeedbackLow]).int shr 2)
    doAssert spc.y == 0
    let finalX = if (before[Settle] and 128) != 0: QueuedOn
      elif before[Settle] == before[RequestedDelay]: EchoLeft else: Flags
    doAssert spc.x.int == finalX
    doAssert ((spc.psw and PswC) != 0) == ((before[FeedbackLow] and 1) != 0)
    doAssert ((spc.psw and PswN) != 0) == ((nextState and 255) >= 128)
    doAssert ((spc.psw and PswZ) != 0) == ((nextState and 255) == 0)
    inc totals.flushes
  else:
    doAssert writes.len == 0 and spc.ram[0 .. 0xEF] == before
    doAssert spc.a == before[Mode] and spc.x == 0xA6 and spc.y == 0xC3
    doAssert ((spc.psw and PswN) != 0) == (before[Mode] >= 128)
    doAssert (spc.psw and PswZ) == 0
    doAssert (spc.psw and PswC) == (status and PswC)
    inc totals.suppressed
  doAssert (spc.psw and (PswP or PswI or PswB or PswH or PswV)) ==
    (status and (PswP or PswI or PswB or PswH or PswV))
  for address in 0 .. 0xEF:
    if not active or address notin [QueuedOn, QueuedOff, FeedbackHigh, FeedbackLow]:
      doAssert spc.ram[address] == before[address], &"flush changed unrelated DP ${address:02X}"
  doAssert spc.ram[0x100 .. 0x1FF] == beforeStack
  doAssert spc.ram[0x200 .. 0x2FF] == beforeArrays

proc checkAdvance(spc: var Spc, status: uint8, totals: var Totals) =
  ## Advance the observed byte toward equality modulo 256 without consuming the saved timer frame.
  let
    before = spc.ram[0 .. 0xEF]
    beforeStack = spc.ram[0x100 .. 0x1FF]
    old = before[Settle].int
    target = before[RequestedDelay].int
    equal = old == target
    expected = if equal: old else: (old + 1) and 255
  spc.a = 0x37
  spc.x = 0xA6
  spc.y = 0xC3
  spc.psw = status
  doAssert spc.execute(AdvanceEntry, AdvanceExit, 4).len == 0
  doAssert spc.a == 0x37 and spc.x == 0xA6 and spc.y == 0xC3
  doAssert spc.ram[Settle].int == expected
  doAssert ((spc.psw and PswC) != 0) == (old >= target)
  doAssert ((spc.psw and PswN) != 0) == (not equal and expected >= 128)
  doAssert ((spc.psw and PswZ) != 0) == (equal or expected == 0)
  doAssert (spc.psw and (PswP or PswI or PswB or PswH or PswV)) ==
    (status and (PswP or PswI or PswB or PswH or PswV))
  for address in 0 .. 0xEF:
    if address != Settle: doAssert spc.ram[address] == before[address]
  doAssert spc.ram[0x100 .. 0x1FF] == beforeStack
  inc totals.advances

proc matrices(spc: var Spc, totals: var Totals) =
  ## Cover complete gate/feedback domains and queue values plus suppression and direct bypass.
  for state in 0 .. 65535:
    let
      current = state shr 8
      requested = state and 255
      seed = (current xor requested) and 255
      status = if (state and 1) == 0: 0'u8 else: 0xDF'u8
    spc.prepare(current, requested, state, seed, 0)
    spc.ram[0x1A] = 255
    spc.checkFlush(status, totals)
    spc.prepare(current, requested, state xor 65535, seed, 0)
    spc.checkAdvance(status, totals)
  for keyOn in 0 .. 255:
    for keyOff in 0 .. 255:
      spc.prepare((keyOn and 3) * 64, keyOff, 0xA55A, keyOn xor keyOff, 0)
      spc.ram[QueuedOn] = keyOn.uint8
      spc.ram[QueuedOff] = keyOff.uint8
      spc.ram[ZeroWord] = (keyOn xor keyOff).uint8
      spc.checkFlush(PswI or PswB or PswH or PswV, totals)
  for mode in 1 .. 255:
    for current in Edges:
      for requested in Edges:
        spc.prepare(current, requested, 0x1234, mode, mode)
        spc.checkFlush(0xDF, totals)
  for mode in 0 .. 255:
    spc.prepare(0, 0, 0x1234, mode, mode)
    let before = spc.ram[0 .. 0x2FF]
    spc.a = 0x37
    spc.x = 0xA6
    spc.y = 0xC3
    spc.psw = 0xDF
    doAssert spc.execute(SkipEntry, SkipExit, 1).len == 0
    doAssert spc.ram[0 .. 0x2FF] == before
    doAssert spc.a == 0x37 and spc.x == 0xA6 and spc.y == 0xC3 and spc.psw == 0xDF
    inc totals.directSkips
  for initial in Edges:
    for requested in Edges:
      spc.prepare(initial, requested, 0x1234, initial xor requested, 0)
      for index in 0 .. ((requested - initial) and 255) + 1:
        spc.checkFlush(PswI or PswB, totals)
        spc.checkAdvance(PswI or PswB, totals)
      doAssert spc.ram[Settle].int == requested
      inc totals.chains

proc main() =
  ## Require original and independently byte-identical rebuilt images with no audible output.
  var totals: Totals
  for image in engineImages("bin/spc_dsp_flush_extract"):
    var spc = newSpc()
    for index in 0 ..< DriverLength: spc.ram[DriverStart + index] = image[DriverPayload + index]
    spc.matrices(totals)
  echo &"SPC DSP flush passed: {totals.flushes} publications, {totals.suppressed} mode suppressions, " &
    &"{totals.directSkips} direct bypasses, {totals.advances} settle advances in " &
    &"{totals.chains} complete settle/publication chains across both images."

when isMainModule:
  main()
