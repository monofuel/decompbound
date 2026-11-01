## Independent EB/EC dispatch, shared depth-store, consumer and note-reset checks.
## Only original ROM instructions and synthetic streams/curves are executed.

import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  DispatchEntry = 0x0943'u16
  DepthEntry = 0x0A65'u16
  ChannelEntry = 0x0C40'u16
  NoteEntry = 0x0654'u16
  NoteResetExit = 0x0696'u16
  ReturnAddress = 0x1E00'u16
  GuardStart = 0x0200
  GuardEnd = 0x038F
  GuardByte = 0xA5'u8
  Delays = [0, 1, 127, 255]
  Rates = [0, 1, 127, 128, 255]

type PortWrite = tuple[address: uint16, value: uint8]

proc word(spc: Spc, address: int): int =
  ## Read a little-endian word independently of emulated arithmetic.
  spc.ram[address].int or (spc.ram[address + 1].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Set an authored word modulo sixteen bits.
  spc.ram[address] = uint8(value and 255)
  spc.ram[address + 1] = uint8((value shr 8) and 255)

proc silentIo(address: uint16, value: uint8): bool =
  ## Reject hardware writes outside the explicitly observed stereo chains.
  doAssert false, &"unexpected I/O ${address:04X}=${value:02X}"
  false

proc prepareStack(spc: var Spc) =
  ## Supply a caller return and guards below nested channel/DSP calls.
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E7] = GuardByte
  spc.ram[0x1F2] = GuardByte
  spc.sp = 0xEF

proc execute(spc: var Spc, entry, stop: uint16, budget = 80) =
  ## Execute unchanged instructions with bounded stack and instruction use.
  spc.pc = entry
  var steps = 0
  while spc.pc != stop:
    doAssert steps < budget, &"entry ${entry:04X} exceeded its instruction budget"
    doAssert spc.sp in 0xE8'u8 .. 0xF1'u8
    spc.step()
    inc steps
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E7] == GuardByte and spc.ram[0x1F2] == GuardByte
  doAssert not spc.stopped

proc checkCommand(spc: var Spc, opcode, channel, stream, delay, rate, depth,
    counter, phase: int) =
  ## Verify exact EB/EC consumption and reconfiguration without restarting phase or delay.
  let pointer = 0x30 + channel
  for address in 0 .. 0xEF:
    spc.ram[address] = uint8((address * 37 + 11) and 255)
  for address in GuardStart .. GuardEnd:
    spc.ram[address] = uint8((address * 53 + 29) and 255)
  spc.putWord(pointer, stream)
  spc.ram[0xC0 + channel] = counter.uint8
  spc.ram[0xC1 + channel] = uint8(if opcode == 0xEB: depth xor 255 else: depth)
  spc.ram[0x2D0 + channel] = phase.uint8
  spc.ram[0x2D1 + channel] = 0x6A
  spc.ram[0x2E0 + channel] = 0xC3
  for index, value in [delay, rate, depth, 0xE1]:
    spc.ram[(stream + index) and 65535] = value.uint8
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[GuardStart .. GuardEnd]
    configuring = opcode == 0xEB
  spc.prepareStack()
  spc.a = opcode.uint8
  spc.x = channel.uint8
  spc.y = 0xA6
  spc.psw = PswI or PswB or PswC
  spc.execute(DispatchEntry, ReturnAddress)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.word(pointer) == ((stream + (if configuring: 3 else: 0)) and 65535)
  doAssert spc.a.int == (if configuring: depth else: 0)
  doAssert spc.y.int == (if configuring: depth else: 0)
  doAssert spc.ram[0xC1 + channel].int == (if configuring: depth else: 0)
  doAssert spc.ram[0xC0 + channel].int == counter
  doAssert spc.ram[0x2D0 + channel].int == phase
  doAssert spc.ram[0x2D1 + channel].int == (if configuring: rate else: 0x6A)
  doAssert spc.ram[0x2E0 + channel].int == (if configuring: delay else: 0xC3)
  for address in 0 .. 0xEF:
    if address != 0xC1 + channel and not (configuring and address in pointer .. pointer + 1):
      doAssert spc.ram[address] == beforeDp[address], &"command changed DP ${address:02X}"
  for address in GuardStart .. GuardEnd:
    if not (configuring and address in [0x2D1 + channel, 0x2E0 + channel]):
      doAssert spc.ram[address] == beforeArrays[address - GuardStart]
  for index, value in [delay, rate, depth, 0xE1]:
    doAssert spc.ram[(stream + index) and 65535].int == value
  doAssert (spc.psw and (PswI or PswB or PswP)) == (PswI or PswB)

proc checkSharedStore(spc: var Spc, channel, value: int) =
  ## Prove A65 is an arbitrary-A depth store followed by RET, not a no-op alias.
  spc.ram[0xC1 + channel] = uint8(value xor 255)
  let before = spc.ram[0 .. 0xEF]
  spc.prepareStack()
  spc.a = value.uint8
  spc.y = 0xA6
  spc.x = channel.uint8
  spc.psw = PswI or PswB or PswC or PswH or PswV or PswN or PswZ
  let flags = spc.psw
  spc.execute(DepthEntry, ReturnAddress, 3)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.a.int == value and spc.y == 0xA6 and spc.psw == flags
  doAssert spc.ram[0xC1 + channel].int == value
  for address in 0 .. 0xEF:
    if address != 0xC1 + channel:
      doAssert spc.ram[address] == before[address]

