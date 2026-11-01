## Independent block loading, zero-word continuation and first-token lifecycle checks.
## Tiny structural blocks and sequence words are authored here, never extracted assets.

import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  ReaderEntry = 0x081A'u16
  BlockEntry = 0x0841'u16
  BlockExit = 0x0871'u16
  TokenExit = 0x089E'u16
  ZeroEntry = 0x07EA'u16
  SelectorEntry = 0x0772'u16
  SelectorHighExit = 0x079A'u16
  DispatchEntry = 0x0943'u16
  ModeEntry = 0x0B7F'u16
  ModePrefixEntry = 0x0B7E'u16
  FlushEntry = 0x0546'u16
  FlushExit = 0x0568'u16
  FlushSuppressedExit = 0x0543'u16
  ReturnAddress = 0x1E00'u16
  GuardByte = 0xA5'u8
  Record = [23, 81, 162, 67, 132, 53]
  ActiveMasks = [0, 1, 0x55, 0x80, 0xFF]

type
  PortWrite = tuple[address: uint16, value: uint8]
  Observation = object
    writes: seq[PortWrite]
    reads: int

proc word(spc: Spc, address: int): int =
  ## Read a structural word with sixteen-bit address wrap.
  spc.ram[address and 65535].int or (spc.ram[(address + 1) and 65535].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Write an authored structural word with address wrap.
  spc.ram[address and 65535] = uint8(value and 255)
  spc.ram[(address + 1) and 65535] = uint8((value shr 8) and 255)

proc prepare(spc: var Spc) =
  ## Guard unrelated RAM and supply the external caller's authentic return frame.
  for address in 0 .. 0xEF:
    spc.ram[address] = uint8((address * 37 + 11) and 255)
  for address in 0x200 .. 0x4BF:
    spc.ram[address] = uint8((address * 53 + 29) and 255)
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E7] = GuardByte
  spc.ram[0x1F2] = GuardByte
  spc.sp = 0xEF
  spc.psw = PswI or PswB or PswH or PswV or PswC
  spc.iplEnabled = false

proc execute(spc: var Spc, entry, stop: uint16, budget: int): Observation =
  ## Run unmodified code with observed hardware accesses and guarded native stack use.
  var observed: Observation
  spc.readHook = proc(address: uint16): int =
    inc observed.reads
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    observed.writes.add (address, value)
    false
  spc.pc = entry
  var instructions = 0
  while spc.pc != stop:
    doAssert instructions < budget, &"lifecycle ${entry:04X} stalled at ${spc.pc:04X}"
    doAssert spc.sp in 0xE8'u8 .. 0xF1'u8
    spc.step()
    inc instructions
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E7] == GuardByte and spc.ram[0x1F2] == GuardByte
  doAssert not spc.stopped
  spc.readHook = nil
  spc.writeHook = nil
  result = observed

proc blockWords(activeMask, low: int): array[8, int] =
  ## Give active channels distinct authored cursors; inactive cursors retain a nonzero low byte.
  for voice in 0 ..< 8:
    result[voice] = if (activeMask and (1 shl voice)) != 0: 0x5000 + voice * 256 + low
      else: 0xA5

proc setupBlock(spc: var Spc, address: int, cursors: array[8, int],
    zeroDefaults, inhibit: int) =
  ## Install a sixteen-byte block, existing instrument selections and a synthetic default record.
  for voice, cursor in cursors:
    spc.putWord(address + voice * 2, cursor)
    spc.ram[0x211 + voice * 2] =
      (if (zeroDefaults and (1 shl voice)) != 0: 0 else: 20 + voice).uint8
  spc.ram[0x1A] = inhibit.uint8
  spc.ram[0x48] = 0xFF
  spc.ram[0x49] = 0xA5
  for index, value in Record:
    spc.ram[0x6E00 + index] = value.uint8

