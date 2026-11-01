## Independent echo commands, delay readback, FIR indexing and global fade behavior.
## Synthetic coefficients occupy only the 32-byte window preceding DSP descriptors.
## Wider unchecked reads use unchanged bytes from the user's runtime image.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  PortWrite = tuple[address: uint16, value: uint8]
  Observation = object
    writes: seq[PortWrite]
    reads: int
  Totals = object
    setters, fadeSetups, delayHelpers, configurations, ticks, transitions: int
    reconfigurations, flushes, wrongSavedX, settlingChains, settlingPasses: int

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  TickEntry = 0x0905'u16
  TickExit = 0x091E'u16
  FirBase = 0x0E88
  Guard = 0xA5'u8
  ByteEdges = [0, 1, 127, 128, 254, 255]
  WordEdges = [0, 1, 255, 256, 32767, 32768, 65534, 65535]
  Durations = [0, 1, 2, 3, 127, 255]

proc word(spc: Spc, address: int): int =
  ## Read a synthetic little-endian word with address wrap.
  spc.ram[address and 65535].int or (spc.ram[(address + 1) and 65535].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Store authored state modulo sixteen bits.
  spc.ram[address and 65535] = uint8(value and 255)
  spc.ram[(address + 1) and 65535] = uint8((value shr 8) and 255)

proc stack(spc: var Spc) =
  ## Supply an external return and guard the deepest nested native frames.
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E8] = Guard
  spc.ram[0x1F2] = Guard
  spc.sp = 0xEF

proc execute(spc: var Spc, entry, stop: uint16, hardwareDelay = -1,
    budget = 250): Observation =
  ## Capture real ports and provide only the DSP EDL register read requested by the helper.
  var
    observed: Observation
    selected = -1
    instructions = 0
  spc.readHook = proc(address: uint16): int =
    doAssert address == 0xF3 and selected == 0x7D and hardwareDelay >= 0
    doAssert observed.reads == 0 and observed.writes == @[(0xF2'u16, 0x7D'u8)]
    inc observed.reads
    hardwareDelay
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address in [0xF2'u16, 0xF3'u16]
    observed.writes.add (address, value)
    if address == 0xF2: selected = value.int
    false
  spc.pc = entry
  while spc.pc != stop:
    doAssert instructions < budget, &"echo entry ${entry:04X} stalled at ${spc.pc:04X}"
    doAssert spc.sp in 0xE9'u8 .. 0xF1'u8
    spc.step()
    inc instructions
  doAssert not spc.stopped
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E8] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil
  result = observed

