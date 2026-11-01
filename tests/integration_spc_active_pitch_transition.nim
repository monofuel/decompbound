## Independent F9 setup, held-service guards and actual caller ordering on authored streams.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  Observation = object
    trace: seq[uint16]
    reads, writes: int
  Totals = object
    kernels, dispatches, services, noPeek, savedX, callers: int

const
  DriverPayload = 0x260042
  DriverStart = 0x500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  Guard = 0xA5'u8
  Edges = [0, 1, 127, 128, 255]

proc word(spc: Spc, address: int): int =
  ## Read authored state with sixteen-bit address wrap.
  spc.ram[address and 65535].int or (spc.ram[(address + 1) and 65535].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Write a synthetic word without using emulated arithmetic.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address + 1) and 65535] = ((value shr 8) and 255).uint8

proc targetValue(raw, globalOffset, channelOffset: int): int =
  ## Keep first-add carry as an extra unit in the second byte sum before masking.
  let first = raw + globalOffset
  ((first and 255) + channelOffset + (if first >= 256: 1 else: 0)) and 127

proc stepValue(currentInteger, target, duration: int): int =
  ## Specify signed full-byte displacement, truncation and SPC zero-divisor behavior.
  let
    delta = target - currentInteger
    quotient = if duration == 0: 65535 - abs(delta) else: abs(delta) * 256 div duration
  (if delta < 0: -quotient else: quotient) and 65535

proc prepare(spc: var Spc, channel, current, globalOffset, channelOffset: int) =
  ## Guard persistent context and install the explicit zero word and native caller frame.
  for address in 0 .. 0xEF: spc.ram[address] = 0
  for address in 0x200 .. 0x38F: spc.ram[address] = Guard
  spc.putWord(0x0E, 0)
  spc.putWord(0x360 + channel, current)
  spc.putWord(0x370 + channel, 0x6655)
  spc.ram[0x380 + channel] = 0xC3
  spc.ram[0xA1 + channel] = 0xD3
  spc.ram[0x50] = globalOffset.uint8
  spc.ram[0x2F0 + channel] = channelOffset.uint8
  spc.ram[0x44] = channel.uint8
  spc.ram[0x12] = (0x54 or ((globalOffset + channelOffset) and 1)).uint8
  spc.ram[0x13] = 0xB5
  spc.ram[0x5E] = 0x6A
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E8] = Guard
  spc.ram[0x1F2] = Guard
  spc.sp = 0xEF
  spc.x = channel.uint8
  spc.y = 0xA6
  spc.psw = PswI or PswB or PswH or PswV or
    (if (current and 1) == 0: 0'u8 else: PswC)

proc execute(spc: var Spc, entry, stop: uint16, budget: int,
    capture = false, stopChannel = -1): Observation =
  ## Bound unchanged core execution and reject hardware access, including accidental peeks.
  var observed: Observation
  spc.readHook = proc(address: uint16): int =
    inc observed.reads
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    inc observed.writes
    false
  spc.pc = entry
  var instructions = 0
  while spc.pc != stop or (stopChannel >= 0 and spc.x.int != stopChannel):
    doAssert instructions < budget, &"active pitch ${entry:04X} at ${spc.pc:04X}"
    doAssert spc.sp in 0xE9'u8 .. 0xF1'u8
    if capture: observed.trace.add spc.pc
    spc.step()
    inc instructions
  doAssert observed.reads == 0 and observed.writes == 0
  doAssert not spc.stopped and spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E8] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil
  result = observed