proc checkLoaded(spc: Spc, cursors: array[8, int], beforeDp,
    beforeArrays: seq[uint8], zeroDefaults, inhibit: int, writes: seq[PortWrite]) =
  ## Verify all cursor/counter writes and default initialization, including inactive channels.
  var expectedWrites: seq[PortWrite]
  var noiseMask = 0xA5
  for voice, cursor in cursors:
    let
      channel = voice * 2
      defaultCall = (cursor shr 8) != 0 and (zeroDefaults and (1 shl voice)) != 0
      enabled = defaultCall and (inhibit and (1 shl voice)) == 0
    doAssert spc.word(0x30 + channel) == cursor
    doAssert spc.ram[0x80 + channel] == 0
    doAssert spc.ram[0x90 + channel] == 0 and spc.ram[0x91 + channel] == 0
    doAssert spc.ram[0x70 + channel] == 1
    doAssert spc.ram[0x70 + channel + 1] == beforeDp[0x70 + channel + 1]
    doAssert spc.ram[0x80 + channel + 1] == beforeDp[0x80 + channel + 1]
    doAssert spc.ram[0x211 + channel] == beforeArrays[0x211 + channel - 0x200]
    if enabled:
      doAssert spc.ram[0x220 + channel].int == Record[5]
      doAssert spc.ram[0x221 + channel].int == Record[4]
      noiseMask = noiseMask and (255 xor (1 shl voice))
      for index in 0 ..< 4:
        expectedWrites.add (0xF2'u16, uint8(voice * 16 + 4 + index))
        expectedWrites.add (0xF3'u16, Record[index].uint8)
    else:
      doAssert spc.ram[0x220 + channel] == beforeArrays[0x220 + channel - 0x200]
      doAssert spc.ram[0x221 + channel] == beforeArrays[0x221 + channel - 0x200]
  doAssert writes == expectedWrites
  doAssert spc.ram[0x48] == 0xFF and spc.ram[0x49].int == noiseMask
  for address in 0x200 .. 0x4BF:
    let channel = address - 0x220
    let changed = channel in 0 .. 15 and
      (cursors[channel div 2] shr 8) != 0 and
      (zeroDefaults and (1 shl (channel div 2))) != 0 and
      (inhibit and (1 shl (channel div 2))) == 0
    if not changed:
      doAssert spc.ram[address] == beforeArrays[address - 0x200],
        &"block loader modified unrelated field ${address:04X}"

proc checkBlock(spc: var Spc, blockAddress, stream, activeMask, zeroDefaults,
    inhibit, low: int, direct: bool) =
  ## Execute either the real reader-to-block path or the direct block-entry boundary.
  spc.prepare()
  let cursors = blockWords(activeMask, low)
  spc.setupBlock(blockAddress, cursors, zeroDefaults, inhibit)
  spc.putWord(0x40, stream)
  spc.putWord(stream, blockAddress)
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[0x200 .. 0x4BF]
  spc.a = uint8(blockAddress and 255)
  spc.y = uint8(blockAddress shr 8)
  spc.x = 0xA6
  let observed = spc.execute((if direct: BlockEntry else: ReaderEntry), BlockExit, 1000)
  doAssert observed.reads == 0
  doAssert spc.sp == 0xEF and spc.x == 16 and spc.a == 1
  doAssert spc.word(0x16) == blockAddress and spc.ram[0x47] == 0
  doAssert spc.word(0x40) == (if direct: stream else: (stream + 2) and 65535)
  spc.checkLoaded(cursors, beforeDp, beforeArrays, zeroDefaults, inhibit, observed.writes)
  for address in 0 .. 0xEF:
    let channelCounter = (address in 0x70 .. 0x7F and address mod 2 == 0) or
      (address in 0x80 .. 0x8F and address mod 2 == 0) or address in 0x90 .. 0x9F
    let scratch = address in [0x14, 0x15, 0x16, 0x17, 0x47, 0x49] or
      address in 0x30 .. 0x3F or (not direct and address in 0x40 .. 0x41)
    if not channelCounter and not scratch:
      doAssert spc.ram[address] == beforeDp[address], &"block changed DP ${address:02X}"

proc checkZero(spc: var Spc, stream, fallback, inhibit, oldActive, oldCommand,
    oldMask, seed: int, direct: bool, mode = -1) =
  ## Follow the actual forced-A-zero $07EA path through selection setup and RET.
  spc.prepare()
  # $2E48/$2E49 is the original selector-zero pointer table entry, not code.
  spc.putWord(0x2E48, fallback)
  spc.putWord(0x40, stream)
  spc.putWord(stream, 0)
  spc.ram[0x1A] = inhibit.uint8
  spc.ram[0x04] = oldActive.uint8
  spc.ram[0x08] = oldCommand.uint8
  spc.ram[0x46] = oldMask.uint8
  if mode >= 0:
    spc.ram[0x1B] = mode.uint8
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[0x200 .. 0x4BF]
  spc.a = seed.uint8
  spc.y = uint8(seed xor 255)
  spc.x = 0xA6
  let observed = spc.execute((if direct: ZeroEntry else: ReaderEntry), ReturnAddress, 80)
  doAssert observed.reads == 0 and observed.writes == @[(0xF4'u16, 0'u8)]
  doAssert spc.sp == 0xF1 and spc.x == 0
  doAssert spc.a.int == (inhibit xor 255) and spc.y.int == (fallback shr 8)
  doAssert spc.ram[0x04] == 0 and spc.ram[0x08].int == oldCommand
  doAssert spc.word(0x40) == fallback and spc.ram[0x0C] == 2
  doAssert spc.ram[0x46].int == (oldMask or (inhibit xor 255))
  for address in [0x491, 0x4B1, 0x4B5]:
    doAssert spc.ram[address] == 0
  for address in 0 .. 0xEF:
    if address notin [0x04, 0x0C, 0x40, 0x41, 0x46]:
      doAssert spc.ram[address] == beforeDp[address], &"zero continuation changed DP ${address:02X}"
  for address in 0x200 .. 0x4BF:
    if address notin [0x491, 0x4B1, 0x4B5]:
      doAssert spc.ram[address] == beforeArrays[address - 0x200]

proc checkFirstToken(spc: var Spc, voice, cursor, token, control, oldCounter: int) =
  ## Follow global controls into an actual block and the chosen channel's first token.
  spc.prepare()
  let
    blockAddress = 0x4800
    stream = 0x4C00
    destination = 0x4D00
    channel = voice * 2
    nextCounter = (oldCounter - 1) and 255
    counter = if nextCounter >= 128: control else: nextCounter
    selectedStream = if counter == 0: stream + 8 else: destination
  var cursors = blockWords(0, 0)
  cursors[voice] = cursor
  spc.setupBlock(blockAddress, cursors, 0, 0xFF)
  spc.putWord(stream, 0x80)
  spc.putWord(stream + 2, 0x81)
  spc.putWord(stream + 4, control)
  spc.putWord(stream + 6, destination)
  spc.putWord(stream + 8, blockAddress)
  spc.putWord(destination, blockAddress)
  spc.putWord(0x40, stream)
  spc.ram[0x42] = oldCounter.uint8
  spc.ram[0x1B] = 0x6A
  spc.ram[cursor] = token.uint8
  let
    beforeArrays = spc.ram[0x200 .. 0x4BF]
    beforeDp = spc.ram[0 .. 0xEF]
  spc.x = 0xA6
  let observed = spc.execute(ReaderEntry, TokenExit, 800)
  doAssert observed.reads == 0 and observed.writes.len == 0
  doAssert spc.sp == 0xEF and spc.x.int == channel
  doAssert spc.a.int == token and spc.y.int == token
  doAssert spc.word(0x40) == selectedStream + 2
  doAssert spc.ram[0x42].int == counter and spc.ram[0x1B] == 0
  doAssert spc.ram[0x44].int == channel and spc.ram[0x47].int == (1 shl voice)
  doAssert spc.ram[0x5E] == 0
  for index in 0 ..< 8:
    let offset = index * 2
    doAssert spc.word(0x30 + offset) ==
      (if index == voice: (cursor + 1) and 65535 else: cursors[index])
    doAssert spc.ram[0x70 + offset].int == (if index == voice: 0 else: 1)
    doAssert spc.ram[0x80 + offset] == 0
    doAssert spc.ram[0x90 + offset] == 0 and spc.ram[0x91 + offset] == 0
    doAssert spc.ram[0x71 + offset] == beforeDp[0x71 + offset]
    doAssert spc.ram[0x81 + offset] == beforeDp[0x81 + offset]
  doAssert spc.ram[0x200 .. 0x4BF] == beforeArrays
  for address in 0 .. 0xEF:
    let channelCounter = (address in 0x70 .. 0x7F and address mod 2 == 0) or
      (address in 0x80 .. 0x8F and address mod 2 == 0) or address in 0x90 .. 0x9F
    let scratch = address in [0x16, 0x17, 0x1B, 0x42, 0x44, 0x47, 0x5E] or
      address in 0x30 .. 0x41
    if not channelCounter and not scratch:
      doAssert spc.ram[address] == beforeDp[address],
        &"control-to-token path changed DP ${address:02X}"

proc tableValue(selector, variant: int): int =
  ## Generate distinct synthetic selector pointers with explicit boundary values.
  if variant == 0:
    return (0x5000 + selector * 257) and 65535
  case selector
  of 0: 0
  of 1: 1
  of 126: 0x50FF
  of 127: 0xFFFF
  else: (0xA300 + selector * 73) and 65535

proc checkSelector(spc: var Spc, selector, inhibit, queued, seed, variant: int) =
  ## Check positive selection and the bounded high-bit branch before alternate selection.
  spc.prepare()
  for index in 0 .. 127:
    spc.putWord(0x2E48 + index * 2, tableValue(index, variant))
  spc.ram[0x04] = uint8(selector xor 255)
  spc.ram[0x08] = 0xA6
  spc.ram[0x0C] = seed.uint8
  spc.ram[0x1A] = inhibit.uint8
  spc.ram[0x46] = queued.uint8
  spc.putWord(0x40, 0xB47D)
  spc.ram[0x491] = seed.uint8
  spc.ram[0x4B1] = uint8(seed xor 0x5A)
  spc.ram[0x4B5] = uint8(seed xor 0xA5)
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[0x200 .. 0x4BF]
    beforeTable = spc.ram[0x2E48 .. 0x2F47]
    high = selector >= 128
  spc.a = selector.uint8
  spc.x = 0xA6
  spc.y = 0xC3
  let observed = spc.execute(SelectorEntry,
    (if high: SelectorHighExit else: ReturnAddress), 35)
  doAssert observed.reads == 0 and observed.writes.len == 0
  doAssert spc.ram[0x04].int == selector and spc.ram[0x08] == 0xA6
  if high:
    # $079A is a real alternate path, not RET; leave its continuation unexecuted.
    doAssert spc.sp == 0xEF and spc.a.int == selector
    doAssert spc.x == 0xA6 and spc.y == 0xC3
  else:
    doAssert spc.sp == 0xF1 and spc.x.int == selector * 2
    doAssert spc.a.int == (inhibit xor 255)
    doAssert spc.y.int == (tableValue(selector, variant) shr 8)
    doAssert spc.word(0x40) == tableValue(selector, variant)
    doAssert spc.ram[0x0C] == 2
    doAssert spc.ram[0x46].int == (queued or (inhibit xor 255))
    for address in [0x491, 0x4B1, 0x4B5]:
      doAssert spc.ram[address] == 0
  for address in 0 .. 0xEF:
    let changed = address == 0x04 or
      (not high and address in [0x0C, 0x40, 0x41, 0x46])
    if not changed:
      doAssert spc.ram[address] == beforeDp[address]
  for address in 0x200 .. 0x4BF:
    if high or address notin [0x491, 0x4B1, 0x4B5]:
      doAssert spc.ram[address] == beforeArrays[address - 0x200]
  doAssert spc.ram[0x2E48 .. 0x2F47] == beforeTable

proc checkMode(spc: var Spc, channel, stream, input, inhibit, queued, seed: int,
    prefix, dispatch: bool) =
  ## Verify FE's full shared tail and FD's wrapping INC-A prefix without interpreting the mode.
  spc.prepare()
  let
    pointer = 0x30 + channel
    expectedMode = if dispatch: (if prefix: 1 else: 0)
      elif prefix: (input + 1) and 255 else: input
  spc.putWord(pointer, stream)
  spc.ram[stream] = 0xA6
  spc.ram[(stream + 1) and 65535] = 0xC3
  spc.ram[0x04] = uint8(seed xor 0xA5)
  spc.ram[0x08] = uint8(seed xor 0x5A)
  spc.ram[0x0C] = seed.uint8
  spc.ram[0x1A] = inhibit.uint8
  spc.ram[0x1B] = 0x6A
  spc.ram[0x46] = queued.uint8
  spc.putWord(0x40, 0xB47D)
  spc.ram[0x491] = seed.uint8
  spc.ram[0x4B1] = uint8(seed xor 0x5A)
  spc.ram[0x4B5] = uint8(seed xor 0xA5)
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[0x200 .. 0x4BF]
  spc.a = uint8(if dispatch: (if prefix: 0xFD else: 0xFE) else: input)
  spc.x = channel.uint8
  spc.y = 0xA5
  let entry = if dispatch: DispatchEntry elif prefix: ModePrefixEntry else: ModeEntry
  let observed = spc.execute(entry, ReturnAddress, 45)
  doAssert observed.reads == 0 and observed.writes.len == 0
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.y.int == (if dispatch: 0 else: 0xA5)
  doAssert spc.a.int == (inhibit xor 255)
  doAssert spc.ram[0x1B].int == expectedMode
  doAssert spc.ram[0x46].int == (queued or (inhibit xor 255))
  doAssert spc.word(pointer) == stream
  doAssert spc.ram[stream] == 0xA6 and spc.ram[(stream + 1) and 65535] == 0xC3
  for address in [0x491, 0x4B1, 0x4B5]:
    doAssert spc.ram[address] == 0
  for address in 0 .. 0xEF:
    if address notin [0x1B, 0x46]:
      doAssert spc.ram[address] == beforeDp[address]
  for address in 0x200 .. 0x4BF:
    if address notin [0x491, 0x4B1, 0x4B5]:
      doAssert spc.ram[address] == beforeArrays[address - 0x200]

proc checkFlush(spc: var Spc) =
  ## Observe only the first real queued KOFF descriptor or the mode-suppressed branch.
  doAssert spc.ram[0xEA7 + 10] == 0x5C
  doAssert spc.ram[0xEB1 + 10] == 0x46
  let
    queued = spc.ram[0x46]
    mode = spc.ram[0x1B]
    before = spc.ram[0 .. 0xEF]
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E7] = GuardByte
  spc.ram[0x1F2] = GuardByte
  spc.sp = 0xEF
  spc.a = 0xA6
  spc.x = 0xC3
  spc.y = 0x5A
  let observed = spc.execute(FlushEntry,
    (if mode == 0: FlushExit else: FlushSuppressedExit), 20)
  doAssert spc.sp == 0xEF and observed.reads == 0
  if mode == 0:
    doAssert observed.writes == @[(0xF2'u16, 0x5C'u8), (0xF3'u16, queued)]
  else:
    # Stop before $0543's JMP; this does not establish later phase cadence.
    doAssert observed.writes.len == 0
  doAssert spc.ram[0 .. 0xEF] == before

proc checkImage(image: seq[uint8]): tuple[blocks, defaults, zeros, forcedZeros,
    firstTokens, zeroMaskPairs, selectors, directModes, prefixModes,
    dispatchedModes, flushContexts: int] =
  ## Verify lifecycle continuations without patching driver returns or executing game scripts.
  var spc = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[DriverMap + address]
  for activeMask in ActiveMasks:
    for low in [0, 255]:
      for direct in [false, true]:
        for stream in [0x4C00, 0x4CFF, 0xFFFF]:
          for blockAddress in [0x4800, 0x48FF]:
            spc.checkBlock(blockAddress, stream, activeMask, 0, 0xFF, low, direct)
            inc result.blocks
        for blockAddress in [0xFFF8, 0xFFFF]:
          spc.checkBlock(blockAddress, 0x4C00, activeMask, 0, 0xFF, low, direct)
          inc result.blocks
  for activeMask in ActiveMasks:
    for zeroDefaults in [0, 1, 0x55, 0x80, 0xFF]:
      for inhibit in [0, 1, 0x55, 0xFF]:
        spc.checkBlock(0x4800, 0x4C00, activeMask, zeroDefaults, inhibit, 255, false)
        inc result.defaults
  for stream in [0x4C00, 0x4CFF, 0xFFFE, 0xFFFF]:
    for fallback in [0, 1, 0x5000, 0xFFFF]:
      for inhibit in [0, 1, 0x55, 0xFF]:
        for active in [0, 1, 128, 255]:
          for command in [0, 1, 128, 255]:
            for mask in [0, 0x55, 0xFF]:
              spc.checkZero(stream, fallback, inhibit, active, command, mask, 0xA6, false)
              inc result.zeros
  for fallback in [0, 1, 0x5000, 0xFFFF]:
    for inhibit in [0, 1, 0x55, 0xFF]:
      for seed in [0, 1, 127, 255]:
        spc.checkZero(0x4C00, fallback, inhibit, 255, 128, 0x55, seed, true)
        inc result.forcedZeros
  for voice in 0 ..< 8:
    for cursor in [0x5000, 0x50FF, 0xFFFF]:
      for token in [1, 127, 128, 199, 224, 255]:
        for control in [1, 2, 127, 255]:
          for oldCounter in [0, 1, 2, 127, 128, 129, 255]:
            spc.checkFirstToken(voice, cursor, token, control, oldCounter)
            inc result.firstTokens
  for inhibit in 0 .. 255:
    for queued in 0 .. 255:
      spc.checkZero(0x4C00, 0x50FF, inhibit, 255, 128, queued,
        inhibit xor queued, true)
      inc result.zeroMaskPairs
  for selector in 0 .. 255:
    for inhibit in [0, 1, 0x55, 0xFF]:
      for queued in [0, 0x55, 0x80, 0xFF]:
        for seed in [0, 1, 255]:
          for variant in [0, 1]:
            spc.checkSelector(selector, inhibit, queued, seed, variant)
            inc result.selectors
  for input in 0 .. 255:
    for inhibit in [0, 1, 0x55, 0xFF]:
      for queued in [0, 1, 0x80, 0xFF]:
        for seed in [0, 1, 255]:
          spc.checkMode(6, 0x4C00, input, inhibit, queued, seed, false, false)
          inc result.directModes
  for input in [0, 1, 127, 128, 254, 255]:
    for inhibit in [0, 1, 0x55, 0xFF]:
      for queued in [0, 1, 0x80, 0xFF]:
        for seed in [0, 1, 255]:
          spc.checkMode(6, 0x4C00, input, inhibit, queued, seed, true, false)
          inc result.prefixModes
  for prefix in [false, true]:
    for voice in 0 ..< 8:
      for stream in [0x48FF, 0xFFFF]:
        for inhibit in [0, 1, 0x55, 0xFF]:
          for queued in [0, 1, 0x80, 0xFF]:
            for seed in [0, 1, 255]:
              spc.checkMode(voice * 2, stream, 0xA6, inhibit, queued, seed, prefix, true)
              inc result.dispatchedModes
  for queued in 0 .. 255:
    let inhibit = (queued * 73) and 255
    for mode in [0, 1, 128]:
      spc.checkZero(0x4C00, 0x5000, inhibit, 255, 128, queued, 0xA6, true, mode)
      spc.checkFlush()
      inc result.flushContexts
      spc.checkMode(6, 0x4C00, mode, inhibit, queued, 255, false, false)
      spc.checkFlush()
      inc result.flushContexts
      let input = (mode - 1) and 255
      spc.checkMode(6, 0x4C00, input, inhibit, queued, 255, true, false)
      spc.checkFlush()
      inc result.flushContexts
    for prefix in [false, true]:
      spc.checkMode(6, 0xFFFF, 0xA6, inhibit, queued, 255, prefix, true)
      spc.checkFlush()
      inc result.flushContexts

proc main() =
  ## Report actual bounded original/rebuilt lifecycle cases and their hardware effects.
  for index, image in engineImages("bin/spc_sequence_lifecycle_extract"):
    let
      counts = checkImage(image)
      name = if index == 0: "original" else: "rebuilt"
    echo &"{name}: {counts.blocks} block loads, {counts.defaults} default-initialization cases, {counts.zeros} zero-word exits, {counts.forcedZeros} direct forced-zero exits and {counts.firstTokens} control-to-first-token paths passed"
    echo &"{name}: {counts.zeroMaskPairs} exhaustive stop-mask pairs, {counts.selectors} selector cases, {counts.directModes} direct FE-tail modes, {counts.prefixModes} direct FD-prefix modes, {counts.dispatchedModes} FE/FD dispatches and {counts.flushContexts} reset-to-KOFF-flush contexts passed"

when isMainModule:
  main()