proc modulation(phase, depth, rate, counter, delay: int):
    tuple[phase, counter, factor: int, dirty: bool] =
  ## Model delayed unsigned-triangle modulation independently of byte instructions.
  result = (phase, counter, 255, false)
  if depth == 0:
    return
  if counter != delay:
    result.counter = (counter + 1) and 255
    return
  result.dirty = true
  result.phase = if phase >= 128 and depth == 255: 128 else: (phase + rate) and 255
  let triangle = if result.phase < 128: 2 * result.phase else: 511 - 2 * result.phase
  result.factor = 255 - depth * triangle div 256

proc gain(factor, master, channelFactor, volume: int): int =
  ## Preserve each distinct fixed-point truncation before squaring the channel magnitude.
  let
    first = factor * master div 256
    second = first * channelFactor div 256
    third = second * volume div 256
  third * third div 256

proc checkStereoChain(spc: var Spc, opcode, channel, delay, rate, depth,
    counter, phase: int) =
  ## Feed a real EB/EC command through C40 and capture both ordered stereo writes.
  spc.checkCommand(opcode, channel, 0xFFFF, delay, rate, depth, counter, phase)
  let
    effectiveDepth = if opcode == 0xEB: depth else: 0
    expected = modulation(phase, effectiveDepth, rate, counter, delay)
    voice = channel div 2
    master = if voice mod 2 == 0: 127 else: 255
    channelFactor = if voice mod 3 == 0: 128 else: 255
    volume = if voice mod 2 == 0: 127 else: 255
    expectedGain = gain(expected.factor, master, channelFactor, volume)
    portVolume = expectedGain * 50 div 256
    mask = 1 shl voice
  spc.ram[0x90 + channel] = 0
  spc.ram[0x91 + channel] = 0
  spc.ram[0x47] = mask.uint8
  spc.ram[0x1A] = 0
  # Active modulation must create the dirty bit itself. Other paths consume
  # a caller's existing dirty bit so their recomputed gain also reaches DSP.
  spc.ram[0x5E] = (if expected.dirty: 0 else: mask).uint8
  spc.putWord(0x58, master * 256 + 127)
  spc.ram[0x210 + channel] = channelFactor.uint8
  spc.putWord(0x300 + channel, volume * 256 + 127)
  spc.ram[0x321 + channel] = 0xA6
  spc.putWord(0x330 + channel, 10 * 256)
  spc.ram[0x351 + channel] = 0
  for index in 0 .. 21:
    spc.ram[0xE73 + index] = uint8(index * index div 2)
  var writes: seq[PortWrite]
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address in [0xF2'u16, 0xF3'u16]
    writes.add (address, value)
    false
  spc.prepareStack()
  spc.x = channel.uint8
  spc.psw = 0
  spc.execute(ChannelEntry, ReturnAddress, 220)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.ram[0xC0 + channel].int == expected.counter
  doAssert spc.ram[0x2D0 + channel].int == expected.phase
  doAssert spc.ram[0xC1 + channel].int == effectiveDepth
  doAssert spc.ram[0x5E].int == mask
  doAssert spc.ram[0x321 + channel].int == expectedGain
  doAssert writes == @[(0xF2'u16, uint8(voice * 16)), (0xF3'u16, portVolume.uint8),
    (0xF2'u16, uint8(voice * 16 + 1)), (0xF3'u16, portVolume.uint8)]
  doAssert spc.word(0x300 + channel) == volume * 256 + 127
  doAssert spc.word(0x330 + channel) == 10 * 256 and spc.ram[0x351 + channel] == 0
  spc.writeHook = silentIo

