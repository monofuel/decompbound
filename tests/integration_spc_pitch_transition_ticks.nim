## Independent normal/preview pitch-transition math on tiny authored channel states.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  PortWrite = tuple[address: uint16, value: uint8]
  State = object
    current, step, target, count, delay: int
    fraction, depth, phase, rate, modDelay, threshold: int
    request: bool
  Totals = object
    normalCalls, previewCalls, modulationCalls, combinedCalls, outputCalls: int

const
  DriverPayload = 0x260042
  DriverStart = 0x500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  NormalEntry = 0x0D60'u16
  NormalExit = 0x0D7C'u16
  PreviewEntry = 0x0DFC'u16
  ModulationEntry = 0x0E13'u16
  ConvertExit = 0x0DC7'u16
  Guard = 0xA5'u8
  WordEdges = [0, 1, 255, 256, 0x7FFF, 0x8000, 0xFF00, 0xFFFF]
  Phases = [0, 1, 127, 128, 255]

proc word(spc: Spc, address: int): int =
  ## Read a synthetic little-endian word.
  spc.ram[address].int or (spc.ram[address + 1].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Install authored state modulo sixteen bits.
  spc.ram[address] = (value and 255).uint8
  spc.ram[address + 1] = ((value shr 8) and 255).uint8

proc execute(spc: var Spc, entry: uint16, stops: openArray[uint16],
    budget: int): seq[PortWrite] =
  ## Execute unmodified instructions with a guarded caller and silent port capture.
  var
    writes: seq[PortWrite]
    reads = 0
    instructions = 0
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E8] = Guard
  spc.ram[0x1F2] = Guard
  spc.sp = 0xEF
  spc.pc = entry
  spc.readHook = proc(address: uint16): int =
    inc reads
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    writes.add (address, value)
    false
  while spc.pc notin stops:
    doAssert instructions < budget, &"pitch tick ${entry:04X} at ${spc.pc:04X}"
    doAssert spc.sp in 0xE9'u8 .. 0xF1'u8
    spc.step()
    inc instructions
  doAssert reads == 0 and not spc.stopped
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E8] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil
  result = writes

proc previewPosition(current, step, fraction: int): int =
  ## Add a signed step scaled toward zero, independently of bytewise SPC operations.
  let
    signedStep = if step < 32768: step else: step - 65536
    magnitude = abs(signedStep) * fraction div 256
  (current + (if signedStep < 0: -magnitude else: magnitude)) and 65535

proc wavePosition(base, depth, phase: int): int =
  ## Apply the signed piecewise-depth triangular displacement to a base word.
  let
    coordinate = (phase and 63) * 4
    triangle = if (phase and 64) == 0: coordinate else: 255 - coordinate
    magnitude = if depth <= 240: depth * triangle div 256 else: (depth and 15) * triangle
  (base + (if phase < 128: magnitude else: -magnitude)) and 65535

proc statusSeed(current: int): uint8 =
  ## Exercise both cleared and set interrupt/break bits while entering on page zero.
  if (current and 1) == 0: 0'u8 else: PswI or PswB

proc install(spc: var Spc, channel: int, state: State) =
  ## Guard persistent fields and install one channel without using setup handlers.
  for base in [0xA0, 0xB0, 0x100, 0x2A0, 0x2B0, 0x360, 0x370, 0x380]:
    for i in 0 ..< 16: spc.ram[base + i] = Guard
  spc.ram[0xA0 + channel] = state.count.uint8
  spc.ram[0xA1 + channel] = state.delay.uint8
  spc.ram[0xB0 + channel] = state.modDelay.uint8
  spc.ram[0xB1 + channel] = state.depth.uint8
  spc.ram[0x2A0 + channel] = state.phase.uint8
  spc.ram[0x2A1 + channel] = state.rate.uint8
  spc.ram[0x2B0 + channel] = state.threshold.uint8
  spc.putWord(0x360 + channel, state.current)
  spc.putWord(0x370 + channel, state.step)
  spc.ram[0x380 + channel] = state.target.uint8
  spc.putWord(0x0E, 0)
  spc.putWord(0x10, state.current)
  spc.ram[0x12] = 0x55
  spc.ram[0x13] = (0x25 or (if state.request: 128 else: 0)).uint8
  spc.putWord(0x14, 0x6655)
  spc.ram[0x44] = (channel xor 2).uint8
  spc.ram[0x47] = (1 shl (channel div 2)).uint8
  spc.ram[0x5E] = 0xA5
  spc.ram[0x51] = state.fraction.uint8
  spc.x = channel.uint8
  spc.y = 0x57
  spc.psw = statusSeed(state.current)