proc checkKernel(spc: var Spc, channel, current, raw, globalOffset,
    channelOffset, delay, duration, stream: int, dispatch: bool, totals: var Totals) =
  ## Verify F9 operands and carry-chained target without rewriting produced state.
  spc.prepare(channel, current, globalOffset, channelOffset)
  spc.putWord(0x30 + channel, stream)
  let values = if dispatch: @[delay, duration, raw] else: @[duration, raw]
  for i, value in values: spc.ram[(stream + i) and 65535] = value.uint8
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[0x200 .. 0x38F]
    target = targetValue(raw, globalOffset, channelOffset)
    step = stepValue(current shr 8, target, duration)
    magnitude = abs(target - (current shr 8))
    quotient = if duration == 0: 65535 - magnitude else: magnitude * 256 div duration
  spc.a = (if dispatch: 0xF9 else: delay).uint8
  discard spc.execute((if dispatch: 0x0943'u16 else: 0x0B94'u16), ReturnAddress, 90)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.ram[0xA0 + channel].int == duration and spc.ram[0xA1 + channel].int == delay
  doAssert spc.ram[0x380 + channel].int == target
  doAssert spc.word(0x370 + channel) == step
  doAssert spc.word(0x360 + channel) == current
  doAssert spc.word(0x30 + channel) == ((stream + (if dispatch: 3 else: 2)) and 65535)
  doAssert spc.a.int == (step shr 8) and spc.y.int == (step shr 8)
  doAssert ((spc.psw and PswN) != 0) == (step >= 32768)
  doAssert ((spc.psw and PswZ) != 0) == ((step shr 8) == 0)
  if target < (current shr 8):
    doAssert ((spc.psw and PswC) != 0) == (quotient == 0)
    doAssert ((spc.psw and PswH) != 0) == ((quotient and 4095) == 0)
    doAssert ((spc.psw and PswV) != 0) == (quotient == 32768)
  else:
    doAssert (spc.psw and PswC) == (beforeDp[0x12] and 1)
    let remainder = if duration == 0: 0 else: magnitude mod duration
    doAssert ((spc.psw and PswH) != 0) ==
      (duration == 0 or (duration and 15) <= (remainder and 15))
    doAssert ((spc.psw and PswV) != 0) == (duration == 0)
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  for address in 0 .. 0xEF:
    if address notin [0x12, 0x14, 0x15, 0x30 + channel, 0x31 + channel,
        0xA0 + channel, 0xA1 + channel]:
      doAssert spc.ram[address] == beforeDp[address]
  for address in 0x200 .. 0x38F:
    if address notin [0x370 + channel, 0x371 + channel, 0x380 + channel]:
      doAssert spc.ram[address] == beforeArrays[address - 0x200]
  if dispatch: inc totals.dispatches
  else: inc totals.kernels

proc checkService(spc: var Spc, channel, current, count, token, stream: int,
    totals: var Totals) =
  ## Check active/no-match guards and the matching path's single peek plus three fetches.
  spc.prepare(channel, current, 255, 1)
  spc.putWord(0x30 + channel, stream)
  spc.ram[0xA0 + channel] = count.uint8
  for i, value in [token, 7, 3, 255]: spc.ram[(stream + i) and 65535] = value.uint8
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[0x200 .. 0x38F]
    match = count == 0 and token == 0xF9
    target = targetValue(255, 255, 1)
    step = stepValue(current shr 8, target, 3)
    observed = spc.execute(0x0B84, ReturnAddress, 95, true)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.word(0x30 + channel) == ((stream + (if match: 4 else: 0)) and 65535)
  doAssert spc.word(0x360 + channel) == current
  if match:
    doAssert spc.ram[0xA0 + channel] == 3 and spc.ram[0xA1 + channel] == 7
    doAssert spc.ram[0x380 + channel].int == target
    doAssert spc.word(0x370 + channel) == step
    var
      fetches = 0
      advances = 0
      peeks = 0
    for pc in observed.trace:
      if pc == 0x0955: inc fetches
      if pc == 0x0957: inc advances
      if pc == 0x0B88: inc peeks
    doAssert fetches == 3 and advances == 4 and peeks == 1
    for address in 0 .. 0xEF:
      if address notin [0x12, 0x14, 0x15, 0x30 + channel, 0x31 + channel,
          0xA0 + channel, 0xA1 + channel]:
        doAssert spc.ram[address] == beforeDp[address]
    for address in 0x200 .. 0x38F:
      if address notin [0x370 + channel, 0x371 + channel, 0x380 + channel]:
        doAssert spc.ram[address] == beforeArrays[address - 0x200]
  else:
    doAssert spc.ram[0 .. 0xEF] == beforeDp
    doAssert spc.ram[0x200 .. 0x38F] == beforeArrays
    doAssert spc.y == 0xA6
    if count != 0:
      doAssert 0x0B88'u16 notin observed.trace
      doAssert spc.a.int == count
      doAssert (spc.psw and (PswC or PswH or PswV)) == (PswC or PswH or PswV)
      doAssert ((spc.psw and PswN) != 0) == (count >= 128)
      doAssert (spc.psw and PswZ) == 0
    else:
      doAssert 0x0B88'u16 in observed.trace
      let difference = (token - 0xF9) and 255
      doAssert spc.a.int == token
      doAssert ((spc.psw and PswC) != 0) == (token >= 0xF9)
      doAssert ((spc.psw and PswN) != 0) == (difference >= 128)
      doAssert (spc.psw and PswZ) == 0
  doAssert spc.ram[0x13] == 0xB5 and spc.ram[0x5E] == 0x6A
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  inc totals.services

