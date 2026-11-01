import
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  CommandEntry = 0x943'u16
  TickEntry = 0xC79'u16
  InterpolateEntry = 0xDDF'u16
  CurveBase = 0xE73
  PositionLimit = 20 * 256

type PortWrite = tuple[address: uint16, value: uint8]

proc word(spc: Spc, address: int): int =
  ## Read a little-endian state word.
  spc.ram[address].int + 256 * spc.ram[address + 1].int

proc putWord(spc: var Spc, address, value: int) =
  ## Set an authored state word modulo sixteen bits.
  spc.ram[address] = (value and 255).uint8
  spc.ram[address + 1] = ((value shr 8) and 255).uint8

proc execute(spc: var Spc, entry: uint16, channel: int,
    stopPc: uint16 = ReturnAddress): seq[PortWrite] =
  ## Execute one bounded original routine, collecting DSP port writes silently.
  var writes: seq[PortWrite]
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    writes.add (address, value)
    false
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.pc = entry
  spc.sp = 0xEF
  spc.x = channel.uint8
  spc.psw = 0
  var steps = 0
  while spc.pc != stopPc:
    doAssert steps < 250
    spc.step()
    inc steps
  doAssert spc.sp == (if stopPc == ReturnAddress: 0xF1 else: 0xEF) and spc.x.int == channel
  spc.writeHook = nil
  result = writes

proc expectedStep(start, target, duration: int): int =
  ## Model full signed target displacement and SPC divide-by-zero explicitly.
  let
    delta = target - start
    magnitude = abs(delta)
    quotient = if duration == 0: 65535 - magnitude else: magnitude * 256 div duration
  (if delta < 0: -quotient else: quotient) and 65535

proc command(spc: var Spc, voice, start, fraction, target, duration,
    overrideFlag, stream: int): int =
  ## Verify E2 dispatch, operand count, complete fields, and preserved phase flags.
  let
    channel = voice * 2
    effective = if overrideFlag == 0: target else: 10
    step = expectedStep(start, effective, duration)
  spc.putWord(0x30 + channel, stream)
  spc.ram[stream] = duration.uint8
  spc.ram[(stream + 1) and 65535] = target.uint8
  spc.putWord(0x330 + channel, start * 256 + fraction)
  spc.ram[0x351 + channel] = 0xC0
  spc.ram[0x431] = overrideFlag.uint8
  spc.ram[0x44] = channel.uint8
  spc.a = 0xE2
  doAssert spc.execute(CommandEntry, channel).len == 0
  doAssert spc.word(0x30 + channel) == ((stream + 2) and 65535)
  doAssert spc.ram[0x91 + channel].int == duration
  doAssert spc.ram[0x350 + channel].int == effective
  doAssert spc.ram[0x351 + channel] == 0xC0
  doAssert spc.word(0x340 + channel) == step, $[voice, start, fraction, target, duration, overrideFlag, spc.word(0x340 + channel), step]
  doAssert spc.word(0x330 + channel) == start * 256 + fraction
  doAssert spc.ram[0x20].int == effective
  result = step

proc coefficient(position: int): int =
  ## Interpolate the authored nonlinear curve with the original truncation order.
  let
    index = position div 256
    fraction = position mod 256
    lower = index * index div 2
    upper = (index + 1) * (index + 1) div 2
  lower + (upper - lower) * fraction div 256