proc checkNoteReset(spc: var Spc, channel, noteByte, mask, blocked, phase,
    counter: int): bool =
  ## Execute only the bounded non-instrument note path through its phase/counter resets.
  doAssert noteByte < 0xCA # Instrument-setting events call a broader handler and are excluded.
  let
    accepted = noteByte < 0xC8 and (blocked and mask) == 0
    sourceBit = (phase xor counter) and 1
  for address in 0 .. 0xEF:
    spc.ram[address] = uint8((address * 37 + 11) and 255)
  for address in GuardStart .. GuardEnd:
    spc.ram[address] = uint8((address * 53 + 29) and 255)
  for index in 0 .. 15:
    spc.ram[0x100 + index] = 0xA5
  spc.ram[0x1A] = blocked.uint8
  spc.ram[0x47] = mask.uint8
  spc.ram[0x50] = 3
  spc.ram[0x45] = 0x5A
  spc.ram[0x5E] = 0xA5
  spc.ram[0xC0 + channel] = counter.uint8
  spc.ram[0xC1 + channel] = 127
  spc.ram[0xB0 + channel] = 0xA6
  spc.ram[0x2D0 + channel] = phase.uint8
  spc.ram[0x2D1 + channel] = 255
  spc.ram[0x2E0 + channel] = 128
  spc.ram[0x2F0 + channel] = 7
  spc.ram[0x2B1 + channel] = uint8(sourceBit or 0xA0)
  spc.ram[0x381 + channel] = 0x91
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[GuardStart .. GuardEnd]
    beforeSlots = spc.ram[0x100 .. 0x10F]
  spc.prepareStack()
  spc.a = 0x6A
  spc.y = noteByte.uint8
  spc.x = channel.uint8
  spc.psw = PswI or PswB
  spc.execute(NoteEntry, (if accepted: NoteResetExit else: ReturnAddress), 45)
  doAssert spc.sp == (if accepted: 0xEF else: 0xF1) and spc.x.int == channel
  doAssert spc.ram[0xC0 + channel].int == (if accepted: 0 else: counter)
  doAssert spc.ram[0x2D0 + channel].int == (if accepted: 0 else: phase)
  doAssert spc.ram[0xC1 + channel] == 127
  doAssert spc.ram[0x2D1 + channel] == 255 and spc.ram[0x2E0 + channel] == 128
  if accepted:
    doAssert spc.ram[0x361 + channel].int == (((noteByte and 127) + 10) and 255)
    doAssert spc.ram[0x360 + channel] == 0x91
    doAssert spc.ram[0x2A0 + channel].int == sourceBit * 128
    doAssert spc.ram[0xB0 + channel] == 0 and spc.ram[0x100 + channel] == 0
    doAssert spc.ram[0x5E].int == (0xA5 or mask)
    doAssert spc.ram[0x45].int == (0x5A or mask)
  for address in 0 .. 0xEF:
    if not (accepted and address in [0xC0 + channel, 0xB0 + channel, 0x45, 0x5E]):
      doAssert spc.ram[address] == beforeDp[address]
  for address in GuardStart .. GuardEnd:
    if not (accepted and address in [0x360 + channel, 0x361 + channel, 0x2A0 + channel, 0x2D0 + channel]):
      doAssert spc.ram[address] == beforeArrays[address - GuardStart]
  for index in 0 .. 15:
    if not (accepted and index == channel):
      doAssert spc.ram[0x100 + index] == beforeSlots[index]
  result = accepted

proc checkImage(image: seq[uint8]): tuple[configurations, disables, directStores,
    stereoChains, acceptedNotes, rejectedNotes: int] =
  ## Run independent command and bounded reset evidence on one driver image.
  var spc = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[DriverMap + address]
  spc.writeHook = silentIo
  for depth in 0 .. 255:
    for delay in Delays:
      for rate in Rates:
        for voice in 0 ..< 8:
          for stream in [0x48FE, 0x48FF, 0xFFFF]:
            spc.checkCommand(0xEB, voice * 2, stream, delay, rate, depth,
              delay xor depth, rate xor depth)
            inc result.configurations
  for depth in 0 .. 255:
    for voice in 0 ..< 8:
      for stream in [0x48FF, 0xFFFF]:
        spc.checkCommand(0xEC, voice * 2, stream, 0xA6, 0xC3, depth,
          depth xor 255, depth)
        inc result.disables
  for value in 0 .. 255:
    for voice in 0 ..< 8:
      spc.checkSharedStore(voice * 2, value)
      inc result.directStores
  for voice in 0 ..< 8:
    for depth in [0, 1, 127, 255]:
      for phase in [0, 1, 127, 128, 255]:
        for counter in [0, 1, 255]:
          for delay in [0, 1, 255]:
            for rate in [0, 1, 127, 255]:
              spc.checkStereoChain(0xEB, voice * 2, delay, rate, depth, counter, phase)
              inc result.stereoChains
    for phase in [0, 127, 128, 255]:
      for counter in [0, 255]:
        spc.checkStereoChain(0xEC, voice * 2, 0xA6, 0xC3, 255, counter, phase)
        inc result.stereoChains
  for voice in 0 ..< 8:
    for noteByte in [0, 1, 127, 128, 167, 199, 200, 201]:
      for mask in [0, 1, 128]:
        for blocked in [0, 1, 128, 255]:
          for phase in [0, 127, 128, 255]:
            for counter in [0, 1, 255]:
              if spc.checkNoteReset(voice * 2, noteByte, mask, blocked, phase, counter):
                inc result.acceptedNotes
              else:
                inc result.rejectedNotes

proc main() =
  ## Report actual original/rebuilt command, consumer and bounded note-reset cases.
  for index, image in engineImages("bin/spc_modulation_commands_extract"):
    let
      counts = checkImage(image)
      name = if index == 0: "original" else: "rebuilt"
    echo &"{name}: {counts.configurations} EB configurations, {counts.disables} EC disables, {counts.directStores} direct A65 stores, {counts.stereoChains} stereo chains, {counts.acceptedNotes} accepted resets and {counts.rejectedNotes} rejected/non-note cases passed"

when isMainModule:
  main()