proc checkNoPeek(spc: var Spc, channel, count: int, totals: var Totals) =
  ## Place the cursor on DSPADDR to make any forbidden active-state peek observable.
  spc.prepare(channel, 0x1200, 0, 0)
  spc.ram[0xA0 + channel] = count.uint8
  spc.putWord(0x30 + channel, 0x00F2)
  discard spc.execute(0x0B84, ReturnAddress, 4)
  doAssert spc.sp == 0xF1 and spc.word(0x30 + channel) == 0x00F2
  doAssert spc.ram[0xA0 + channel].int == count
  doAssert spc.a.int == count and spc.y == 0xA6 and spc.x.int == channel
  doAssert (spc.psw and (PswC or PswH or PswV)) == (PswH or PswV)
  inc totals.noPeek

proc checkSavedX(spc: var Spc, totals: var Totals) =
  ## Expose the saved-channel precondition rather than claiming mismatches preserve X.
  spc.prepare(0, 0x1201, 255, 1)
  spc.putWord(0x30, 0x4800)
  spc.ram[0x4800] = 3
  spc.ram[0x4801] = 255
  spc.ram[0x44] = 2
  spc.a = 7
  discard spc.execute(0x0B94, ReturnAddress, 90)
  doAssert spc.sp == 0xF1 and spc.x == 2
  doAssert spc.ram[0xA0] == 3 and spc.ram[0xA1] == 7
  doAssert spc.ram[0x380] == 0 and spc.ram[0x382] == Guard
  doAssert spc.word(0x370) == 0x6655
  doAssert spc.word(0x372) == stepValue(18, 0, 3)
  inc totals.savedX