proc expectedWrites(voice, position: int): seq[PortWrite] =
  ## Derive inverted stereo volume bytes from the earlier verified E1 law.
  for side in 0 .. 1:
    let
      coordinate = if side == 0: position else: PositionLimit - position
      magnitude = coefficient(coordinate) * 255 div 256
    result.add (0xF2'u16, (voice * 16 + side).uint8)
    result.add (0xF3'u16, ((-magnitude) and 255).uint8)

proc checkTicks(spc: var Spc, voice, start, target, duration: int) =
  ## Verify counter exhaustion, repeated fixed-point adds, and resulting DSP output.
  let
    channel = voice * 2
    mask = 1 shl voice
    step = spc.command(voice, start, 0, target, duration, 0, 0x48FF)
  var position = start * 256
  spc.ram[0x47] = mask.uint8
  spc.ram[0x1A] = 0
  spc.ram[0x321 + channel] = 255
  spc.ram[0x5E] = 0
  for tick in 1 .. duration + 1:
    let active = tick <= duration
    if active: position = (position + step) and 65535
    let writes = spc.execute(TickEntry, channel)
    doAssert spc.word(0x330 + channel) == position
    doAssert spc.ram[0x91 + channel].int == max(0, duration - tick)
    doAssert spc.ram[0x5E].int == (if duration == 0: 0 else: mask)
    if duration == 0:
      doAssert writes.len == 0
    else:
      doAssert position in 0 .. PositionLimit
      doAssert writes == expectedWrites(voice, position)
    # $5E remains dirty here, so the exhausted counter still permits DSP output.

proc checkInterpolation(spc: var Spc, voice, start, target, duration, phase: int) =
  ## Verify sub-tick preview without mutating the persistent position or counter.
  let
    channel = voice * 2
    mask = 1 shl voice
    unsignedStep = spc.command(voice, start, 0, target, duration, 0, 0x48FF)
    step = if unsignedStep < 32768: unsignedStep else: unsignedStep - 65536
    offset = (if step < 0: -1 else: 1) * (abs(step) * phase div 256)
    position = start * 256 + (if duration == 0: 0 else: offset)
  spc.ram[0x47] = mask.uint8
  spc.ram[0x1A] = 0
  spc.ram[0x321 + channel] = 255
  spc.ram[0x51] = phase.uint8
  spc.ram[0x13] = 0
  # Stop immediately after the preview's call to the already verified pan writer.
  let writes = spc.execute(InterpolateEntry, channel, 0xDFC)
  doAssert spc.word(0x330 + channel) == start * 256
  doAssert spc.ram[0x91 + channel].int == duration
  if duration == 0:
    doAssert writes.len == 0
  else:
    doAssert position in 0 .. PositionLimit
    doAssert writes == expectedWrites(voice, position)

proc checkTickFlags(spc: var Spc): int =
  ## Distinguish the helper's OR-result branch from duration exhaustion.
  for remaining in [1, 3]:
    for mask in [0, 1, 128]:
      for dirty in [0, 1, 128]:
        discard spc.command(0, 10, 127, 20, remaining, 0, 0x48FF)
        let step = spc.word(0x340)
        spc.ram[0x47] = mask.uint8
        spc.ram[0x5E] = dirty.uint8
        spc.ram[0x1A] = 255
        discard spc.execute(TickEntry, 0)
        let expected = if (mask or dirty) == 0: 20 * 256 else: 10 * 256 + 127 + step
        doAssert spc.word(0x330) == expected
        doAssert spc.ram[0x91].int == remaining - 1
        inc result

proc checkSchedulerCall(spc: var Spc): int =
  ## Execute the original enclosing channel-update call at $0939 exactly once.
  for voice in 0 ..< 8:
    let
      channel = voice * 2
      step = spc.command(voice, 10, 0, 20, 3, 0, 0x48FF)
    spc.ram[0x47] = (1 shl voice).uint8
    spc.ram[0x5E] = 0
    spc.ram[0x1A] = 255
    spc.ram[0x90 + channel] = 0
    spc.ram[0xC1 + channel] = 0
    discard spc.execute(0x939, channel, 0x93C)
    doAssert spc.ram[0x91 + channel] == 2
    doAssert spc.word(0x330 + channel) == 10 * 256 + step
    inc result

proc checkImage(image: seq[uint8]): tuple[commands, transitions, previews, branches,
    enclosingCalls: int] =
  ## Check E2 arithmetic and both consumers without audio or extracted assets.
  var
    spc = newSpc()
    commands = 0
    transitions = 0
    previews = 0
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[address + DriverMap]
  doAssert spc.word(0xB23 + ((0xE2 * 2) and 255)) == 0x9D6
  for index in 0 .. 21:
    spc.ram[CurveBase + index] = (index * index div 2).uint8
  let
    branches = spc.checkTickFlags()
    enclosingCalls = spc.checkSchedulerCall()
  for voice in 0 ..< 8:
    for start in [0, 1, 10, 20, 127, 128, 255]:
      for target in [0, 1, 10, 20, 127, 128, 255]:
        for duration in [0, 1, 2, 3, 127, 255]:
          for fraction in [0, 127, 255]:
            for overrideFlag in [0, 1]:
              for stream in [0x48FF, 0xFFFF]:
                discard spc.command(voice, start, fraction, target, duration,
                  overrideFlag, stream)
                inc commands
    for start in [0, 1, 10, 19, 20]:
      for target in [0, 1, 10, 19, 20]:
        for duration in [0, 1, 2, 3, 127, 255]:
          spc.checkTicks(voice, start, target, duration)
          inc transitions
          for phase in [0, 1, 127, 255]:
            spc.checkInterpolation(voice, start, target, duration, phase)
            inc previews
  result = (commands, transitions, previews, branches, enclosingCalls)

proc main() =
  ## Verify original and rebuilt driver transitions with independently predicted DSP writes.
  var commands, transitions, previews, branches, enclosingCalls = 0
  for image in engineImages("bin/spc_pan_transition_extract"):
    let checked = checkImage(image)
    commands += checked.commands
    transitions += checked.transitions
    previews += checked.previews
    branches += checked.branches
    enclosingCalls += checked.enclosingCalls
  echo "SPC pan transition: ", commands, " command cases, ", transitions,
    " complete transitions, ", previews,
    " sub-tick previews, ", branches, " branch cases and ", enclosingCalls,
    " enclosing-call cases passed."

when isMainModule:
  main()
