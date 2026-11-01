## Independent global-command producer chains and volume-preview arithmetic/ports.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  PortWrite = tuple[address: uint16, value: uint8]
  Preview = object
    phase, depth, rate, fraction, counter, threshold: int
  Totals = object
    commands, remaps, eventGuards, previews, contrasts, stereo: int

const
  DriverPayload = 0x260042
  DriverStart = 0x500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  Guard = 0xA5'u8

proc word(spc: Spc, address: int): int =
  ## Read authored state with sixteen-bit address wrap.
  spc.ram[address and 65535].int or (spc.ram[(address + 1) and 65535].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Install synthetic words without using driver arithmetic.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address + 1) and 65535] = ((value shr 8) and 255).uint8

proc stack(spc: var Spc) =
  ## Guard native frames and supply an external caller return.
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E7] = Guard
  spc.ram[0x1F2] = Guard
  spc.sp = 0xEF

proc execute(spc: var Spc, entry, stop: uint16, budget: int): seq[PortWrite] =
  ## Run unchanged original code with no hardware reads or speaker/DSP device.
  var
    writes: seq[PortWrite]
    reads = 0
    instructions = 0
  spc.readHook = proc(address: uint16): int =
    inc reads
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    writes.add (address, value)
    false
  spc.pc = entry
  while spc.pc != stop:
    doAssert instructions < budget, &"global preview ${entry:04X} at ${spc.pc:04X}"
    doAssert spc.sp in 0xE8'u8 .. 0xF1'u8
    spc.step()
    inc instructions
  doAssert reads == 0 and not spc.stopped
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E7] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil
  result = writes

proc scaledGain(factor, master, channelFactor, volume: int): int =
  ## Truncate each unsigned product separately before the final square.
  let
    first = factor * master div 256
    second = first * channelFactor div 256
    third = second * volume div 256
  third * third div 256

proc previewGain(phase, depth, master, channelFactor, volume: int): int =
  ## Specify the triangular attenuation and staged channel gain with host integers.
  let
    triangle = if phase < 128: phase * 2 else: 511 - phase * 2
    factor = 255 - depth * triangle div 256
  scaledGain(factor, master, channelFactor, volume)

proc coefficient(position: int): int =
  ## Interpolate the authored quadratic pan curve independently of the driver.
  let
    integer = position div 256
    fraction = position and 255
    lower = integer * integer div 2
    upper = (integer + 1) * (integer + 1) div 2
  lower + (upper - lower) * fraction div 256

