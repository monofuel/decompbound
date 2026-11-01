## Independently model command setup and persistent pitch modulation on authored state.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  PortWrite = tuple[address: uint16, value: uint8]
  State = object
    depth, target, quotient, duration, ramp: int
    delay, threshold, phase, rate, position: int
    request: bool
  Totals = object
    setupCalls, stageCalls, rampContexts, eventCalls, outputCalls: int

const
  DriverPayload = 0x260042
  DriverStart = 0x500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  TickEntry = 0x0D7C'u16
  ConvertEntry = 0x0DC7'u16
  Guard = 0xA5'u8
  DepthEdges = [0, 1, 2, 127, 240, 241, 254, 255]

proc word(spc: Spc, address: int): int =
  ## Read an authored little-endian word.
  spc.ram[address].int or (spc.ram[address + 1].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Store synthetic state modulo sixteen bits.
  spc.ram[address] = (value and 255).uint8
  spc.ram[address + 1] = ((value shr 8) and 255).uint8

proc stack(spc: var Spc) =
  ## Install an external caller and guards below all expected native frames.
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E8] = Guard
  spc.ram[0x1F2] = Guard
  spc.sp = 0xEF

proc execute(spc: var Spc, entry: uint16, stops: openArray[uint16], budget: int): seq[PortWrite] =
  ## Execute original instructions silently with observed ports and bounded stack use.
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
  while spc.pc notin stops:
    doAssert instructions < budget, &"pitch modulation ${entry:04X} at ${spc.pc:04X}"
    doAssert spc.sp in 0xE9'u8 .. 0xF1'u8
    spc.step()
    inc instructions
  doAssert reads == 0 and not spc.stopped
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E8] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil
  result = writes

proc model(before: State): tuple[state: State, output: bool, active: bool] =
  ## Specify a bounded tick using byte arithmetic and a signed triangular offset.
  result.state = before
  result.output = before.request
  if before.depth == 0: return
  if before.delay != before.threshold:
    result.state.delay = (before.delay + 1) and 255
    return
  result.active = true
  result.output = true
  if before.ramp == before.duration:
    result.state.depth = before.target
  else:
    result.state.ramp = (before.ramp + 1) and 255
    let baseline = if before.ramp == 0: 0 else: before.depth
    result.state.depth = (baseline + before.quotient) and 255
  result.state.phase = (before.phase + before.rate) and 255
  let
    coordinate = 4 * (result.state.phase and 63)
    triangle = if (result.state.phase and 64) == 0: coordinate else: 255 - coordinate
    magnitude = if result.state.depth <= 240: result.state.depth * triangle div 256
      else: (result.state.depth and 15) * triangle
    signedOffset = if result.state.phase < 128: magnitude else: -magnitude
  result.state.position = (before.position + signedOffset) and 65535

proc install(spc: var Spc, channel: int, state: State) =
  ## Guard all channel fields, then install one synthetic modulation state.
  for i in 0 ..< 16:
    for base in [0x100, 0x2A0, 0x2B0, 0x2C0, 0xB0]:
      spc.ram[base + i] = Guard
  spc.ram[0xB0 + channel] = state.delay.uint8
  spc.ram[0xB1 + channel] = state.depth.uint8
  spc.ram[0x100 + channel] = state.ramp.uint8
  spc.ram[0x2A0 + channel] = state.phase.uint8
  spc.ram[0x2A1 + channel] = state.rate.uint8
  spc.ram[0x2B0 + channel] = state.threshold.uint8
  spc.ram[0x2B1 + channel] = state.duration.uint8
  spc.ram[0x2C0 + channel] = state.quotient.uint8
  spc.ram[0x2C1 + channel] = state.target.uint8
  spc.putWord(0x0E, 0)
  spc.putWord(0x10, state.position)
  spc.ram[0x12] = 0x55
  spc.ram[0x13] = (0x35 or (if state.request: 128 else: 0)).uint8
  spc.putWord(0x14, 0x6655)
  spc.ram[0x44] = (channel xor 2).uint8
  spc.ram[0x47] = (1 shl (channel div 2)).uint8
  spc.ram[0x5E] = 0xA5

proc checkFields(spc: Spc, channel: int, expected: State) =
  ## Verify state transitions, preserved parameters and every neighboring channel byte.
  doAssert spc.ram[0xB0 + channel].int == expected.delay
  doAssert spc.ram[0xB1 + channel].int == expected.depth
  doAssert spc.ram[0x100 + channel].int == expected.ramp
  doAssert spc.ram[0x2A0 + channel].int == expected.phase
  doAssert spc.ram[0x2A1 + channel].int == expected.rate
  doAssert spc.ram[0x2B0 + channel].int == expected.threshold
  doAssert spc.ram[0x2B1 + channel].int == expected.duration
  doAssert spc.ram[0x2C0 + channel].int == expected.quotient
  doAssert spc.ram[0x2C1 + channel].int == expected.target
  doAssert spc.ram[0x101 + channel] == Guard
  for i in 0 ..< 16:
    if i notin [channel, channel + 1]:
      for base in [0x100, 0x2A0, 0x2B0, 0x2C0, 0xB0]:
        doAssert spc.ram[base + i] == Guard