proc prepare(spc: var Spc, channel: int, status = 0xDF'u8) =
  ## Initialize distinct shadows and explicit zero/saved-X prerequisites.
  for address in 0 .. 0xEF:
    spc.ram[address] = uint8((address * 37 + 11) and 255)
  spc.putWord(0x0E, 0)
  spc.ram[0x12] = 0x55
  spc.ram[0x13] = 0xB5
  spc.ram[0x1A] = 255      # Echo writes must bypass the guarded-pitch/stereo inhibition.
  spc.ram[0x1B] = 255
  spc.ram[0x44] = channel.uint8
  spc.ram[0x47] = 255
  spc.ram[0x48] = 0xD3
  spc.ram[0x4A] = 0xA5
  spc.ram[0x4C] = 0x91
  spc.ram[0x4D] = 0xC3
  spc.ram[0x4E] = 0x5A
  spc.ram[0x5E] = 0x6A
  spc.putWord(0x60, 0xB47D)
  spc.putWord(0x62, 0x6655)
  spc.putWord(0x64, 0x1234)
  spc.putWord(0x66, 0xFEDC)
  spc.ram[0x68] = 0xD3
  spc.ram[0x69] = 0xA5
  spc.ram[0x6A] = 0x5A
  spc.a = 0xA6
  spc.y = 0xC3
  spc.x = channel.uint8
  spc.psw = status
  spc.stack()

proc expectedStep(current, target, duration: int): int =
  ## Model full-byte signed displacement and SPC's zero-divisor law independently.
  let
    delta = target - current
    magnitude = abs(delta)
    quotient = if duration == 0: 65535 - magnitude else: magnitude * 256 div duration
  (if delta < 0: -quotient else: quotient) and 65535

proc addPort(writes: var seq[PortWrite], register, value: int) =
  ## Append an expected hardware register/value pair.
  writes.add (0xF2'u16, register.uint8)
  writes.add (0xF3'u16, value.uint8)

proc delayWrites(request, hardware, history, flagShadow: int): seq[PortWrite] =
  ## Specify full-byte readback comparison and unconditional ESA output in hardware order.
  result.add (0xF2'u16, 0x7D'u8)
  if request != hardware:
    for register in [0x4D, 0x0D, 0x3C, 0x2C]:
      result.addPort(register, 0)
    result.addPort(0x6C, flagShadow or 32)
    result.addPort(0x7D, request)
  result.addPort(0x6D, 255 - ((request * 8) and 255))

proc delayHistory(request, hardware, history: int): int =
  ## Derive history replacement or wrapping accumulation from the old hardware low nibble.
  if request == hardware:
    history
  else:
    let wait = 255 - (hardware and 15)
    if history >= 128: (history + wait) and 255 else: wait

proc checkSetter(spc: var Spc, command, channel, first, left, right, stream,
    oldCount: int, direct: bool, status: uint8) =
  ## Check F5 byte replacement versus F6 direct YA copying, retaining every fade field.
  spc.prepare(channel, status)
  spc.ram[0x68] = oldCount.uint8
  spc.ram[0x48] = uint8(first xor 0xA5)
  spc.putWord(0x30 + channel, stream)
  if command == 0xF5:
    if direct:
      spc.ram[stream] = left.uint8
      spc.ram[(stream + 1) and 65535] = right.uint8
    else:
      spc.ram[stream] = first.uint8
      spc.ram[(stream + 1) and 65535] = left.uint8
      spc.ram[(stream + 2) and 65535] = right.uint8
  else:
    spc.ram[stream] = 0xA6
  let before = spc.ram[0 .. 0xEF]
  spc.a = uint8(if direct: first else: command)
  spc.y = (if command == 0xF6 and direct: left else: 0xC3).uint8
  let
    directWord = left * 256 + first
    expectedLeft = if command == 0xF5: left * 256 elif direct: directWord else: 0
    expectedRight = if command == 0xF5: right * 256 elif direct: directWord else: 0
    consumed = if command == 0xF6: 0 elif direct: 2 else: 3
    entry = if not direct: 0x943'u16 elif command == 0xF5: 0xACF'u16 else: 0xB03'u16
  let observed = spc.execute(entry, ReturnAddress)
  doAssert observed.reads == 0 and observed.writes.len == 0
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.word(0x60) == expectedLeft and spc.word(0x62) == expectedRight
  doAssert spc.word(0x30 + channel) == ((stream + consumed) and 65535)
  doAssert spc.ram[0x48].int ==
    (if command == 0xF5: before[0x48].int and (255 xor 32) else: before[0x48].int or 32)
  doAssert spc.ram[0x4A].int == (if command == 0xF5: first else: before[0x4A].int)
  doAssert spc.a.int == (if command == 0xF5: 0 elif direct: first else: 0)
  doAssert spc.y.int == (if command == 0xF5: right elif direct: left else: 0)
  if command == 0xF6 and direct:
    doAssert spc.psw == status
  else:
    doAssert (spc.psw and (PswP or PswI or PswB or PswH or PswV)) ==
      (status and (PswP or PswI or PswB or PswH or PswV))
    doAssert (spc.psw and PswC) == (if direct: status and PswC else: 0'u8)
    doAssert (spc.psw and (PswN or PswZ)) == PswZ
  for address in 0 .. 0xEF:
    let changed = address in 0x60 .. 0x63 or address == 0x48 or
      (command == 0xF5 and address == 0x4A) or
      (command == 0xF5 and address in 0x30 + channel .. 0x31 + channel)
    if not changed:
      doAssert spc.ram[address] == before[address]

proc checkFade(spc: var Spc, channel, duration, targetLeft, targetRight,
    currentLeft, currentRight, stream, seed: int, direct: bool) =
  ## Verify two signed steps, unchanged fractional currents and restored-X stream fetches.
  spc.prepare(channel)
  spc.putWord(0x60, currentLeft)
  spc.putWord(0x62, currentRight)
  spc.ram[0x12] = seed.uint8
  spc.putWord(0x30 + channel, stream)
  if direct:
    spc.ram[stream] = targetLeft.uint8
    spc.ram[(stream + 1) and 65535] = targetRight.uint8
  else:
    spc.ram[stream] = duration.uint8
    spc.ram[(stream + 1) and 65535] = targetLeft.uint8
    spc.ram[(stream + 2) and 65535] = targetRight.uint8
  let
    before = spc.ram[0 .. 0xEF]
    leftStep = expectedStep(currentLeft shr 8, targetLeft, duration)
    rightStep = expectedStep(currentRight shr 8, targetRight, duration)
  spc.a = uint8(if direct: duration else: 0xF8)
  let observed = spc.execute((if direct: 0xAE2'u16 else: 0x943'u16), ReturnAddress)
  doAssert observed.reads == 0 and observed.writes.len == 0
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.word(0x60) == currentLeft and spc.word(0x62) == currentRight
  doAssert spc.ram[0x68].int == duration
  doAssert spc.ram[0x69].int == targetLeft and spc.ram[0x6A].int == targetRight
  doAssert spc.word(0x64) == leftStep and spc.word(0x66) == rightStep
  doAssert spc.word(0x30 + channel) == ((stream + (if direct: 2 else: 3)) and 65535)
  doAssert spc.a.int + 256 * spc.y.int == rightStep
  doAssert spc.ram[0x12].int == ((seed shr 2) or
    (if targetLeft < (currentLeft shr 8): 64 else: 0) or
    (if targetRight < (currentRight shr 8): 128 else: 0))
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  if targetRight < (currentRight shr 8):
    let magnitude = if duration == 0: 65535 - abs(targetRight - (currentRight shr 8))
      else: abs(targetRight - (currentRight shr 8)) * 256 div duration
    doAssert ((spc.psw and PswC) != 0) == (magnitude == 0)
    doAssert ((spc.psw and PswN) != 0) == (rightStep >= 32768)
    doAssert ((spc.psw and PswZ) != 0) == (rightStep == 0)
    doAssert ((spc.psw and PswH) != 0) == ((magnitude and 4095) == 0)
    doAssert ((spc.psw and PswV) != 0) == (magnitude == 32768)
  else:
    doAssert ((spc.psw and PswC) != 0) == ((seed and 2) != 0)
    doAssert ((spc.psw and PswN) != 0) == (channel >= 128)
    doAssert ((spc.psw and PswZ) != 0) == (channel == 0)
    doAssert ((spc.psw and PswH) != 0) ==
      (duration == 0 or (duration and 15) <= ((abs(targetRight - (currentRight shr 8)) mod duration) and 15))
    doAssert ((spc.psw and PswV) != 0) == (duration == 0)
  for address in 0 .. 0xEF:
    let changed = address in [0x12, 0x14, 0x15] or address in 0x64 .. 0x6A or
      address in 0x30 + channel .. 0x31 + channel
    if not changed:
      doAssert spc.ram[address] == before[address]

proc tick(spc: var Spc) =
  ## Check both wrapping sums, final integer snaps, freeze and right-ADDW status provenance.
  let
    left = spc.word(0x60)
    right = spc.word(0x62)
    leftStep = spc.word(0x64)
    rightStep = spc.word(0x66)
    count = spc.ram[0x68].int
    targetLeft = spc.ram[0x69].int
    targetRight = spc.ram[0x6A].int
    next = max(0, count - 1)
    rightSum = (right + rightStep) and 65535
    expectedLeft = if count == 0: left elif next == 0: targetLeft * 256
      else: (left + leftStep) and 65535
    expectedRight = if count == 0: right elif next == 0: targetRight * 256 else: rightSum
    before = spc.ram[0 .. 0xEF]
    flags = PswI or PswB or PswC or PswH or PswV or PswN
  spc.stack()
  spc.x = 0xA6
  spc.y = 0xC3
  spc.psw = flags
  let observed = spc.execute(TickEntry, TickExit, budget = 25)
  doAssert observed.reads == 0 and observed.writes.len == 0
  doAssert spc.sp == 0xEF and spc.x == 0xA6
  doAssert spc.word(0x60) == expectedLeft and spc.word(0x62) == expectedRight
  doAssert spc.ram[0x68].int == next
  if count == 0:
    doAssert spc.a == 0 and spc.y == 0xC3
    doAssert (spc.psw and (PswC or PswH or PswV or PswI or PswB)) ==
      (flags and (PswC or PswH or PswV or PswI or PswB))
    doAssert (spc.psw and (PswN or PswZ)) == PswZ
  else:
    doAssert ((spc.psw and PswC) != 0) == (right + rightStep > 65535)
    doAssert ((spc.psw and PswH) != 0) == ((right and 4095) + (rightStep and 4095) > 4095)
    doAssert ((spc.psw and PswV) != 0) ==
      (((not (right xor rightStep)) and (right xor rightSum) and 32768) != 0)
    doAssert spc.a.int + 256 * spc.y.int == expectedRight
    let statusValue = if next == 0: targetRight else: rightSum
    doAssert ((spc.psw and PswN) != 0) ==
      (if next == 0: statusValue >= 128 else: statusValue >= 32768)
    doAssert ((spc.psw and PswZ) != 0) == (statusValue == 0)
  for address in 0 .. 0xEF:
    if address notin [0x60, 0x61, 0x62, 0x63, 0x68]:
      doAssert spc.ram[address] == before[address]

proc checkDelay(spc: var Spc, request, hardware, history, flags: int) =
  ## Compare full request/readback bytes and verify history plus exact unguarded DSP ordering.
  spc.prepare(6)
  spc.ram[0x4C] = history.uint8
  spc.ram[0x48] = flags.uint8
  let before = spc.ram[0 .. 0xEF]
  spc.a = request.uint8
  let observed = spc.execute(0xB2C, ReturnAddress, hardware)
  let esa = 255 - ((request * 8) and 255)
  doAssert observed.reads == 1
  doAssert observed.writes == delayWrites(request, hardware, history, flags)
  doAssert spc.ram[0x4D].int == request
  doAssert spc.ram[0x4C].int == delayHistory(request, hardware, history)
  doAssert spc.a.int == esa and spc.y == 0x6D and spc.x == 6 and spc.sp == 0xF1
  # Final MOV Y,#$6D overwrites N/Z after the ESA ADC; C/H/V still come from ADC.
  doAssert (spc.psw and (PswC or PswH or PswV or PswN or PswZ)) == (PswC or PswH)
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  for address in 0 .. 0xEF:
    if address notin [0x4C, 0x4D]:
      doAssert spc.ram[address] == before[address]

proc checkConfigure(spc: var Spc, runtimeWindow: seq[uint8], request, feedback,
    selector, hardware, history, channel, cursor: int, direct: bool,
    restoreX = -1) =
  ## Verify F7's real helper, feedback byte and eight wrapped-index FIR writes.
  spc.prepare(channel)
  let expectedX = if restoreX < 0: channel else: restoreX
  spc.ram[0x44] = expectedX.uint8
  spc.ram[0x4C] = history.uint8
  spc.putWord(0x30 + channel, cursor)
  if direct:
    spc.ram[cursor] = feedback.uint8
    spc.ram[(cursor + 1) and 65535] = selector.uint8
  else:
    spc.ram[cursor] = request.uint8
    spc.ram[(cursor + 1) and 65535] = feedback.uint8
    spc.ram[(cursor + 2) and 65535] = selector.uint8
  let before = spc.ram[0 .. 0xEF]
  spc.a = uint8(if direct: request else: 0xF7)
  let observed = spc.execute((if direct: 0xB0A'u16 else: 0x943'u16), ReturnAddress, hardware)
  var expected = delayWrites(request, hardware, history, before[0x48].int)
  for index in 0 ..< 8:
    expected.addPort(0x0F + index * 16, runtimeWindow[((selector * 8) + index) and 255].int)
  doAssert observed.reads == 1 and observed.writes == expected
  doAssert spc.ram[0x4D].int == request and spc.ram[0x4E].int == feedback
  doAssert spc.ram[0x4C].int == delayHistory(request, hardware, history)
  doAssert spc.word(0x30 + channel) == ((cursor + (if direct: 2 else: 3)) and 65535)
  doAssert spc.sp == 0xF1 and spc.x.int == expectedX and spc.a == 0x8F and spc.y == 0x8F
  doAssert (spc.psw and (PswC or PswH or PswV or PswN or PswZ)) ==
    (PswV or (if expectedX == 0: PswZ else: 0'u8))
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  for address in 0 .. 0xEF:
    let changed = address in [0x4C, 0x4D, 0x4E] or address in 0x30 + channel .. 0x31 + channel
    if not changed:
      doAssert spc.ram[address] == before[address]
  doAssert spc.ram[FirBase .. FirBase + 255] == runtimeWindow

proc flushEcho(spc: var Spc, expectedLeft, expectedRight: int) =
  ## Feed actual produced current bytes into the full original unguarded flush loop.
  spc.ram[0x1B] = 0
  spc.ram[0x4C] = 0
  spc.ram[0x4D] = 0
  spc.stack()
  let observed = spc.execute(0x546, 0x56A, budget = 200)
  doAssert observed.reads == 0 and observed.writes.len == 20
  doAssert observed.writes[^4 .. ^1] == @[(0xF2'u16, 0x3C'u8),
    (0xF3'u16, expectedRight.uint8), (0xF2'u16, 0x2C'u8), (0xF3'u16, expectedLeft.uint8)]
  doAssert spc.ram[0x61].int == expectedLeft and spc.ram[0x63].int == expectedRight
  doAssert spc.sp == 0xEF

proc flushProducedEcho(spc: var Spc, settle, request: int) =
  ## Check full publication and cleanup without replacing the producer's settle state.
  let before = spc.ram[0 .. 0xEF]
  doAssert before[0x4C].int == settle and before[0x4D].int == request
  doAssert before[0x1B] == 0 and before[0x1A] == 255
  var expected: seq[PortWrite]
  # Fixed register/source roles are independent of the runtime descriptor bytes.
  expected.addPort(0x5C, before[0x46].int)
  expected.addPort(0x2D, before[0x4B].int)
  expected.addPort(0x3D, before[0x49].int)
  expected.addPort(0x5C, 0)
  expected.addPort(0x4C, before[0x45].int)
  if settle < 128:
    expected.addPort(0x6C, before[0x48].int)
    if settle == request:
      expected.addPort(0x4D, before[0x4A].int)
      expected.addPort(0x0D, before[0x4E].int)
      expected.addPort(0x3C, before[0x63].int)
      expected.addPort(0x2C, before[0x61].int)
  let observed = spc.execute(0x546, 0x579, budget = 200)
  doAssert observed.reads == 0 and observed.writes == expected
  doAssert spc.sp == 0xEF
  doAssert spc.ram[0x45] == 0 and spc.ram[0x46] == 0
  let
    oldFeedback = before[0x18].int * 256 + before[0x19].int
    injectedBit = 1 xor (((before[0x18] xor before[0x19]).int shr 1) and 1)
    nextFeedback = (oldFeedback shr 1) or (injectedBit shl 15)
  doAssert spc.ram[0x18].int == (nextFeedback shr 8)
  doAssert spc.ram[0x19].int == (nextFeedback and 255)
  for address in 0 .. 0xEF:
    if address notin [0x18, 0x19, 0x45, 0x46]:
      doAssert spc.ram[address] == before[address]

proc checkSettlingChain(spc: var Spc, runtimeWindow: seq[uint8], request,
    hardware, history: int, configure: bool): int =
  ## Carry actual helper/F7 output through every settle pass, full flush and equality hold.
  spc.prepare(6)
  spc.ram[0x1B] = 0
  spc.ram[0x4C] = history.uint8
  spc.putWord(0x36, 0x4800)
  spc.ram[0x4800] = 0x87
  spc.ram[0x4801] = 2
  spc.a = request.uint8
  var expected = delayWrites(request, hardware, history, spc.ram[0x48].int)
  if configure:
    for index in 0 ..< 8:
      expected.addPort(0x0F + 16 * index, runtimeWindow[16 + index].int)
  let observed = spc.execute((if configure: 0xB0A'u16 else: 0xB2C'u16),
    ReturnAddress, hardware)
  doAssert observed.reads == 1 and observed.writes == expected
  let
    produced = delayHistory(request, hardware, history)
    distance = (request - produced) and 255
  doAssert spc.ram[0x4C].int == produced and spc.ram[0x4D].int == request
  doAssert spc.ram[0x4E].int == (if configure: 0x87 else: 0x5A)
  spc.stack()
  # Only the original updater writes $4C after the producer; $4D is never rewritten.
  for pass in 0 .. distance:
    let settle = (produced + pass) and 255
    spc.flushProducedEcho(settle, request)
    inc result
    if pass < distance:
      let advanced = spc.execute(0x5C6, 0x5CD, budget = 4)
      doAssert advanced.reads == 0 and advanced.writes.len == 0
      doAssert spc.ram[0x4C].int == ((settle + 1) and 255)
      doAssert spc.ram[0x4D].int == request
  let held = spc.execute(0x5C6, 0x5CD, budget = 4)
  doAssert held.reads == 0 and held.writes.len == 0
  spc.flushProducedEcho(request, request)
  inc result

proc checkImage(image: seq[uint8]): Totals =
  ## Run independent commands, readback, fades and consumers without importing assembly fixtures.
  var spc = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[DriverMap + address]
  for index in 0 ..< 32:
    spc.ram[FirBase + index] = uint8((index * 47 + 13) and 255)
  # Wider indices deliberately read the user's unchanged runtime bytes, including
  # descriptor/pitch data and code. Never synthesize or overwrite that wider window.
  let runtimeWindow = spc.ram[FirBase .. FirBase + 255]
  for context in [(0, 0, 0), (3, 3, 3), (16, 16, 16), (255, 255, 255),
      (3, 1, 128), (16, 0, 0), (255, 15, 255), (0, 255, 1),
      (16, 255, 128), (255, 0, 0), (1, 0, 128)]:
    for configure in [false, true]:
      result.settlingPasses += spc.checkSettlingChain(runtimeWindow,
        context[0], context[1], context[2], configure)
      inc result.settlingChains
  for left in 0 .. 255:
    for right in 0 .. 255:
      let channel = ((left xor right) and 7) * 2
      spc.checkSetter(0xF5, channel, left xor right, left, right,
        (if (left and 1) == 0: 0x48FF else: 0xFFFF), 3,
        (left and 1) != 0, (if (right and 1) == 0: 0'u8 else: 0xDF'u8))
      inc result.setters
  for value in 0 .. 65535:
    spc.checkSetter(0xF6, (value and 7) * 2, value and 255, value shr 8, 0,
      0xF3, 2, true, (if (value and 1) == 0: 0'u8 else: 0xDF'u8))
    inc result.setters
  for channel in countup(0, 14, 2):
    for count in [0, 1, 255]:
      for status in [0'u8, 0xDF'u8]:
        spc.checkSetter(0xF6, channel, 255, 255, 0, 0xFFFF, count, false, status)
        inc result.setters
  for duration in 0 .. 255:
    for target in 0 .. 255:
      for direct in [false, true]:
        let
          channel = ((duration xor target) and 7) * 2
          left = (((duration * 73 + target * 31) and 255) * 256 + target)
          right = ((duration xor target) * 256 + ((duration + target) and 255))
        spc.checkFade(channel, duration, target, 255 - target, left, right,
          (if direct: 0xFFFF else: 0x48FF), 0x55, direct)
        inc result.fadeSetups
  for request in 0 .. 255:
    for hardware in 0 .. 255:
      for history in [0, 127, 128, 255]:
        spc.checkDelay(request, hardware, history, request xor hardware)
        inc result.delayHelpers
  for selector in 0 .. 255:
    for pair in [(0, 0), (0, 16), (1, 0), (15, 15), (16, 0), (255, 15), (255, 255), (128, 255)]:
      for history in [0, 127, 128, 255]:
        for direct in [false, true]:
          spc.checkConfigure(runtimeWindow, pair[0], selector xor 255, selector,
            pair[1], history, ((selector + history) and 7) * 2,
            (if direct: 0xFFFF else: 0x48FF), direct)
          inc result.configurations
  for left in ByteEdges:
    for right in ByteEdges:
      for targetLeft in [0, 127, 255]:
        for targetRight in [0, 1, 128, 255]:
          for duration in Durations:
            for fraction in [0, 127, 255]:
              spc.checkFade(6, duration, targetLeft, targetRight, left * 256 + fraction,
                right * 256 + (255 - fraction), 0xFFFF, fraction, false)
              inc result.fadeSetups
              for index in 0 .. duration:
                spc.tick()
                inc result.ticks
              doAssert spc.word(0x60) ==
                (if duration == 0: left * 256 + fraction else: targetLeft * 256)
              doAssert spc.word(0x62) ==
                (if duration == 0: right * 256 + 255 - fraction else: targetRight * 256)
              inc result.transitions
  for left in WordEdges:
    for right in WordEdges:
      for stepLeft in [0, 1, 255, 256, 32768, 65535]:
        for stepRight in [0, 1, 255, 256, 32768, 65535]:
          for count in [0, 1, 2]:
            spc.prepare(6)
            spc.putWord(0x60, left)
            spc.putWord(0x62, right)
            spc.putWord(0x64, stepLeft)
            spc.putWord(0x66, stepRight)
            spc.ram[0x68] = count.uint8
            spc.tick()
            inc result.ticks
  for command in [0xF5, 0xF6]:
    for channel in countup(0, 14, 2):
      for count in [0, 1, 2, 255]:
        spc.checkSetter(command, channel, 0xE7, 0x81, 0x37, 0x48FF, count, true, 0xDF)
        inc result.setters
        let
          beforeLeft = if command == 0xF5: 0x8100 else: 0x81E7
          beforeRight = if command == 0xF5: 0x3700 else: 0x81E7
          expectedLeft = if count == 0: beforeLeft elif count == 1: 0xA500
            else: (beforeLeft + 0x1234) and 65535
          expectedRight = if count == 0: beforeRight elif count == 1: 0x5A00
            else: (beforeRight + 0xFEDC) and 65535
        spc.tick()
        inc result.ticks
        doAssert spc.word(0x60) == expectedLeft and spc.word(0x62) == expectedRight
        inc result.reconfigurations
        spc.flushEcho(expectedLeft shr 8, expectedRight shr 8)
        inc result.flushes
  spc.prepare(0)
  spc.ram[0x44] = 2
  spc.putWord(0x30, 0x4800)
  spc.putWord(0x32, 0x4900)
  spc.ram[0x4800] = 1
  spc.ram[0x4801] = 2
  spc.ram[0x4900] = 200
  spc.a = 3
  let mismatch = spc.execute(0xAE2, ReturnAddress)
  doAssert mismatch.reads == 0 and mismatch.writes.len == 0
  doAssert spc.x == 2 and spc.sp == 0xF1
  doAssert spc.word(0x30) == 0x4801 and spc.word(0x32) == 0x4901
  doAssert spc.ram[0x69] == 1 and spc.ram[0x6A] == 200
  doAssert spc.word(0x64) == expectedStep(0xB4, 1, 3)
  doAssert spc.word(0x66) == expectedStep(0x66, 200, 3)
  doAssert spc.word(0x60) == 0xB47D and spc.word(0x62) == 0x6655
  inc result.wrongSavedX
  spc.checkConfigure(runtimeWindow, 16, 0xA6, 255, 0, 255, 0, 0x48FF, true, 2)
  inc result.wrongSavedX

proc main() =
  ## Require original and fresh byte-identical rebuilt ROMs and report executed checks.
  var totals: Totals
  for image in engineImages("bin/spc_echo_control_extract"):
    let checked = checkImage(image)
    totals.setters += checked.setters
    totals.fadeSetups += checked.fadeSetups
    totals.delayHelpers += checked.delayHelpers
    totals.configurations += checked.configurations
    totals.ticks += checked.ticks
    totals.transitions += checked.transitions
    totals.reconfigurations += checked.reconfigurations
    totals.flushes += checked.flushes
    totals.wrongSavedX += checked.wrongSavedX
    totals.settlingChains += checked.settlingChains
    totals.settlingPasses += checked.settlingPasses
  echo &"SPC echo control passed: {totals.setters} setters, {totals.fadeSetups} fade setups, {totals.delayHelpers} delay/readback helpers, {totals.configurations} F7 configurations, {totals.ticks} ticks, {totals.transitions} full fades, {totals.reconfigurations} active-fade replacements, {totals.flushes} producer-to-flush chains and {totals.wrongSavedX} saved-X mismatch proofs."
  echo &"SPC produced settling passed: {totals.settlingChains} helper/F7-to-settle-to-full-flush contexts, {totals.settlingPasses} flush passes including equality holds."

when isMainModule:
  main()