proc checkCaller(spc: var Spc, channel, count, delay, mode: int, totals: var Totals) =
  ## Follow the real selected channel through CF7 before held F9 eligibility is tested.
  spc.prepare(channel, 0x1200, 1, 2)
  spc.ram[0x04] = 1
  spc.ram[0x00] = 0
  spc.ram[0x08] = 0
  spc.ram[0x0C] = 0
  spc.ram[0x1B] = mode.uint8
  spc.putWord(0x30 + channel, 0x5000)
  for i, value in [0xF9, 2, 3, 20]: spc.ram[0x5000 + i] = value.uint8
  spc.ram[0x70 + channel] = 2
  spc.ram[0x71 + channel] = 0
  spc.ram[0xA0 + channel] = count.uint8
  spc.ram[0xA1 + channel] = delay.uint8
  spc.ram[0x380 + channel] = 10
  spc.ram[0x1A] = (1 shl (channel div 2)).uint8
  spc.putWord(0x220 + channel, 0x100)
  let observed = spc.execute(0x07F9, 0x08F0, 1800, true, channel)
  doAssert spc.sp == 0xEF and spc.x.int == channel
  doAssert spc.ram[0x44].int == channel and spc.ram[0x5E] == 0
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  if mode != 0:
    doAssert 0x0CF7'u16 notin observed.trace and 0x0B84'u16 notin observed.trace
    doAssert spc.ram[0xA0 + channel].int == count
    doAssert spc.ram[0xA1 + channel].int == delay
    doAssert spc.word(0x360 + channel) == 0x1200
    doAssert spc.word(0x30 + channel) == 0x5000
    doAssert spc.ram[0x13] == 0xB5
  else:
    let
      afterCount = if count != 0 and delay == 0: count - 1 else: count
      afterDelay = if count != 0 and delay != 0: delay - 1 else: delay
      afterPitch = if count != 0 and delay == 0:
          (if afterCount == 0: 10 * 256 else: (0x1200 + 0x6655) and 65535)
        else: 0x1200
      available = afterCount == 0
    doAssert 0x08EA'u16 in observed.trace and 0x0CF7'u16 in observed.trace
    doAssert 0x0D60'u16 in observed.trace and 0x0BBC'u16 in observed.trace
    doAssert 0x0D79'u16 in observed.trace
    doAssert 0x0B84'u16 in observed.trace
    doAssert observed.trace.find(0x0CF7'u16) < observed.trace.find(0x0D60'u16)
    doAssert observed.trace.find(0x0D60'u16) < observed.trace.find(0x0BBC'u16)
    doAssert observed.trace.find(0x0BBC'u16) < observed.trace.find(0x0B84'u16)
    doAssert spc.word(0x360 + channel) == afterPitch
    doAssert spc.ram[0x13].int ==
      (0x35 or (if count != 0 and delay == 0: 128 else: 0))
    if available:
      doAssert 0x0B94'u16 in observed.trace and 0x0BC7'u16 in observed.trace
      doAssert spc.ram[0xA0 + channel] == 3 and spc.ram[0xA1 + channel] == 2
      doAssert spc.word(0x30 + channel) == 0x5004
      doAssert spc.word(0x370 + channel) == stepValue(afterPitch shr 8, 23, 3)
    else:
      doAssert 0x0B94'u16 notin observed.trace and 0x0B88'u16 notin observed.trace
      doAssert spc.ram[0xA0 + channel].int == afterCount
      doAssert spc.ram[0xA1 + channel].int == afterDelay
      doAssert spc.word(0x370 + channel) == 0x6655
      doAssert spc.word(0x30 + channel) == 0x5000
  inc totals.callers

proc main() =
  ## Require original and fresh byte-identical rebuilt images with no missing-ROM skips.
  var totals: Totals
  for image in engineImages("bin/spc_active_pitch_transition_extract"):
    var spc = newSpc()
    for i in 0 ..< DriverLength: spc.ram[DriverStart + i] = image[DriverPayload + i]
    for raw in 0 .. 255:
      for globalOffset in 0 .. 255:
        for channelOffset in Edges:
          let
            channel = ((raw xor globalOffset xor channelOffset) and 7) * 2
            current = ((raw xor globalOffset) * 256 + channelOffset) and 65535
          spc.checkKernel(channel, current, raw, globalOffset, channelOffset,
            raw xor globalOffset, (raw + globalOffset + channelOffset) and 255,
            0xFFFF, false, totals)
    for channel in countup(0, 14, 2):
      for raw in 0 .. 255:
        for duration in [0, 1, 2, 255]:
          for delay in [0, 1, 255]:
            for stream in [0x48FF, 0xFFFF]:
              spc.checkKernel(channel, 0x8001, raw, (raw * 73) and 255,
                raw xor 0x55, delay, duration, stream, true, totals)
    for channel in countup(0, 14, 2):
      for token in 0 .. 255:
        for count in [0, 1, 2, 127, 255]:
          for stream in [0x48FF, 0xFFFF]:
            spc.checkService(channel, 0x1201, count, token, stream, totals)
      for count in [1, 128, 255]: spc.checkNoPeek(channel, count, totals)
    spc.checkSavedX(totals)
    for channel in countup(0, 14, 2):
      for count in [0, 1, 2]:
        for delay in [0, 1]:
          for mode in [0, 1, 128]:
            spc.checkCaller(channel, count, delay, mode, totals)
  echo &"SPC active pitch transitions passed: {totals.kernels} direct F9 calls, " &
    &"{totals.dispatches} F9 dispatches, {totals.services} held-service calls, " &
    &"{totals.noPeek} I/O-cursor short circuits, {totals.savedX} saved-X contexts, " &
    &"{totals.callers} actual selected-channel 07F9 callers (including 96 original " &
    &"probe contexts per image plus count-zero truth-table extensions)."

when isMainModule:
  main()
