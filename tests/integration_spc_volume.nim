## Independent original-driver volume laws, using synthetic streams and RAM only.

import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  DispatchEntry = 0x0943'u16
  ChannelEntry = 0x0C40'u16
  ChannelExit = 0x0C79'u16
  FactorEntry = 0x0E56'u16
  GainEntry = 0x0E61'u16
  MasterTickEntry = 0x091E'u16
  MasterTickExit = 0x0930'u16
  ReturnAddress = 0x1E00'u16
  ByteEdges = [0, 1, 127, 128, 254, 255]
  WordEdges = [0, 1, 255, 256, 32767, 32768, 65534, 65535]
  Durations = [0, 1, 2, 3, 127, 255]
  Rates = [0, 1, 127, 128, 255]
  GainContexts = [(0, 255), (1, 255), (127, 128), (254, 255), (255, 255)]
  GuardStart = 0x0200
  GuardEnd = 0x035F
  GuardByte = 0xA5'u8

type PortWrite = tuple[address: uint16, value: uint8]

proc word(spc: Spc, address: int): int =
  ## Read an authored little-endian RAM word.
  spc.ram[address].int or (spc.ram[address + 1].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Write a synthetic word modulo sixteen bits.
  spc.ram[address] = uint8(value and 255)
  spc.ram[address + 1] = uint8((value shr 8) and 255)

proc silentIo(address: uint16, value: uint8): bool =
  ## Reject unexpected hardware-port writes during memory-only checks.
  doAssert false, &"volume math unexpectedly wrote I/O ${address:04X}=${value:02X}"
  false

proc prepareStack(spc: var Spc) =
  ## Install a caller return and guards below the deepest nested writer call.
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E7] = GuardByte
  spc.ram[0x1F2] = GuardByte
  spc.sp = 0xEF

proc execute(spc: var Spc, entry, stop: uint16, budget = 100) =
  ## Run unchanged driver code within an instruction and stack budget.
  spc.pc = entry
  var steps = 0
  while spc.pc != stop:
    doAssert steps < budget, &"volume helper ${entry:04X} exceeded its step budget"
    doAssert spc.sp in 0xE8'u8 .. 0xF1'u8
    spc.step()
    inc steps
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E7] == GuardByte and spc.ram[0x1F2] == GuardByte
  doAssert not spc.stopped

proc expectedStep(current, target, duration: int): int =
  ## Compute signed full-byte displacement with the independently verified zero-divisor law.
  let
    delta = target - current
    quotient = if duration == 0: 65535 - abs(delta) else: abs(delta) * 256 div duration
  (if delta < 0: -quotient else: quotient) and 65535

proc expectedGain(factor, master, channelFactor, current: int): int =
  ## Apply the three separately truncated gains, then square the resulting magnitude.
  let
    first = factor * master div 256
    second = first * channelFactor div 256
    third = second * current div 256
  third * third div 256

proc expectedFactor(phase, depth: int): int =
  ## Scale the unsigned triangle wave without interpreting phase as a signed byte.
  let triangle = if phase < 128: 2 * phase else: 511 - 2 * phase
  255 - depth * triangle div 256

proc expectedModulation(phase, depth, rate, counter, delay: int):
    tuple[phase, counter, factor: int, dirty: bool] =
  ## Model counter gating and the unsigned triangle wave independently of instructions.
  result = (phase, counter, 255, false)
  if depth == 0:
    return
  if counter != delay:
    result.counter = (counter + 1) and 255
    return
  result.dirty = true
  result.phase = if phase >= 128 and depth == 255: 128 else: (phase + rate) and 255
  result.factor = expectedFactor(result.phase, depth)

