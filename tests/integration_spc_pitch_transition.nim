## Verify pending pitch commands, accepted-event initialization and complete active transitions.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  Totals = object
    configurations, pendingStores, targets, initializations, copies, ticks, ramps, callers, fractions: int

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  ConversionEntry = 0x06BE'u16
  ModulationEntry = 0x0D7C'u16
  Guard = 0xA5'u8
  Streams = [0x4800, 0x48FF, 0xFFFE, 0xFFFF]
  Edges = [0, 1, 127, 128, 254, 255]
  Durations = [0, 1, 2, 3, 127, 255]

proc word(spc: Spc, address: int): int =
  ## Read an authored word with sixteen-bit address wrap.
  spc.ram[address and 65535].int + spc.ram[(address + 1) and 65535].int * 256

proc putWord(spc: var Spc, address, value: int) =
  ## Populate a synthetic word without using driver arithmetic.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address + 1) and 65535] = ((value shr 8) and 255).uint8

proc prepare(spc: var Spc, channel: int) =
  ## Guard channel state and provide the bootstrap zero word and saved channel.
  for address in 0 .. 0xEF: spc.ram[address] = Guard
  for address in 0x100 .. 0x3AF: spc.ram[address] = Guard
  spc.putWord(0x0E, 0)
  spc.ram[0x44] = channel.uint8
  spc.ram[0x47] = (1 shl (channel div 2)).uint8
  spc.ram[0x1A] = 0
  spc.iplEnabled = false

proc execute(spc: var Spc, entry, stop: uint16, budget = 120) =
  ## Run original instructions with a real caller frame, stack guards and forbidden I/O.
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E7] = Guard
  spc.ram[0x1F2] = Guard
  spc.sp = 0xEF
  spc.pc = entry
  var instructions = 0
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected hardware read ${address:04X}"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, &"unexpected hardware write ${address:04X}=${value:02X}"
    false
  while spc.pc != stop:
    doAssert instructions < budget, &"transition ${entry:04X} stalled at ${spc.pc:04X}"
    doAssert spc.sp in 0xE8'u8 .. 0xF1'u8
    spc.step()
    inc instructions
  doAssert not spc.stopped
  doAssert spc.sp == (if stop == ReturnAddress: 0xF1 else: 0xEF)
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E7] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil

proc checkArrays(spc: Spc, before: seq[uint8], allowed: openArray[int]) =
  ## Reject every neighboring channel write outside the named result fields.
  for address in 0x200 .. 0x3AF:
    if address notin allowed:
      doAssert spc.ram[address] == before[address - 0x200], &"changed field ${address:04X}"

proc quotient(delta, duration: int): int =
  ## Specify the existing signed divider's normal and zero-duration laws.
  let magnitude = if duration == 0: 65535 - abs(delta)
    else: abs(delta) * 256 div duration
  (if delta < 0: -magnitude else: magnitude) and 65535

proc configure(spc: var Spc, kind, channel, delay, duration, interval, stream,
    seed: int, totals: var Totals) =
  ## Compare dispatch, direct F1/F2 and arbitrary-mode shared setup using distinct A/Y.
  spc.prepare(channel)
  let
    dispatched = kind < 2
    mode = if kind == 4: seed elif kind in [0, 2]: 1 else: 0
  spc.putWord(0x30 + channel, stream)
  for index, value in (if dispatched: @[delay, duration, interval]
      else: @[duration, interval]):
    spc.ram[(stream + index) and 65535] = value.uint8
  let
    before = spc.ram[0x200 .. 0x3AF]
    beforeDp = spc.ram[0 .. 0xEF]
    status = PswI or PswB or PswH or PswV or PswC
    entry = if dispatched: 0x0943'u16 elif kind == 2: 0x0A68'u16
      elif kind == 3: 0x0A6C'u16 else: 0x0A6E'u16
  spc.a = (if dispatched: 0xF1 + kind elif kind == 4: seed else: delay xor 255).uint8
  spc.y = delay.uint8
  spc.x = channel.uint8
  spc.psw = status
  spc.execute(entry, ReturnAddress)
  doAssert spc.a.int == interval and spc.y.int == interval and spc.x.int == channel
  doAssert spc.ram[0x280 + channel].int == duration
  doAssert spc.ram[0x281 + channel].int == delay
  doAssert spc.ram[0x290 + channel].int == mode
  doAssert spc.ram[0x291 + channel].int == interval
  doAssert spc.word(0x30 + channel) == ((stream + (if dispatched: 3 else: 2)) and 65535)
  doAssert (spc.psw and (PswI or PswB or PswP or PswH or PswV)) ==
    (PswI or PswB or PswH or PswV)
  doAssert ((spc.psw and PswC) != 0) == not dispatched
  doAssert ((spc.psw and PswN) != 0) == (interval >= 128)
  doAssert ((spc.psw and PswZ) != 0) == (interval == 0)
  spc.checkArrays(before, [0x280 + channel, 0x281 + channel,
    0x290 + channel, 0x291 + channel])
  for address in 0 .. 0xEF:
    if address notin [0x30 + channel, 0x31 + channel]:
      doAssert spc.ram[address] == beforeDp[address]
  inc totals.configurations