proc command(spc: var Spc, opcode, channel, operand, cursor: int,
    direct: bool, status: uint8, totals: var Totals) =
  ## Check actual metadata consumption, direct register differences and skip-only input.
  for address in 0 .. 0xEF: spc.ram[address] = 0
  for i in 0 ..< 16: spc.ram[0x400 + i] = Guard
  spc.ram[0x5F] = Guard
  spc.putWord(0x30 + channel, cursor)
  spc.ram[cursor] = operand.uint8
  spc.ram[(cursor + 1) and 65535] = 0x6A
  let before = spc.ram[0 .. 0xEF]
  spc.stack()
  spc.x = channel.uint8
  spc.a = (if direct: operand else: opcode).uint8
  spc.y = (operand xor 255).uint8
  spc.psw = status
  let
    entry = if not direct: 0x0943'u16 elif opcode == 0xFA: 0x0B72'u16
      elif opcode == 0xFB: 0x0B75'u16 else: 0x0B79'u16
    input = if direct or opcode != 0xFC: operand else: 0
    output = if opcode == 0xFC: (input + 1) and 255 else: input
    consumed = if direct: (if opcode == 0xFB: 1 else: 0)
      elif opcode == 0xFA: 1 elif opcode == 0xFB: 2 else: 0
  doAssert spc.execute(entry, ReturnAddress, 45).len == 0
  doAssert spc.sp == 0xF1 and spc.x.int == channel and spc.a.int == output
  doAssert spc.y.int == (if opcode == 0xFB or not direct: input else: operand xor 255)
  doAssert spc.word(0x30 + channel) == ((cursor + consumed) and 65535)
  doAssert spc.ram[0x5F].int == (if opcode == 0xFA: operand else: Guard.int)
  doAssert spc.ram[cursor].int == operand and spc.ram[(cursor + 1) and 65535] == 0x6A
  for i in 0 ..< 16:
    doAssert spc.ram[0x400 + i].int ==
      (if opcode == 0xFC and i == channel: output else: Guard.int)
  for address in 0 .. 0xEF:
    if address notin [0x30 + channel, 0x31 + channel] and
        not (opcode == 0xFA and address == 0x5F):
      doAssert spc.ram[address] == before[address]
  doAssert (spc.psw and (PswP or PswI or PswB or PswH or PswV)) ==
    (status and (PswP or PswI or PswB or PswH or PswV))
  doAssert (spc.psw and PswC) == (if direct: status and PswC else: 0'u8)
  if opcode == 0xFA and direct: doAssert spc.psw == status
  else:
    doAssert ((spc.psw and PswN) != 0) == (output >= 128)
    doAssert ((spc.psw and PswZ) != 0) == (output == 0)
  inc totals.commands

proc producerConsumers(spc: var Spc, totals: var Totals) =
  ## Feed real FA and FC outputs into their original consumers without rewriting them.
  for channel in countup(0, 14, 2):
    for operand in 0 .. 255:
      spc.command(0xFA, channel, operand, 0xFFFF, false, 0, totals)
      spc.ram[0x47] = (1 shl (channel div 2)).uint8
      spc.ram[0x1A] = spc.ram[0x47]
      spc.putWord(0x220 + channel, 0x6655)
      let producedCursor = spc.word(0x30 + channel)
      spc.stack()
      spc.a = 0xFF
      spc.x = channel.uint8
      spc.psw = 0
      doAssert spc.execute(0x095F, ReturnAddress, 30).len == 0
      doAssert spc.word(0x14) == 0x6E00 + ((53 + operand) and 255) * 6
      doAssert spc.ram[0x5F].int == operand and spc.ram[0x211 + channel] == 0xFF
      doAssert spc.word(0x30 + channel) == producedCursor
      doAssert spc.word(0x220 + channel) == 0x6655
      doAssert spc.x.int == channel and spc.sp == 0xF1
      inc totals.remaps
    for kind in 0 .. 2:
      for mode in [0, 128]:
        let
          direct = kind != 0
          input = if kind == 2: 255 else: 0
          produced = if direct: (input + 1) and 255 else: 1
          accepted = produced == 0 and mode == 0
        spc.command(0xFC, channel, input, 0x5000, direct, 0, totals)
        spc.ram[0x5000] = 0xA4
        spc.ram[0x1B] = mode.uint8
        spc.ram[0x50] = 0
        spc.ram[0x2F0 + channel] = 0
        spc.ram[0x1A] = 0
        spc.putWord(0x0E, 0)
        spc.ram[0x44] = channel.uint8
        spc.ram[0x280 + channel] = 0
        spc.putWord(0x360 + channel, 0xB47D)
        spc.ram[0x381 + channel] = 0x5A
        spc.ram[0x2B1 + channel] = 0
        spc.stack()
        spc.x = channel.uint8
        spc.psw = 0
        doAssert spc.execute(0x0882, (if accepted: 0x06BE'u16 else: 0x08D4'u16), 100).len == 0
        doAssert spc.ram[0x400 + channel].int == produced
        doAssert spc.word(0x360 + channel) == (if accepted: 0x245A else: 0xB47D)
        doAssert spc.word(0x30 + channel) == 0x5001 and spc.x.int == channel
        doAssert spc.sp == (if accepted: 0xED else: 0xEF)
        inc totals.eventGuards

proc preparePreview(spc: var Spc, channel: int, state: Preview,
    master, channelFactor, volume: int, direct: bool) =
  ## Disable unrelated previews and guard every persistent volume/modulation field.
  for address in 0 .. 0xEF: spc.ram[address] = 0
  for address in 0x200 .. 0x40F: spc.ram[address] = Guard
  spc.ram[0xC0 + channel] = state.counter.uint8
  spc.ram[0xC1 + channel] = state.depth.uint8
  spc.ram[0x2D0 + channel] = state.phase.uint8
  spc.ram[0x2D1 + channel] = state.rate.uint8
  spc.ram[0x2E0 + channel] = state.threshold.uint8
  spc.ram[0x51] = state.fraction.uint8
  spc.ram[0x13] = (if direct: 0x35 else: 0xB5)
  spc.ram[0x5E] = 0x6A
  spc.ram[0x47] = (1 shl (channel div 2)).uint8
  spc.putWord(0x58, master * 256 + 127)
  spc.putWord(0x300 + channel, volume * 256 + 127)
  spc.ram[0x210 + channel] = channelFactor.uint8
  spc.ram[0x321 + channel] = 0xA6
  spc.putWord(0x330 + channel, 10 * 256)
  spc.ram[0x351 + channel] = 0
  spc.ram[0xB1 + channel] = 0
  spc.ram[0x90 + channel] = 0
  spc.ram[0x91 + channel] = 0
  spc.ram[0xA0 + channel] = 0
  spc.ram[0x44] = (channel xor 2).uint8
  spc.x = channel.uint8
  spc.y = 0x57
  spc.psw = PswC or PswH or PswV or (if (state.phase and 1) == 0: 0'u8 else: PswI or PswB)
  spc.stack()

proc preview(spc: var Spc, channel: int, state: Preview, direct: bool,
    totals: var Totals, master = 255, channelFactor = 255, volume = 255) =
  ## Check phase truncation, unconditional direct depth-zero behavior and persistent state.
  spc.preparePreview(channel, state, master, channelFactor, volume, direct)
  let
    active = direct or (state.depth != 0 and state.counter == state.threshold)
    phase = (state.phase + state.rate * state.fraction div 256) and 255
    expected = if active: previewGain(phase, state.depth, master, channelFactor, volume) else: 0xA6
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[0x200 .. 0x40F]
    entryStatus = spc.psw
  doAssert spc.execute((if direct: 0x0E49'u16 else: 0x0DD0'u16),
    (if direct: ReturnAddress else: 0x0DDF'u16), 65).len == 0
  doAssert spc.sp == (if direct: 0xF1 else: 0xEF) and spc.x.int == channel
  doAssert spc.ram[0x321 + channel].int == expected
  doAssert spc.ram[0x13].int == (0x35 or (if active: 128 else: 0))
  doAssert (spc.psw and (PswP or PswI or PswB)) == (entryStatus and (PswI or PswB))
  if active:
    doAssert ((spc.psw and PswC) != 0) == (phase >= 128)
    doAssert spc.a.int == expected and spc.y.int == expected
  else:
    doAssert (spc.psw and (PswC or PswH or PswV)) == (entryStatus and (PswC or PswH or PswV))
  for address in 0 .. 0xEF:
    if address != 0x13: doAssert spc.ram[address] == beforeDp[address]
  for address in 0x200 .. 0x40F:
    if address != 0x321 + channel:
      doAssert spc.ram[address] == beforeArrays[address - 0x200]
  inc totals.previews

proc contrast(spc: var Spc, channel: int, state: Preview, totals: var Totals) =
  ## Contrast normal depth-255 holding/delay advancement with stateless preview behavior.
  spc.preparePreview(channel, state, 255, 255, 255, false)
  let
    active = state.depth != 0 and state.counter == state.threshold
    phase = if not active: state.phase elif state.phase >= 128 and state.depth == 255: 128
      else: (state.phase + state.rate) and 255
    counter = if state.depth != 0 and state.counter != state.threshold:
      (state.counter + 1) and 255 else: state.counter
    expected = if active: previewGain(phase, state.depth, 255, 255, 255)
      else: scaledGain(255, 255, 255, 255)
  doAssert spc.execute(0x0C40, 0x0C79, 65).len == 0
  doAssert spc.ram[0x2D0 + channel].int == phase
  doAssert spc.ram[0xC0 + channel].int == counter
  doAssert spc.ram[0xC1 + channel].int == state.depth
  doAssert spc.ram[0x321 + channel].int == expected
  doAssert spc.ram[0x5E].int == (if active: 0x6A or (1 shl (channel div 2)) else: 0x6A)
  doAssert spc.x.int == channel and spc.sp == 0xEF
  inc totals.contrasts

proc stereoTail(spc: var Spc, channel: int, state: Preview, blocked: bool, totals: var Totals) =
  ## Retain the 3072 original fixture contexts with an independent authored-curve port oracle.
  spc.preparePreview(channel, state, 255, 255, 255, false)
  let
    active = state.depth != 0 and state.counter == state.threshold
    phase = (state.phase + state.rate * state.fraction div 256) and 255
    expectedGain = if active: previewGain(phase, state.depth, 255, 255, 255) else: 0xA6
    beforeArrays = spc.ram[0x200 .. 0x40F]
    entryStatus = spc.psw and (PswP or PswI or PswB)
  spc.ram[0x1A] = (if blocked: spc.ram[0x47] else: 0)
  for i in 0 .. 21: spc.ram[0xE73 + i] = (i * i div 2).uint8
  let writes = spc.execute(0x0DD0, ReturnAddress, 250)
  var expected: seq[PortWrite]
  if active and not blocked:
    for side in 0 .. 1:
      let
        position = if side == 0: 10 * 256 else: 20 * 256 - 10 * 256
        value = expectedGain * coefficient(position) div 256
      expected.add (0xF2'u16, (channel * 8 + side).uint8)
      expected.add (0xF3'u16, value.uint8)
  doAssert writes == expected
  doAssert spc.ram[0x321 + channel].int == expectedGain
  for address in 0x200 .. 0x40F:
    if address != 0x321 + channel:
      doAssert spc.ram[address] == beforeArrays[address - 0x200]
  doAssert spc.ram[0xC0 + channel].int == state.counter
  doAssert spc.ram[0xC1 + channel].int == state.depth
  doAssert spc.ram[0x5E] == 0x6A and spc.ram[0x13] == 0x35
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert (spc.psw and (PswP or PswI or PswB)) == entryStatus
  inc totals.stereo

proc main() =
  ## Require original and fresh byte-identical rebuilt drivers; no source-code oracle or ROM skips.
  var totals: Totals
  for image in engineImages("bin/spc_global_commands_preview_extract"):
    var spc = newSpc()
    for i in 0 ..< DriverLength: spc.ram[DriverStart + i] = image[DriverPayload + i]
    for opcode in [0xFA, 0xFB, 0xFC]:
      for channel in countup(0, 14, 2):
        for operand in 0 .. 255:
          for cursor in [0x48FF, 0xFFFF]:
            for direct in [false, true]:
              for status in [0'u8, 0xDF'u8]:
                spc.command(opcode, channel, operand, cursor, direct, status, totals)
    for channel in countup(0, 14, 2):
      for operand in [0, 1, 127, 255]:
        for status in [0'u8, 0xDF'u8]: spc.command(0xFB, channel, operand, 0xF2, true, status, totals)
    spc.producerConsumers(totals)
    for phase in 0 .. 255:
      for depth in 0 .. 255:
        let state = Preview(phase: phase, depth: depth, rate: phase xor depth,
          fraction: (phase + depth) and 255)
        spc.preview(((phase xor depth) and 7) * 2, state, false, totals)
    for rate in 0 .. 255:
      for fraction in 0 .. 255:
        let state = Preview(phase: rate xor fraction, depth: 255, rate: rate, fraction: fraction)
        spc.preview(((rate + fraction) and 7) * 2, state, true, totals)
    for channel in countup(0, 14, 2):
      for phase in [0, 127, 128, 255]:
        for depth in [0, 1, 127, 255]:
          for rate in [0, 1, 127, 255]:
            for counters in [(0, 0), (0, 1), (255, 255), (255, 0)]:
              let state = Preview(phase: phase, depth: depth, rate: rate, fraction: 255,
                counter: counters[0], threshold: counters[1])
              for direct in [false, true]: spc.preview(channel, state, direct, totals)
              spc.contrast(channel, state, totals)
    for master in [0, 1, 128, 255]:
      for factor in [0, 1, 128, 255]:
        for volume in [0, 1, 128, 255]:
          for phase in [0, 127, 128, 255]:
            for depth in [0, 1, 127, 255]:
              let state = Preview(phase: phase, depth: depth, rate: 129, fraction: 127)
              spc.preview(((master + factor + volume) and 7) * 2, state, true, totals,
                master, factor, volume)
    for channel in countup(0, 14, 2):
      for depth in [0, 1, 127, 255]:
        for phase in [0, 127, 128, 255]:
          for rate in [0, 1, 255]:
            for counters in [(0, 0), (0, 1), (255, 255), (255, 0)]:
              for blocked in [false, true]:
                spc.stereoTail(channel, Preview(phase: phase, depth: depth, rate: rate,
                  fraction: 255, counter: counters[0], threshold: counters[1]), blocked, totals)
  echo &"SPC global commands/preview passed: {totals.commands} command calls, " &
    &"{totals.remaps} produced-remap consumers, {totals.eventGuards} produced-event-guard " &
    &"consumers, {totals.previews} bounded previews, {totals.contrasts} normal contrasts, " &
    &"{totals.stereo} complete stereo preview tails (3072 original fixtures per image)."

when isMainModule:
  main()