proc checkCommand(spc: var Spc, opcode, channel, stream, current, operand,
    target, oldDuration: int) =
  ## Check full command dispatch, wrapping stream consumption and all unrelated fields.
  let
    pointer = 0x30 + channel
    master = opcode in [0xE5, 0xE6]
    fading = opcode in [0xE6, 0xEE]
  for address in 0 .. 0xEF:
    spc.ram[address] = uint8((address * 37 + 11) and 255)
  for address in GuardStart .. GuardEnd:
    spc.ram[address] = uint8((address * 53 + 29) and 255)
  spc.putWord(0x0E, 0)
  spc.ram[0x44] = channel.uint8
  spc.ram[0x431] = 255      # These targets are not replaced by the pan override.
  spc.putWord(pointer, stream)
  spc.putWord(0x58, current)
  spc.ram[0x5A] = oldDuration.uint8
  spc.ram[0x5B] = 0xC3
  spc.putWord(0x5C, 0xB47D)
  spc.ram[0x5E] = 0x5A
  spc.putWord(0x300 + channel, current)
  spc.ram[0x90 + channel] = oldDuration.uint8
  spc.putWord(0x310 + channel, 0xB47D)
  spc.ram[0x320 + channel] = 0xC3
  spc.ram[0x321 + channel] = 0x6A
  spc.ram[stream] = operand.uint8
  spc.ram[(stream + 1) and 65535] = target.uint8
  spc.ram[(stream + 2) and 65535] = 0xE1
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[GuardStart .. GuardEnd]
    resultWord = if fading: expectedStep(current shr 8, target, operand) else: operand * 256
  spc.prepareStack()
  spc.a = opcode.uint8
  spc.y = 0xA6
  spc.x = channel.uint8
  spc.psw = PswI or PswB or PswC
  spc.execute(DispatchEntry, ReturnAddress)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.word(pointer) == ((stream + (if fading: 2 else: 1)) and 65535)
  if master:
    doAssert spc.word(0x58) == (if fading: current else: resultWord)
    doAssert spc.ram[0x5A].int == (if fading: operand else: oldDuration)
    doAssert spc.ram[0x5B].int == (if fading: target else: 0xC3)
    doAssert spc.word(0x5C) == (if fading: resultWord else: 0xB47D)
  else:
    doAssert spc.word(0x300 + channel) == (if fading: current else: resultWord)
    doAssert spc.ram[0x90 + channel].int == (if fading: operand else: oldDuration)
    doAssert spc.ram[0x320 + channel].int == (if fading: target else: 0xC3)
    doAssert spc.word(0x310 + channel) == (if fading: resultWord else: 0xB47D)
  doAssert spc.ram[0x5E] == 0x5A and spc.ram[0x321 + channel] == 0x6A
  doAssert spc.ram[0x431] == 255 and spc.word(0x0E) == 0
  doAssert spc.y.int == (resultWord shr 8)
  doAssert spc.a.int == (if opcode == 0xEE: resultWord shr 8 else: resultWord and 255)
  for address in 0 .. 0xEF:
    let changed = address in pointer .. pointer + 1 or
      (master and address in (if fading: 0x5A else: 0x58) .. (if fading: 0x5D else: 0x59)) or
      (not master and fading and address == 0x90 + channel) or
      (fading and address in [0x12, 0x14, 0x15])
    if not changed:
      doAssert spc.ram[address] == beforeDp[address], &"command ${opcode:02X} changed DP ${address:02X}"
  for address in GuardStart .. GuardEnd:
    let changed = not master and
      (address in (if fading: 0x310 else: 0x300) + channel .. (if fading: 0x311 else: 0x301) + channel or
      (fading and address == 0x320 + channel))
    if not changed:
      doAssert spc.ram[address] == beforeArrays[address - GuardStart],
        &"command ${opcode:02X} changed neighboring field ${address:04X}"
  doAssert spc.ram[stream].int == operand
  doAssert spc.ram[(stream + 1) and 65535].int == target
  doAssert spc.ram[(stream + 2) and 65535] == 0xE1
  doAssert (spc.psw and (PswI or PswB or PswP)) == (PswI or PswB)

proc checkGain(spc: var Spc, channel, factor, master, channelFactor, current: int) =
  ## Check direct gain truncation, ignored fractions and register/status preservation.
  let
    expected = expectedGain(factor, master, channelFactor, current)
    flags = if (factor xor current) mod 2 == 0: PswI or PswC or PswH or PswV else: PswB
  spc.putWord(0x58, master * 256 + 0xA5)
  spc.ram[0x210 + channel] = channelFactor.uint8
  spc.putWord(0x300 + channel, current * 256 + ((factor + current) and 255))
  spc.ram[0x321 + channel] = 0xA6
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[GuardStart .. GuardEnd]
  spc.prepareStack()
  spc.x = channel.uint8
  spc.a = factor.uint8
  spc.y = 0xC3
  spc.psw = flags
  spc.execute(GainEntry, ReturnAddress, 20)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.a.int == expected and spc.y.int == expected
  doAssert spc.ram[0x321 + channel].int == expected and expected <= 248
  doAssert (spc.psw and (PswC or PswH or PswV or PswI or PswB or PswP)) == flags
  doAssert ((spc.psw and PswN) != 0) == (expected >= 128)
  doAssert ((spc.psw and PswZ) != 0) == (expected == 0)
  doAssert spc.ram[0 .. 0xEF] == beforeDp
  for address in GuardStart .. GuardEnd:
    if address != 0x321 + channel:
      doAssert spc.ram[address] == beforeArrays[address - GuardStart]