proc pendingStore(spc: var Spc, channel, operand: int, direct: bool, totals: var Totals) =
  ## Prove that F3 dispatch clears only pending duration while direct entry stores A.
  spc.prepare(channel)
  spc.putWord(0x30 + channel, 0xFFFF)
  let
    before = spc.ram[0x200 .. 0x3AF]
    beforeDp = spc.ram[0 .. 0xEF]
  spc.a = (if direct: operand else: 0xF3).uint8
  spc.y = (operand xor 255).uint8
  spc.x = channel.uint8
  spc.psw = 0xDF
  spc.execute((if direct: 0x0A82'u16 else: 0x0943'u16), ReturnAddress)
  doAssert spc.ram[0x280 + channel].int == (if direct: operand else: 0)
  doAssert spc.a.int == (if direct: operand else: 0)
  doAssert spc.y.int == (if direct: operand xor 255 else: 0)
  doAssert spc.x.int == channel and spc.ram[0 .. 0xEF] == beforeDp
  doAssert spc.psw == (if direct: 0xDF'u8 else: PswI or PswB or PswH or PswV or PswZ)
  spc.checkArrays(before, [0x280 + channel])
  inc totals.pendingStores

proc checkFraction(spc: var Spc, channel, operand: int, direct: bool, totals: var Totals) =
  ## Feed actual F4 output into accepted-event setup without rewriting the source fraction.
  spc.prepare(channel)
  spc.putWord(0x30 + channel, 0xFFFF)
  spc.ram[0xFFFF] = operand.uint8
  spc.ram[0x280 + channel] = 0
  let before = spc.ram[0x200 .. 0x3AF]
  spc.a = (if direct: operand else: 0xF4).uint8
  spc.y = (operand xor 255).uint8
  spc.x = channel.uint8
  spc.psw = 0xDF
  spc.execute((if direct: 0x0AA8'u16 else: 0x0943'u16), ReturnAddress)
  doAssert spc.ram[0x381 + channel].int == operand
  doAssert spc.a.int == operand and spc.y.int == (if direct: operand xor 255 else: operand)
  doAssert spc.word(0x30 + channel) == (if direct: 0xFFFF else: 0)
  if direct: doAssert spc.psw == 0xDF
  else:
    doAssert (spc.psw and not (PswN or PswZ)) == (PswH or PswV or PswI or PswB)
    doAssert ((spc.psw and PswN) != 0) == (operand >= 128)
    doAssert ((spc.psw and PswZ) != 0) == (operand == 0)
  spc.checkArrays(before, [0x381 + channel])
  spc.ram[0x50] = 0
  spc.ram[0x2F0 + channel] = 0
  spc.a = 0xA4
  spc.y = 0xA4
  spc.x = channel.uint8
  spc.psw = PswI or PswB
  spc.execute(0x0654, ConversionEntry)
  doAssert spc.ram[0x381 + channel].int == operand
  doAssert spc.word(0x360 + channel) == 36 * 256 + operand
  doAssert spc.word(0x10) == 36 * 256 + operand
  doAssert spc.x.int == channel
  inc totals.fractions

proc checkTarget(spc: var Spc, channel, raw, current, duration: int, totals: var Totals) =
  ## Verify masking, unsigned target-minus-current sign and actual target/step stores.
  spc.prepare(channel)
  spc.ram[0x361 + channel] = current.uint8
  spc.ram[0xA0 + channel] = duration.uint8
  spc.ram[0x12] = 0x5A
  let
    target = raw and 127
    step = quotient(target - current, duration)
    before = spc.ram[0x200 .. 0x3AF]
  spc.a = raw.uint8
  spc.y = 0xC3
  spc.x = channel.uint8
  spc.psw = PswI or PswB or PswC
  spc.execute(0x0BA4, ReturnAddress)
  doAssert spc.ram[0x380 + channel].int == target
  doAssert spc.word(0x370 + channel) == step
  doAssert spc.ram[0x361 + channel].int == current
  doAssert spc.a.int == (step shr 8) and spc.y.int == (step shr 8)
  doAssert spc.x.int == channel
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  doAssert ((spc.psw and PswN) != 0) == (step >= 32768)
  doAssert ((spc.psw and PswZ) != 0) == (step < 256)
  spc.checkArrays(before, [0x380 + channel, 0x370 + channel, 0x371 + channel])
  inc totals.targets

proc initialize(spc: var Spc, channel, integer, fraction, delay, duration, interval,
    mode: int, acceptedEvent: bool, totals: var Totals) =
  ## Check the initialized state while preserving the actual command outputs on event paths.
  if not acceptedEvent:
    spc.prepare(channel)
    spc.ram[0x280 + channel] = duration.uint8
    spc.ram[0x281 + channel] = delay.uint8
    spc.ram[0x290 + channel] = mode.uint8
    spc.ram[0x291 + channel] = interval.uint8
  for (address, expected) in [(0x280 + channel, duration), (0x281 + channel, delay),
      (0x290 + channel, mode), (0x291 + channel, interval)]:
    doAssert spc.ram[address].int == expected
  spc.putWord(0x360 + channel, fraction + integer * 256)
  spc.ram[0x381 + channel] = fraction.uint8
  spc.ram[0x50] = ((integer - 36) and 255).uint8
  spc.ram[0x2F0 + channel] = 0
  let
    active = duration != 0
    current = if active and mode == 0: (integer - interval) and 255 else: integer
    target = (current + interval) and 127
    step = quotient(target - current, duration)
    before = spc.ram[0x200 .. 0x3AF]
    oldDelay = spc.ram[0xA1 + channel]
  spc.x = channel.uint8
  spc.a = 0xA4
  spc.y = 0xA4
  spc.psw = PswI or PswB
  spc.execute((if acceptedEvent: 0x0654'u16 else: 0x0696'u16), ConversionEntry)
  doAssert spc.ram[0xA0 + channel].int == duration
  doAssert spc.ram[0xA1 + channel] == (if active: delay.uint8 else: oldDelay)
  doAssert spc.word(0x360 + channel) == fraction + current * 256
  doAssert spc.word(0x10) == fraction + current * 256
  doAssert spc.ram[0x380 + channel].int == (if active: target else: Guard.int)
  doAssert spc.word(0x370 + channel) == (if active: step else: Guard.int * 257)
  doAssert spc.a.int == fraction and spc.y.int == (if active: step shr 8 else: 0xA4)
  doAssert spc.x.int == channel
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  doAssert ((spc.psw and PswN) != 0) == (fraction >= 128)
  doAssert ((spc.psw and PswZ) != 0) == (fraction == 0)
  var allowed = @[0x360 + channel, 0x361 + channel]
  if active: allowed.add [0x370 + channel, 0x371 + channel, 0x380 + channel]
  if acceptedEvent: allowed.add [0x2A0 + channel, 0x2D0 + channel]
  spc.checkArrays(before, allowed)
  inc totals.initializations

proc checkCopy(spc: var Spc, channel, position, status: int, totals: var Totals) =
  ## Verify the current reader's fraction-only N/Z and otherwise preserved registers/status.
  spc.prepare(channel)
  spc.putWord(0x360 + channel, position)
  spc.x = channel.uint8
  spc.y = 0xC3
  spc.psw = status.uint8
  spc.execute(0x0BBC, ReturnAddress)
  doAssert spc.word(0x10) == position
  doAssert spc.a.int == (position and 255) and spc.y == 0xC3 and spc.x.int == channel
  doAssert (spc.psw and not (PswN or PswZ)).int == (status and 0x7D)
  doAssert ((spc.psw and PswN) != 0) == ((position and 255) >= 128)
  doAssert ((spc.psw and PswZ) != 0) == ((position and 255) == 0)
  inc totals.copies

proc ramp(spc: var Spc, mode, duration, delay, interval: int, totals: var Totals) =
  ## Feed real commands into event setup and repeated original ticks, including F3 during activity.
  const Channel = 6
  let
    integer = 127
    fraction = 253
    current = if duration != 0 and mode == 0: (integer - interval) and 255 else: integer
    target = (current + interval) and 127
    step = quotient(target - current, duration)
  spc.configure((if mode == 1: 0 else: 1), Channel, delay, duration, interval, 0xFFFF, 0, totals)
  spc.initialize(Channel, integer, fraction, delay, duration, interval, mode, true, totals)
  var
    position = fraction + current * 256
    remaining = duration
    wait = if duration == 0: Guard.int else: delay
  for tick in 0 .. duration + delay + 1:
    let updates = remaining != 0 and wait == 0
    if remaining != 0:
      if wait != 0: dec wait
      else:
        dec remaining
        position = if remaining == 0: target * 256 else: (position + step) and 65535
    spc.x = Channel
    spc.psw = PswI or PswB
    spc.execute(0x0D60, ModulationEntry)
    doAssert spc.ram[0xA0 + Channel].int == remaining
    doAssert spc.ram[0xA1 + Channel].int == wait
    doAssert spc.word(0x360 + Channel) == position and spc.word(0x10) == position
    doAssert ((spc.ram[0x13] and 128) != 0) == updates
    doAssert spc.word(0x370 + Channel) == (if duration == 0: Guard.int * 257 else: step)
    doAssert spc.ram[0x380 + Channel].int == (if duration == 0: Guard.int else: target)
    inc totals.ticks
    if tick == 0:
      spc.a = 0xF3
      spc.x = Channel
      spc.execute(0x0943, ReturnAddress)
      doAssert spc.ram[0x280 + Channel] == 0
      doAssert spc.ram[0xA0 + Channel].int == remaining
      doAssert spc.ram[0xA1 + Channel].int == wait
  if duration != 0: doAssert position == target * 256
  inc totals.ramps

proc checkCaller(spc: var Spc, channel: int, preview: bool, totals: var Totals) =
  ## Preserve actual update/phase caller fixtures after retiring their temporary probe.
  spc.prepare(channel)
  for address in 0 .. 0xEF: spc.ram[address] = 0
  spc.ram[0x04] = 1
  spc.ram[0x44] = (channel xor 2).uint8
  spc.ram[0x5E] = 0x6A
  spc.ram[0x13] = 0xB5
  spc.ram[0xA0 + channel] = 2
  spc.ram[0xA1 + channel] = 0
  spc.putWord(0x360 + channel, 0x7F81)
  spc.putWord(0x370 + channel, 0x0101)
  spc.ram[0x380 + channel] = 0xC3
  spc.ram[0x51] = 127
  spc.putWord(0x30 + channel, 0x5000)
  spc.ram[0x70 + channel] = 2
  spc.ram[0x71 + channel] = 0
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1E7] = Guard
  spc.ram[0x1F2] = Guard
  spc.sp = 0xEF
  spc.x = channel.uint8
  spc.psw = PswI or PswB or PswC
  if preview:
    # The real phase entry pops this saved timer count before its native preview CALL.
    spc.ram[0x53] = 0
    spc.ram[0xC1 + channel] = 0
    spc.ram[0x91 + channel] = 0
    spc.ram[0x1EF] = 1
    spc.sp = 0xEE
  spc.pc = if preview: 0x05CD else: 0x07F9
  let stop = if preview: 0x0E13'u16 else: ModulationEntry
  var trace: seq[uint16]
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected caller port read ${address:04X}"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, &"unexpected caller port write ${address:04X}=${value:02X}"
    false
  while spc.pc != stop:
    doAssert trace.len < 300 and spc.sp in 0xE8'u8 .. 0xF1'u8
    trace.add spc.pc
    spc.step()
  let expectedSites = if preview: @[0x05E0'u16, 0x0DD0, 0x0DDF, 0x0DFC, 0x0BBC, 0x0E2B]
    else: @[0x08EA'u16, 0x0CF7, 0x0D60, 0x0BBC]
  var site = 0
  for address in trace:
    if site < expectedSites.len and address == expectedSites[site]: inc site
  doAssert site == expectedSites.len
  doAssert spc.sp == 0xED and spc.x.int == channel
  doAssert spc.word(0x10) == (if preview: 0x8000 else: 0x8082)
  doAssert spc.word(0x360 + channel) == (if preview: 0x7F81 else: 0x8082)
  doAssert spc.ram[0xA0 + channel].int == (if preview: 2 else: 1)
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E7] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil
  inc totals.callers

proc main() =
  ## Run independent original/rebuilt setup, helper and command-to-event-to-tick checks.
  var totals: Totals
  for image in engineImages("bin/spc_pitch_transition_extract"):
    var spc = newSpc()
    for index in 0 ..< DriverLength: spc.ram[DriverStart + index] = image[DriverPayload + index]
    for channel in countup(0, 14, 2):
      for operand in 0 .. 255:
        for stream in Streams:
          for kind in 0 .. 4:
            spc.configure(kind, channel, operand, operand xor 127,
              (operand * 73) and 255, stream, operand, totals)
        for direct in [false, true]:
          spc.pendingStore(channel, operand, direct, totals)
          spc.checkFraction(channel, operand, direct, totals)
    for first in 0 .. 255:
      for second in 0 .. 255:
        let channel = ((first xor second) and 7) * 2
        spc.checkTarget(channel, first, second, Durations[(first + second) mod Durations.len], totals)
        spc.checkTarget(channel, second, first xor second, first, totals)
        for mode in [0, 1]:
          spc.initialize(channel, first, first xor second, second,
            Durations[(first + second) mod Durations.len], second, mode, false, totals)
    for duration in 0 .. 255:
      for integer in Edges:
        for interval in Edges:
          for mode in [0, 1]:
            let
              channel = ((duration xor interval) and 7) * 2
              delay = (duration + interval) and 255
            spc.configure((if mode == 1: 0 else: 1), channel, delay,
              duration, interval, 0xFFFF, 0, totals)
            spc.initialize(channel, integer, (integer xor duration) and 255,
              delay, duration, interval, mode, true, totals)
    for mode in 0 .. 255:
      for duration in [0, 1, 255]:
        for interval in [0, 128, 255]:
          let channel = (mode and 7) * 2
          spc.configure(4, channel, mode xor 255, duration, interval, 0x48FF, mode, totals)
          spc.initialize(channel, 128, mode, mode xor 255, duration,
            interval, mode, true, totals)
    for channel in countup(0, 14, 2):
      for fraction in 0 .. 255:
        for integer in [0, 127, 128, 255]:
          for status in [0, 0xDF]:
            spc.checkCopy(channel, fraction + integer * 256, status, totals)
    for mode in [0, 1]:
      for duration in Durations:
        for delay in [0, 1, 2, 255]:
          for interval in [0, 1, 127, 255]:
            spc.ramp(mode, duration, delay, interval, totals)
    for channel in countup(0, 14, 2):
      for preview in [false, true]: spc.checkCaller(channel, preview, totals)
  echo &"SPC pitch transitions passed: {totals.configurations} configuration calls, " &
    &"{totals.pendingStores} F3 calls, {totals.targets} target helpers, " &
    &"{totals.initializations} event initializations, {totals.copies} current readers " &
    &"and {totals.ticks} actual ticks in {totals.ramps} complete ramp contexts; " &
    &"{totals.callers} original upstream caller traces and {totals.fractions} F4-to-event chains."

when isMainModule:
  main()