proc stage(spc: var Spc, channel: int, before: State, totals: var Totals) =
  ## Check the original modulation stage before the separately verified converter tail.
  let expected = model(before)
  spc.putWord(0x10, before.position)
  spc.stack()
  spc.x = channel.uint8
  spc.y = 0x5A
  spc.psw = PswI or PswB or PswC
  doAssert spc.execute(TickEntry, [ConvertEntry, ReturnAddress], 60).len == 0
  doAssert spc.pc == (if expected.output: ConvertEntry else: ReturnAddress)
  doAssert spc.sp == (if expected.output: 0xEF else: 0xF1)
  doAssert spc.x.int == channel
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  doAssert spc.word(0x10) == expected.state.position
  doAssert spc.ram[0x13].int == (0x35 or (if before.request: 128 else: 0))
  doAssert spc.ram[0x5E] == 0xA5
  if expected.active: doAssert spc.ram[0x12].int == expected.state.phase
  spc.checkFields(channel, expected.state)
  inc totals.stageCalls

proc setup(spc: var Spc, command, channel, operand, oldDepth: int,
    direct: bool, status: uint8, totals: var Totals) =
  ## Check real dispatcher operands and direct-entry distinctions against host division.
  let
    rate = operand xor 255
    depth = (operand * 73) and 255
    stream = if (operand and 1) == 0: 0x48FF else: 0xFFFF
    before = State(depth: oldDepth, target: 0xB3, quotient: 0x35, duration: 0x25,
      ramp: 0xC3, delay: 0xD3, threshold: 0xF3, phase: 0x91, rate: 0xE3)
  spc.install(channel, before)
  spc.ram[0x44] = channel.uint8
  spc.putWord(0x30 + channel, stream)
  if command == 0xE3:
    if direct:
      spc.ram[stream] = rate.uint8
      spc.ram[(stream + 1) and 65535] = depth.uint8
    else:
      spc.ram[stream] = operand.uint8
      spc.ram[(stream + 1) and 65535] = rate.uint8
      spc.ram[(stream + 2) and 65535] = depth.uint8
  else: spc.ram[stream] = operand.uint8
  spc.stack()
  spc.x = channel.uint8
  spc.a = (if direct: operand else: command).uint8
  spc.y = (operand xor 0x55).uint8
  spc.psw = status
  let entry = if not direct: 0x0943'u16 elif command == 0xE3: 0x09FD'u16
    elif command == 0xE4: 0x0A09'u16 else: 0x0A14'u16
  doAssert spc.execute(entry, [ReturnAddress], 70).len == 0
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  var expected = before
  let expectedCarry = if direct: status and PswC else: 0'u8
  if command == 0xE3:
    expected.threshold = operand
    expected.rate = rate
    expected.depth = depth
    expected.target = depth
    expected.duration = 0
    doAssert spc.a == 0 and spc.y.int == depth
  elif command == 0xE4:
    let selected = if direct: operand else: 0
    expected.depth = selected
    expected.target = selected
    expected.duration = 0
    doAssert spc.a == 0
    doAssert spc.y.int == (if direct: operand xor 0x55 else: 0)
  else:
    expected.duration = operand
    expected.quotient = if operand == 0: 255 else: oldDepth div operand
    doAssert spc.a.int == expected.quotient
    doAssert spc.y.int == (if operand == 0: oldDepth else: oldDepth mod operand)
    doAssert ((spc.psw and PswH) != 0) == ((operand and 15) == 0)
    doAssert ((spc.psw and PswV) != 0) == (operand == 0)
  spc.checkFields(channel, expected)
  let consumed = if command == 0xE3: (if direct: 2 else: 3)
    elif command == 0xE4 or direct: 0 else: 1
  doAssert spc.word(0x30 + channel) == ((stream + consumed) and 65535)
  doAssert spc.ram[0x5E] == 0xA5
  doAssert (spc.psw and PswC) == expectedCarry
  doAssert (spc.psw and (PswP or PswI or PswB)) == (status and (PswI or PswB))
  if command != 0xF0:
    doAssert (spc.psw and (PswH or PswV)) == (status and (PswH or PswV))
    doAssert (spc.psw and (PswN or PswZ)) == PswZ
  else:
    doAssert (spc.psw and PswN) == 0
    doAssert ((spc.psw and PswZ) != 0) == (channel == 0)
  inc totals.setupCalls