proc checkFactor(spc: var Spc, channel, phase, depth: int) =
  ## Verify direct E56 inputs, including phases suppressed by the depth-255 caller.
  let factor = expectedFactor(phase, depth)
  spc.ram[0xC1 + channel] = depth.uint8
  spc.putWord(0x58, 0xFF7F)
  spc.ram[0x210 + channel] = 255
  spc.putWord(0x300 + channel, 0xFF7F)
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[GuardStart .. GuardEnd]
  spc.prepareStack()
  spc.x = channel.uint8
  spc.a = phase.uint8
  spc.psw = PswI or PswB or PswH or PswV
  spc.execute(FactorEntry, GainEntry, 12)
  doAssert spc.sp == 0xEF and spc.x.int == channel
  doAssert spc.a.int == factor and spc.y.int == 255 - factor
  doAssert ((spc.psw and PswC) != 0) == (phase >= 128)
  doAssert (spc.psw and (PswH or PswV)) == (PswH or PswV)
  spc.execute(GainEntry, ReturnAddress, 20)
  let gain = expectedGain(factor, 255, 255, 255)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.a.int == gain and spc.y.int == gain
  doAssert spc.ram[0x321 + channel].int == gain
  doAssert spc.ram[0 .. 0xEF] == beforeDp
  for address in GuardStart .. GuardEnd:
    if address != 0x321 + channel:
      doAssert spc.ram[address] == beforeArrays[address - GuardStart]

proc checkModulation(spc: var Spc, channel, phase, depth, rate, counter, delay: int) =
  ## Observe the factor at real E61 entry, then verify gain and channel fall-through.
  let expected = expectedModulation(phase, depth, rate, counter, delay)
  spc.ram[0x90 + channel] = 0
  spc.ram[0xC0 + channel] = counter.uint8
  spc.ram[0xC1 + channel] = depth.uint8
  spc.ram[0x2D0 + channel] = phase.uint8
  spc.ram[0x2D1 + channel] = rate.uint8
  spc.ram[0x2E0 + channel] = delay.uint8
  spc.ram[0x47] = 128
  spc.ram[0x5E] = 1
  spc.putWord(0x58, 0xFFA5)
  spc.ram[0x210 + channel] = 255
  spc.putWord(0x300 + channel, 0xFF7F)
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[GuardStart .. GuardEnd]
  spc.prepareStack()
  spc.x = channel.uint8
  spc.psw = PswI or PswB
  spc.execute(ChannelEntry, GainEntry, 40)
  doAssert spc.sp == 0xED and spc.a.int == expected.factor
  spc.execute(GainEntry, ChannelExit, 25)
  doAssert spc.sp == 0xEF and spc.x.int == channel
  doAssert spc.ram[0xC0 + channel].int == expected.counter
  doAssert spc.ram[0x2D0 + channel].int == expected.phase
  doAssert spc.ram[0x5E].int == (if expected.dirty: 129 else: 1)
  doAssert spc.ram[0x321 + channel].int == expectedGain(expected.factor, 255, 255, 255)
  for address in 0 .. 0xEF:
    if address != 0xC0 + channel and address != 0x5E:
      doAssert spc.ram[address] == beforeDp[address]
  for address in GuardStart .. GuardEnd:
    if address != 0x2D0 + channel and address != 0x321 + channel:
      doAssert spc.ram[address] == beforeArrays[address - GuardStart]