proc persistent(spc: Spc, channel: int, expected: State, entryStatus: uint8) =
  ## Verify current/counter updates, all untouched parameters and neighboring bytes.
  doAssert spc.word(0x360 + channel) == expected.current
  doAssert spc.word(0x370 + channel) == expected.step
  doAssert spc.ram[0x380 + channel].int == expected.target
  doAssert spc.ram[0x381 + channel] == Guard
  doAssert spc.ram[0xA0 + channel].int == expected.count
  doAssert spc.ram[0xA1 + channel].int == expected.delay
  doAssert spc.ram[0xB0 + channel].int == expected.modDelay
  doAssert spc.ram[0xB1 + channel].int == expected.depth
  doAssert spc.ram[0x2A0 + channel].int == expected.phase
  doAssert spc.ram[0x2A1 + channel].int == expected.rate
  doAssert spc.ram[0x2B0 + channel].int == expected.threshold
  doAssert spc.ram[0x2B1 + channel] == Guard
  doAssert spc.ram[0x100 + channel] == Guard and spc.ram[0x101 + channel] == Guard
  for base in [0xA0, 0xB0, 0x100, 0x2A0, 0x2B0, 0x360, 0x370, 0x380]:
    for i in 0 ..< 16:
      if i notin [channel, channel + 1]: doAssert spc.ram[base + i] == Guard
  doAssert spc.ram[0x5E] == 0xA5 and spc.ram[0x44].int == (channel xor 2)
  doAssert spc.ram[0x51].int == expected.fraction and spc.word(0x0E) == 0
  doAssert spc.x.int == channel
  doAssert (spc.psw and (PswP or PswI or PswB)) == entryStatus

proc checkNormal(spc: var Spc, channel: int, before: State, totals: var Totals) =
  ## Specify decrement-before-update and the exact final target snap.
  spc.install(channel, before)
  spc.putWord(0x10, before.current xor 65535)
  var expected = before
  let updated = before.count != 0 and before.delay == 0
  if before.count != 0:
    if before.delay != 0: dec expected.delay
    else:
      dec expected.count
      expected.current = if expected.count == 0: before.target * 256
        else: (before.current + before.step) and 65535
  doAssert spc.execute(NormalEntry, [NormalExit], 80).len == 0
  spc.persistent(channel, expected, statusSeed(before.current))
  doAssert spc.word(0x10) == expected.current and spc.a.int == (expected.current and 255)
  doAssert spc.ram[0x13].int == (0x25 or (if updated: 128 else: 0))
  doAssert spc.sp == 0xEF
  inc totals.normalCalls

proc checkPreview(spc: var Spc, channel: int, state: State, totals: var Totals) =
  ## Scale signed steps without mutating current pitch or either transition counter.
  spc.install(channel, state)
  spc.putWord(0x10, state.current xor 65535)
  let
    active = state.count != 0 and state.delay == 0
    expected = if active: previewPosition(state.current, state.step, state.fraction)
      else: state.current
  doAssert spc.execute(PreviewEntry, [ModulationEntry], 80).len == 0
  spc.persistent(channel, state, statusSeed(state.current))
  doAssert spc.word(0x10) == expected
  doAssert spc.ram[0x13].int == (0x25 or (if active: 128 else: 0))
  doAssert spc.sp == 0xEF
  if active: doAssert spc.a.int + 256 * spc.y.int == expected
  inc totals.previewCalls

proc checkModulation(spc: var Spc, channel: int, state: State,
    combined: bool, totals: var Totals) =
  ## Compare preview phase and shared wave value without advancing persistent modulation.
  spc.install(channel, state)
  if combined: spc.putWord(0x10, state.current xor 65535)
  let
    pitchPreview = combined and state.count != 0 and state.delay == 0
    request = if combined: pitchPreview else: state.request
    base = if pitchPreview: previewPosition(state.current, state.step, state.fraction)
      else: state.current
    active = state.depth != 0 and state.modDelay == state.threshold
    previewPhase = (state.phase + state.rate * state.fraction div 256) and 255
    expected = if active: wavePosition(base, state.depth, previewPhase) else: base
    output = request or active
    entry = if combined: PreviewEntry else: ModulationEntry
  doAssert spc.execute(entry, [ConvertExit, ReturnAddress], 150).len == 0
  spc.persistent(channel, state, statusSeed(state.current))
  doAssert spc.word(0x10) == expected
  doAssert spc.pc == (if output: ConvertExit else: ReturnAddress)
  doAssert spc.sp == (if output: 0xEF else: 0xF1)
  doAssert spc.ram[0x13].int == (0x25 or (if request: 128 else: 0))
  if active: doAssert spc.ram[0x12].int == previewPhase
  if combined: inc totals.combinedCalls
  else: inc totals.modulationCalls