proc matrices(spc: var Spc, totals: var Totals) =
  ## Cover full operand/phase domains and delay, ramp, depth-scaling boundaries.
  for channel in countup(0, 14, 2):
    for operand in 0 .. 255:
      for direct in [false, true]:
        for status in [0'u8, 0xDF'u8]:
          spc.setup(0xE3, channel, operand, 0x45, direct, status, totals)
          spc.setup(0xE4, channel, operand, 0x45, direct, status, totals)
          for oldDepth in DepthEdges:
            spc.setup(0xF0, channel, operand, oldDepth, direct, status, totals)
  for depth in 0 .. 255:
    for phase in 0 .. 255:
      let
        channel = ((depth xor phase) and 7) * 2
        state = State(depth: depth, target: depth, phase: phase, rate: 1,
          position: ((depth * 257) xor (phase * 73)) and 65535,
          request: (phase and 1) != 0)
      spc.install(channel, state)
      spc.stage(channel, state, totals)
  for depth in [0, 1, 2, 127, 240, 241, 255]:
    for ramp in [0, 1, 2, 127, 128, 254, 255]:
      for duration in [0, 1, 2, 127, 255]:
        for quotient in [0, 1, 127, 255]:
          for target in [0, 1, 128, 255]:
            for counters in [(0, 0), (0, 1), (255, 0), (255, 255)]:
              let
                channel = ((depth + ramp + target) and 7) * 2
                state = State(depth: depth, target: target, quotient: quotient,
                  duration: duration, ramp: ramp, delay: counters[0], threshold: counters[1],
                  phase: (ramp + duration) and 255, rate: quotient, position: 0xFFF0,
                  request: (ramp and 1) != 0)
              spc.install(channel, state)
              spc.stage(channel, state, totals)

proc ramps(spc: var Spc, totals: var Totals) =
  ## Follow actual F0 setup and accepted-event reset across repeated original ticks.
  for depth in [0, 1, 2, 127, 240, 241, 255]:
    for duration in [0, 1, 2, 3, 127, 255]:
      const Channel = 6
      let quotient = if duration == 0: 255 else: depth div duration
      spc.setup(0xF0, Channel, duration, depth, true, 0, totals)
      spc.ram[0x2C1 + Channel] = depth.uint8
      spc.ram[0x2B0 + Channel] = 0
      spc.ram[0x2A1 + Channel] = 1
      spc.ram[0x381 + Channel] = 0
      spc.ram[0x2F0 + Channel] = 0
      spc.ram[0x50] = 0
      spc.ram[0x1A] = 0
      spc.stack()
      spc.x = Channel
      spc.a = 0xA4
      spc.y = 0xA4
      spc.psw = 0
      doAssert spc.execute(0x0654, [0x0696'u16], 50).len == 0
      doAssert spc.ram[0x100 + Channel] == 0
      doAssert spc.ram[0x2A0 + Channel].int == ((duration and 1) * 128)
      inc totals.eventCalls
      var expected = State(depth: depth, target: depth, quotient: quotient,
        duration: duration, phase: (duration and 1) * 128, rate: 1, position: 0x2400)
      # Event reset marked dirty; modulation ticks must preserve this value.
      spc.ram[0x5E] = 0xA5
      spc.ram[0x13] = 0x35
      for tick in 0 .. duration + 1:
        spc.stage(Channel, expected, totals)
        expected = model(expected).state
        expected.position = 0x2400
      inc totals.rampContexts

proc outputGuards(spc: var Spc, totals: var Totals) =
  ## Check real conversion-tail port gating without re-specifying its separate pitch math.
  for channel in countup(0, 14, 2):
    for depth in [240, 241]:
      for phase in [63, 127, 191, 255]:
        for kind in 0 .. 2:
          for request in [false, true]:
            for inhibit in [0, 255]:
              for zeroMask in [false, true]:
                let
                  state = State(depth: (if kind == 1: 0 else: depth), target: depth,
                    phase: phase, rate: 1, threshold: (if kind == 2: 1 else: 0),
                    position: 0x2400, request: request)
                  expected = model(state)
                  mask = if zeroMask: 0 else: 1 shl (channel div 2)
                spc.install(channel, state)
                spc.ram[0x47] = mask.uint8
                spc.ram[0x1A] = inhibit.uint8
                spc.putWord(0x220 + channel, 0x100)
                spc.stack()
                spc.x = channel.uint8
                spc.psw = PswI or PswB
                let writes = spc.execute(TickEntry, [ReturnAddress], 2000)
                doAssert spc.sp == 0xF1 and spc.x.int == channel
                doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
                doAssert spc.ram[0x5E] == 0xA5
                spc.checkFields(channel, expected.state)
                if expected.output and (mask and inhibit) == 0:
                  doAssert writes == @[(0xF2'u16, (channel * 8 + 2).uint8),
                    (0xF3'u16, spc.ram[0x16]), (0xF2'u16, (channel * 8 + 3).uint8),
                    (0xF3'u16, spc.ram[0x17])]
                else: doAssert writes.len == 0
                inc totals.outputCalls

proc main() =
  ## Execute original and fresh byte-identical rebuilt driver code without speaker output.
  var totals: Totals
  for image in engineImages("bin/spc_pitch_modulation_extract"):
    var spc = newSpc()
    for i in 0 ..< DriverLength: spc.ram[DriverStart + i] = image[DriverPayload + i]
    spc.matrices(totals)
    spc.ramps(totals)
    spc.outputGuards(totals)
  echo &"SPC pitch modulation passed: {totals.setupCalls} setup calls, " &
    &"{totals.stageCalls} bounded stage entries, {totals.eventCalls} accepted-event " &
    &"entries, {totals.outputCalls} complete output-tail calls; " &
    &"{totals.rampContexts} repeated-ramp contexts (not additional calls)."

when isMainModule:
  main()