proc masterTick(spc: var Spc) =
  ## Verify master countdown, final snap, zero freeze and exact dirty-mask replacement.
  let
    current = spc.word(0x58)
    remaining = spc.ram[0x5A].int
    target = spc.ram[0x5B].int
    step = spc.word(0x5C)
    dirty = spc.ram[0x5E]
    next = max(0, remaining - 1)
    expected = if remaining == 0: current elif next == 0: target * 256
      else: (current + step) and 65535
    before = spc.ram[0 .. 0xEF]
  spc.prepareStack()
  spc.x = 0xA6
  spc.psw = 0
  spc.execute(MasterTickEntry, MasterTickExit, 20)
  doAssert spc.sp == 0xEF and spc.x == 0xA6
  doAssert spc.word(0x58) == expected and spc.ram[0x5A].int == next
  doAssert spc.ram[0x5E] == (if remaining == 0: dirty else: 255'u8)
  for address in 0 .. 0xEF:
    if address notin [0x58, 0x59, 0x5A, 0x5E]:
      doAssert spc.ram[address] == before[address]

proc channelTick(spc: var Spc, channel: int) =
  ## Verify channel accumulation continues through its final tick without snapping.
  let
    current = spc.word(0x300 + channel)
    remaining = spc.ram[0x90 + channel].int
    step = spc.word(0x310 + channel)
    expected = if remaining == 0: current else: (current + step) and 65535
    target = spc.ram[0x320 + channel]
  spc.ram[0xC1 + channel] = 0
  spc.ram[0x47] = 1
  spc.ram[0x5E] = 0
  spc.putWord(0x58, 0xFF7F)
  spc.ram[0x210 + channel] = 255
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[GuardStart .. GuardEnd]
  spc.prepareStack()
  spc.x = channel.uint8
  spc.psw = 0
  spc.execute(ChannelEntry, ChannelExit, 60)
  doAssert spc.sp == 0xEF and spc.x.int == channel
  doAssert spc.word(0x300 + channel) == expected
  doAssert spc.ram[0x90 + channel].int == max(0, remaining - 1)
  doAssert spc.ram[0x320 + channel] == target and spc.word(0x310 + channel) == step
  doAssert spc.ram[0x5E].int == (if remaining == 0: 0 else: 1)
  doAssert spc.ram[0x321 + channel].int == expectedGain(255, 255, 255, expected shr 8)
  for address in 0 .. 0xEF:
    if address notin [0x14, 0x15, 0x16, 0x17, 0x5E, 0x90 + channel]:
      doAssert spc.ram[address] == beforeDp[address]
  for address in GuardStart .. GuardEnd:
    if address notin [0x300 + channel, 0x301 + channel, 0x321 + channel]:
      doAssert spc.ram[address] == beforeArrays[address - GuardStart]

proc checkStereoChain(spc: var Spc, channel: int, master: bool, operand: int) =
  ## Execute a real fade command through channel gain and both ordered DSP writes.
  let opcode = if master: 0xE6 else: 0xEE
  spc.checkCommand(opcode, channel, 0xFFFF, 0x807F, 2, operand, 255)
  spc.ram[0x5E] = 0
  if master:
    spc.masterTick()
    spc.putWord(0x300 + channel, 0xFF7F)
    spc.ram[0x90 + channel] = 0
  else:
    spc.putWord(0x58, 0xFF7F)
  spc.ram[0x210 + channel] = 255
  spc.ram[0xC1 + channel] = 0
  spc.ram[0x91 + channel] = 0
  spc.ram[0x47] = uint8(1 shl (channel div 2))
  spc.ram[0x1A] = 0
  spc.putWord(0x330 + channel, 10 * 256)
  spc.ram[0x351 + channel] = 0
  for index in 0 .. 21:
    spc.ram[0xE73 + index] = uint8(index * index div 2)
  let
    expectedVolume = if master: spc.word(0x300 + channel)
      else: (0x807F + expectedStep(128, operand, 2)) and 65535
    gain = expectedGain(255, spc.ram[0x59].int, 255, expectedVolume shr 8)
    volume = gain * 50 div 256
  var writes: seq[PortWrite]
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address in [0xF2'u16, 0xF3'u16]
    writes.add (address, value)
    false
  spc.prepareStack()
  spc.x = channel.uint8
  spc.psw = 0
  spc.execute(ChannelEntry, ReturnAddress, 200)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.word(0x300 + channel) == expectedVolume
  doAssert spc.ram[0x321 + channel].int == gain
  doAssert writes == @[(0xF2'u16, uint8(channel * 8)), (0xF3'u16, volume.uint8),
    (0xF2'u16, uint8(channel * 8 + 1)), (0xF3'u16, volume.uint8)]
  doAssert spc.word(0x330 + channel) == 10 * 256
  doAssert spc.ram[0x351 + channel] == 0 and spc.ram[0x91 + channel] == 0
  spc.writeHook = silentIo

proc checkImage(image: seq[uint8]): tuple[setters, fades, transitions, masterTicks,
    channelTicks, replacements, factors, modulation, delays, gains, stereoChains: int] =
  ## Run all independent volume matrices against one freshly loaded driver image.
  var spc = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[DriverMap + address]
  spc.writeHook = silentIo
  for opcode in [0xE5, 0xED]:
    for operand in 0 .. 255:
      for voice in 0 ..< 8:
        for oldDuration in [0, 1, 255]:
          for stream in [0x48FF, 0xFFFF]:
            spc.checkCommand(opcode, voice * 2, stream, 0xB47D, operand, 0x6A, oldDuration)
            inc result.setters
  for opcode in [0xE6, 0xEE]:
    for current in 0 .. 255:
      for target in 0 .. 255:
        spc.checkCommand(opcode, ((current xor target) and 7) * 2,
          (if (current + target) mod 2 == 0: 0x48FF else: 0xFFFF),
          current * 256 + ((current * 37 + target) and 255),
          Durations[(current + target) mod Durations.len], target, 255)
        inc result.fades
    for duration in 0 .. 255:
      for target in 0 .. 255:
        spc.checkCommand(opcode, ((duration xor target) and 7) * 2, 0x48FF,
          128 * 256 + ((duration + target) and 255), duration, target, 1)
        inc result.fades
    for current in ByteEdges:
      for target in ByteEdges:
        for duration in Durations:
          for fraction in [0, 127, 255]:
            spc.checkCommand(opcode, 14, 0xFFFF, current * 256 + fraction, duration, target, 255)
            inc result.fades
            let step = expectedStep(current, target, duration)
            for index in 0 .. duration:
              if opcode == 0xE6:
                spc.masterTick()
                inc result.masterTicks
              else:
                spc.channelTick(14)
                inc result.channelTicks
            let expected = if duration == 0: current * 256 + fraction
              elif opcode == 0xE6: target * 256
              else: (current * 256 + fraction + duration * step) and 65535
            doAssert (if opcode == 0xE6: spc.word(0x58) else: spc.word(0x30E)) == expected
            inc result.transitions
  for current in WordEdges:
    for step in WordEdges:
      for remaining in [0, 1, 2, 255]:
        for target in [0, 1, 127, 255]:
          for dirty in [0, 1, 128]:
            spc.putWord(0x58, current)
            spc.ram[0x5A] = remaining.uint8
            spc.ram[0x5B] = target.uint8
            spc.putWord(0x5C, step)
            spc.ram[0x5E] = dirty.uint8
            spc.masterTick()
            inc result.masterTicks
  for opcode in [0xE5, 0xED]:
    for voice in 0 ..< 8:
      for operand in [0, 1, 127, 255]:
        for remaining in [1, 2]:
          spc.checkCommand(opcode, voice * 2, 0x48FF, 0xB47D, operand, 0, remaining)
          inc result.setters
          if opcode == 0xE5:
            spc.masterTick()
            inc result.masterTicks
          else:
            spc.channelTick(voice * 2)
            inc result.channelTicks
          inc result.replacements
  for phase in 0 .. 255:
    for depth in 0 .. 255:
      spc.checkFactor(((phase + depth) and 7) * 2, phase, depth)
      inc result.factors
  for phase in 0 .. 255:
    for depth in 0 .. 255:
      for rate in Rates:
        spc.checkModulation(((phase + depth) and 7) * 2, phase, depth, rate, 0, 0)
        inc result.modulation
  for voice in 0 ..< 8:
    for counter in [0, 1, 127, 254, 255]:
      for delay in [0, 1, 127, 254, 255]:
        for phase in [0, 127, 128, 255]:
          for depth in [0, 1, 127, 255]:
            for rate in [0, 1, 255]:
              spc.checkModulation(voice * 2, phase, depth, rate, counter, delay)
              inc result.delays
  for factor in 0 .. 255:
    for current in 0 .. 255:
      for context in GainContexts:
        spc.checkGain(((factor xor current) and 7) * 2, factor, context[0], context[1], current)
        inc result.gains
  for voice in 0 ..< 8:
    for master in [false, true]:
      for target in [0, 1, 127, 128, 255]:
        spc.checkStereoChain(voice * 2, master, target)
        inc result.stereoChains

proc main() =
  ## Report executed cases on the original and independently rebuilt ROMs.
  for index, image in engineImages("bin/spc_volume_extract"):
    let
      counts = checkImage(image)
      name = if index == 0: "original" else: "rebuilt"
    echo &"{name}: {counts.setters} setters, {counts.fades} fades, {counts.transitions} full transitions, {counts.masterTicks} master ticks, {counts.channelTicks} channel ticks, {counts.replacements} active-fade replacements, {counts.factors} direct factors, {counts.modulation} phase/depth cases, {counts.delays} delay cases, {counts.gains} gain cases and {counts.stereoChains} stereo chains passed"

when isMainModule:
  main()