proc matrices(spc: var Spc, totals: var Totals) =
  ## Use full single domains and focused boundary crosses rather than a huge Cartesian sweep.
  const NormalWords = [(0, 0, 0), (0xFFFF, 1, 255), (0, 0xFFFF, 1),
    (0x7FFF, 1, 128), (0x8000, 0x8000, 127), (0x1234, 0x180, 17),
    (0xFF80, 0xFF80, 0), (0x7F00, 0x7FFF, 255)]
  for count in 0 .. 255:
    for delay in [0, 1, 255]:
      for values in NormalWords:
        let state = State(current: values[0], step: values[1], target: values[2],
          count: count, delay: delay, request: true)
        spc.checkNormal(((count + delay + values[2]) and 7) * 2, state, totals)
  for step in 0 .. 65535:
    let state = State(current: (step * 17) and 65535, step: step, count: 2,
      fraction: (step * 73) and 255, request: true)
    spc.checkPreview((step and 7) * 2, state, totals)
  for step in WordEdges:
    for fraction in 0 .. 255:
      let state = State(current: 0xFFF1, step: step, count: 255, fraction: fraction)
      spc.checkPreview(((step + fraction) and 7) * 2, state, totals)
  for counters in [(0, 0), (0, 255), (1, 1), (1, 0), (255, 0), (255, 255)]:
    for step in WordEdges:
      for fraction in Phases:
        let state = State(current: 0x7FFF, step: step, count: counters[0],
          delay: counters[1], fraction: fraction, request: true)
        spc.checkPreview(((step + fraction) and 7) * 2, state, totals)
  for depth in 0 .. 255:
    for phase in 0 .. 255:
      let state = State(current: 0xFFF1, depth: depth, phase: phase,
        rate: depth xor phase, fraction: (depth + phase) and 255, request: (phase and 1) != 0)
      spc.checkModulation(((depth + phase) and 7) * 2, state, false, totals)
  for depth in [0, 1, 240, 241, 255]:
    for phase in [0, 63, 64, 127, 128, 191, 192, 255]:
      for rate in [0, 1, 128, 255]:
        for fraction in [0, 1, 127, 255]:
          for matched in [false, true]:
            for request in [false, true]:
              let state = State(current: 0x2401, depth: depth, phase: phase,
                rate: rate, fraction: fraction, modDelay: 255,
                threshold: (if matched: 255 else: 0), request: request)
              spc.checkModulation(((depth + phase) and 7) * 2, state, false, totals)

proc combinedOutput(spc: var Spc, totals: var Totals) =
  ## Check combined values separately from port serialization through the real converter tail.
  for step in WordEdges:
    for depth in [0, 240, 241, 255]:
      for phase in [0, 127, 128, 255]:
        for fraction in [0, 1, 127, 255]:
          for counters in [(0, 0), (1, 1), (1, 0), (255, 0)]:
            for matched in [false, true]:
              let
                channel = ((step + depth + phase + fraction) and 7) * 2
                state = State(current: 0x2401, step: step, count: counters[0],
                  delay: counters[1], fraction: fraction, depth: depth, phase: phase,
                  rate: 255, threshold: (if matched: 0 else: 1), request: true)
                output = (state.count != 0 and state.delay == 0) or
                  (depth != 0 and matched)
                mask = if (phase and 1) == 0: 0 else: 1 shl (channel div 2)
                inhibit = if (fraction and 1) == 0: 0 else: 255
              spc.checkModulation(channel, state, true, totals)
              spc.install(channel, state)
              spc.putWord(0x10, state.current xor 65535)
              spc.ram[0x47] = mask.uint8
              spc.ram[0x1A] = inhibit.uint8
              spc.putWord(0x220 + channel, 0x100)
              let writes = spc.execute(PreviewEntry, [ReturnAddress], 2000)
              spc.persistent(channel, state, statusSeed(state.current))
              doAssert spc.sp == 0xF1
              if output and (mask and inhibit) == 0:
                # Value math was checked at DC7 above. Here only serialization/gating
                # is claimed; converter arithmetic has its own independent suite.
                doAssert writes == @[(0xF2'u16, (channel * 8 + 2).uint8),
                  (0xF3'u16, spc.ram[0x16]), (0xF2'u16, (channel * 8 + 3).uint8),
                  (0xF3'u16, spc.ram[0x17])]
              else: doAssert writes.len == 0
              inc totals.outputCalls

proc main() =
  ## Require original and fresh byte-identical rebuilt driver images; never skip missing ROMs.
  var totals: Totals
  for image in engineImages("bin/spc_pitch_transition_ticks_extract"):
    var spc = newSpc()
    for i in 0 ..< DriverLength: spc.ram[DriverStart + i] = image[DriverPayload + i]
    spc.matrices(totals)
    spc.combinedOutput(totals)
  echo &"SPC pitch transition ticks passed: {totals.normalCalls} normal entries, " &
    &"{totals.previewCalls} signed-step preview entries, {totals.modulationCalls} " &
    &"modulation-preview entries, {totals.combinedCalls} combined value entries, " &
    &"{totals.outputCalls} complete guarded output calls."

when isMainModule:
  main()
