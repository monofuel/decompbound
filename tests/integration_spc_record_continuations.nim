## Record-progress arithmetic, byte consumption and complete original initialization calls.
## Unclaimed finish/forward targets remain explicit entry observations, not fake returns.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  ReturnAddress = 0x1E00'u16
  Guard = 0xA5'u8
  StableFlags = PswP or PswI or PswB or PswH or PswV
  Stops = [ReturnAddress, 0x1491'u16, 0x1557'u16, 0x148B'u16, 0x0FB7'u16]

type
  Totals = object
    ticks, shared, records, setters, external, initialized, finishEntries: int
  State = tuple[low, high: seq[uint8]]
  Prediction = object
    state: State
    value: int
    status: uint8
  Observation = object
    exit: uint16
    writes: seq[(uint16, uint8)]
    trace: seq[uint16]

proc prepare(spc: var Spc, slot: int, status = 0xDF'u8) =
  ## Author distinct local state while preserving original code and runtime tables.
  for address in 0 .. 0xEF:
    spc.ram[address] = ((address * 37 + 19) and 255).uint8
  for address in 0x400 .. 0x4FF:
    spc.ram[address] = ((address * 19 + 7) and 255).uint8
  for address in 0x1E8 .. 0x1F2:
    spc.ram[address] = Guard
  spc.ram[0x1E0] = Guard
  spc.ram[0x1F0] = 0
  spc.ram[0x1F1] = 0x1E
  spc.ram[0x2E] = slot.uint8
  spc.ram[0x2F] = (slot * 2).uint8
  spc.ram[0x450 + slot] = 1
  spc.a = 0xA3
  spc.x = 0xA6
  spc.y = 0xD2
  spc.psw = status
  spc.sp = 0xEF

proc snapshot(spc: Spc): State =
  ## Capture only synthetic local fields for complete neighbor checks.
  (spc.ram[0 .. 0xEF], spc.ram[0x400 .. 0x4FF])

proc nz(value: int): uint8 =
  ## Predict byte N/Z independently of the CPU core.
  (if value == 0: PswZ else: 0'u8) or (if value >= 128: PswN else: 0'u8)

proc cmpFlags(value, other: int): uint8 =
  ## Model unsigned byte comparison including wrapped subtraction flags.
  nz((value - other) and 255) or (if value >= other: PswC else: 0'u8)

proc adcFlags(value, addend: int): uint8 =
  ## Model carry, half-carry and signed overflow for a cleared-carry addition.
  let sum = (value + addend) and 255
  (if value + addend > 255: PswC else: 0'u8) or
    (if (value and 15) + (addend and 15) > 15: PswH else: 0'u8) or
    (if ((not (value xor addend)) and (value xor sum) and 128) != 0: PswV else: 0'u8)

proc predictTick(spc: Spc, shared = false): Prediction =
  ## Predict the already-initialized domain without interpreting any original instruction bytes.
  result.state = spc.snapshot()
  let
    slot = spc.ram[0x2E].int
    limitA = spc.ram[0x4BC + slot].int
    limitB = spc.ram[0x4C0 + slot].int
    mode = spc.ram[0x49C + slot].int
    mask = spc.ram[0x4D7].int
  var
    value = (spc.ram[0x4B8 + slot].int + (if shared: 0 else: 1)) and 255
    carry = false
  if shared or value == 1:
    if shared or mode == 1:
      result.state.high[0x9C + slot] = 0x81
      carry = if shared: (spc.psw and PswC) != 0 else: true
    else:
      carry = mode >= 0x81
    if shared or mode != 0x81:
      doAssert spc.ram[0x450 + slot] != 0
      if spc.ram[0x4C8 + slot] == 0:
        result.state.low[0x45] = (spc.ram[0x45].int or mask).uint8
  elif value == limitA:
    carry = value == 255
    value = if value == 255: 254 else: 0
  else:
    carry = value >= limitB
    if value == limitB and (mode and 1) == 0:
      let queued = spc.ram[0x46].int or mask
      result.state.low[0x46] = queued.uint8
      if queued == 0:
        value = 0
        carry = false
  result.state.high[0xB8 + slot] = value.uint8
  result.value = value
  result.status = (spc.psw and StableFlags) or nz(value) or (if carry: PswC else: 0'u8)

proc execute(spc: var Spc, entry: int, completeInit = false): Observation =
  ## Stop only at named external boundaries or a real native return; never patch callees.
  var observed: Observation
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected I/O read {address:04X}"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address in [0xF2'u16, 0xF3'u16]
    observed.writes.add((address, value))
    false
  spc.pc = entry.uint16
  while spc.pc notin Stops or (completeInit and spc.pc == 0x1557):
    doAssert observed.trace.len < (if completeInit: 2000 else: 300)
    doAssert spc.sp in (if completeInit: 0xE1'u8 else: 0xEB'u8) .. 0xF1'u8
    observed.trace.add spc.pc
    spc.step()
  doAssert not spc.stopped
  doAssert spc.ram[(if completeInit: 0x1E0 else: 0x1E8)] == Guard
  doAssert spc.ram[0x1F2] == Guard
  doAssert spc.ram[0x1F0] == 0 and spc.ram[0x1F1] == 0x1E
  observed.exit = spc.pc
  spc.readHook = nil
  spc.writeHook = nil
  observed

proc checkState(spc: Spc, state: State) =
  ## Verify intended updates and every unaffected local neighbor.
  doAssert spc.ram[0 .. 0xEF] == state.low
  doAssert spc.ram[0x400 .. 0x4FF] == state.high

proc checkTick(spc: var Spc, slot, old, limitA, limitB, mode, mask, queued,
    gate: int, shared = false) =
  ## Exercise the complete finite tick domain that does not call external initialization.
  spc.prepare(slot, (if (old and 1) == 0: 0'u8 else: 0xDF'u8))
  spc.ram[0x4B8 + slot] = old.uint8
  spc.ram[0x4BC + slot] = limitA.uint8
  spc.ram[0x4C0 + slot] = limitB.uint8
  spc.ram[0x49C + slot] = mode.uint8
  spc.ram[0x4D7] = mask.uint8
  spc.ram[0x46] = queued.uint8
  spc.ram[0x4C8 + slot] = gate.uint8
  if shared: spc.x = slot.uint8
  let expected = spc.predictTick(shared)
  let observed = spc.execute(if shared: 0x13D8 else: 0x13A0)
  doAssert observed.exit == ReturnAddress and observed.writes.len == 0 and spc.sp == 0xF1
  spc.checkState(expected.state)
  doAssert spc.a.int == expected.value and spc.x.int == slot and spc.y == 0xD2
  doAssert spc.psw == expected.status

proc addPort(writes: var seq[(uint16, uint8)], register, value: int) =
  ## Append an independently predicted raw DSP address/data transaction.
  writes.add((0xF2'u16, register.uint8))
  writes.add((0xF3'u16, value.uint8))

proc checkMain(spc: var Spc, slot, token, index, base, controlGate, period,
    counter: int, zeroProgress = false, stream = 0x5000) =
  ## Predict byte consumption and execute original writers through their natural returns.
  spc.prepare(slot, (if (token and 1) == 0: 0'u8 else: 0xDF'u8))
  spc.ram[0x4B8 + slot] = 1
  spc.ram[0x4BC + slot] = (if zeroProgress: 2 else: 0)
  spc.ram[0x4C0 + slot] = 0
  spc.ram[0x49C + slot] = 0
  spc.ram[0x4C8 + slot] = 1
  spc.ram[0xD0 + slot] = index.uint8
  spc.ram[0xD4 + slot] = counter.uint8
  spc.ram[0x2C] = period.uint8
  spc.ram[0x26] = (stream and 255).uint8
  spc.ram[0x27] = (stream shr 8).uint8
  spc.ram[0x28] = 0
  spc.ram[0x29] = (if controlGate == 0: 0 else: 0x60)
  spc.ram[(stream + index) and 65535] = token.uint8
  spc.ram[0x6000 + index] = (token xor 0xA5).uint8
  spc.ram[0x4D5] = base.uint8
  spc.ram[0x4D7] = (16 shl slot).uint8
  spc.ram[0x1A] = 255
  spc.ram[0x1B] = 255
  let predicted = spc.predictTick()
  var
    expected = predicted.state
    writes: seq[(uint16, uint8)]
    expectedA = predicted.value
    expectedY = 0xD2
    flags = predicted.status
    exit = ReturnAddress
  if predicted.value == 0:
    exit = 0x1491
  else:
    let next = (counter + 1) and 255
    expected.low[0xD4 + slot] = next.uint8
    expectedA = next
    flags = (flags and StableFlags) or cmpFlags(next, period)
    if next == period:
      expected.low[0xD4 + slot] = 0
      expected.low[0xD0 + slot] = ((index + 1) and 255).uint8
      expectedY = index
      expectedA = token
      flags = (flags and StableFlags) or cmpFlags(token, 0)
      if token == 0:
        exit = 0x1491
      elif token == 127:
        expected.low[0x46] = (expected.low[0x46].int or (16 shl slot)).uint8
        writes.addPort(base, 0)
        writes.addPort((base + 1) and 255, 0)
        expectedA = 0
        expectedY = (base + 1) and 255
        flags = (flags and StableFlags) or PswC or nz(expectedY)
      else:
        writes.addPort((base + 7) and 255, token)
        flags = (flags and (PswP or PswI or PswB)) or adcFlags(base, 7)
        if controlGate == 0:
          expectedA = 0
        else:
          expected.low[0x48] = ((token xor 0xA5) and 31).uint8
          expected.low[0x49] = (expected.low[0x49].int or (16 shl slot)).uint8
          expectedA = expected.low[0x49].int
        flags = flags or nz(expectedA)
  let observed = spc.execute(0x134E)
  doAssert observed.exit == exit and observed.writes == writes
  spc.checkState(expected)
  doAssert spc.a.int == expectedA and spc.x.int == slot and spc.y.int == expectedY
  doAssert spc.psw == flags, &"main flags token={token} base={base} gate={controlGate}: {spc.psw} vs {flags}"
  doAssert spc.sp == (if exit == ReturnAddress: 0xF1 else: 0xEF)
  doAssert (0x1124'u16 in observed.trace) == (writes.len == 2)
  doAssert (0x1144'u16 in observed.trace) == (writes.len == 4)

proc checkCompleteInit(spc: var Spc, slot, voice, variant: int, throughMain: bool) =
  ## Execute real 1557/instrument/stereo/pitch helpers against authored constant curves.
  spc.prepare(slot)
  let
    channel = voice * 2
    voiceBase = voice * 16
    record = [0x5000, 0x50FD, 0x50FE, 0x50FF][variant and 3]
    payload = (record and 0xFF00) or ((record + 2) and 255)
    gain = [0, 1, 127, 255][variant and 3]
    phase = ((variant shr 2) and 3) shl 6
    pan = [0, 10, 20][(voice + variant) mod 3]
    pitchHigh = [0, 12, 72, 128][(voice + variant) and 3]
    pitchLow = (variant * 37) and 255
    multiplier = [0, 0x0180, 0x7FFF, 0xFFFF][(slot + variant) and 3]
    override = (variant and 1) != 0
    optional = (variant and 2) != 0
    noisy = (variant and 4) != 0
    mode = if (variant and 8) != 0: 1 else: 0
    outputBase = [voiceBase, 0x7C, 0xFC, 0xFF][variant and 3]
    mask = 1 shl voice
    oldGain = 0xA5
    oldPhase = 0x5A
    q = ((pitchHigh * 2) and 255) div 24
    preScale = 0x8ACE shr (6 - q)
    scaled = ((preScale * multiplier) shr 8) and 65535
  spc.ram[0x2A] = (record and 255).uint8
  spc.ram[0x2B] = (record shr 8).uint8
  for index, value in [0, gain, phase or pan, pitchHigh, pitchLow]:
    spc.ram[(payload + index) and 65535] = value.uint8
  for index, value in [0x35, 0xA2, 0x3C, 0x7F, multiplier shr 8, multiplier and 255]:
    spc.ram[0x6E00 + index] = value.uint8
  for index in 0 .. 21: spc.ram[0xE73 + index] = 128
  for index in 0 .. 12:
    spc.ram[0xEBC + 2 * index] = 0x67
    spc.ram[0xEBD + 2 * index] = 0x45
  spc.ram[0x4B8 + slot] = 0
  spc.ram[0x49C + slot] = mode.uint8
  spc.ram[0x450 + slot] = 0
  spc.ram[0x454 + slot] = optional.uint8
  spc.ram[0x458 + slot * 2] = 0x31
  spc.ram[0x459 + slot * 2] = 0xE2
  spc.ram[0x4C8 + slot] = 0
  spc.ram[0x4CC + slot] = noisy.uint8
  spc.ram[0x4DF] = channel.uint8
  spc.ram[0x4D5] = outputBase.uint8
  spc.ram[0x4D6] = (255 xor mask).uint8
  spc.ram[0x4D7] = mask.uint8
  spc.ram[0x431] = override.uint8
  spc.ram[0x321 + channel] = oldGain.uint8
  spc.ram[0x351 + channel] = oldPhase.uint8
  spc.ram[0x49] = ((variant * 73 + slot) and 255).uint8
  spc.ram[0x1A] = 255
  spc.ram[0x1B] = 255
  spc.ram[0xD4 + slot] = 1
  spc.ram[0x2C] = 1
  var
    expected = spc.snapshot()
    channels = spc.ram[0x200 .. 0x3FF]
    writes: seq[(uint16, uint8)]
  expected.high[0xB8 + slot] = 1
  if mode == 1: expected.high[0x9C + slot] = 0x81
  expected.high[0x50 + slot] = 1
  expected.high[0xE0 + channel] = oldGain.uint8
  expected.high[0xF0 + channel] = oldPhase.uint8
  expected.high[0x33] = (if override: 10 else: pan).uint8
  expected.low[0x22] = (payload and 255).uint8
  expected.low[0x23] = (payload shr 8).uint8
  expected.low[0x47] = 0
  expected.low[0x49] = (if noisy: expected.low[0x49].int or mask
    else: expected.low[0x49].int and (255 xor mask)).uint8
  expected.low[0x10] = pitchLow.uint8
  expected.low[0x11] = pitchHigh.uint8
  expected.low[0x12] = (voiceBase + 2).uint8
  expected.low[0x14] = (preScale and 255).uint8
  expected.low[0x15] = (preScale shr 8).uint8
  expected.low[0x16] = (scaled and 255).uint8
  expected.low[0x17] = (scaled shr 8).uint8
  expected.low[0x45] = (expected.low[0x45].int or mask).uint8
  channels[0x20 + channel] = (multiplier and 255).uint8
  channels[0x21 + channel] = (multiplier shr 8).uint8
  channels[0x121 + channel] = gain.uint8
  channels[0x151 + channel] = phase.uint8
  for index, value in [0x35, 0xA2, 0x3C, 0x7F]: writes.addPort(voiceBase + 4 + index, value)
  let magnitude = gain div 2
  writes.addPort(voiceBase, (if (phase and 128) != 0: -magnitude else: magnitude) and 255)
  writes.addPort(voiceBase + 1, (if (phase and 64) != 0: -magnitude else: magnitude) and 255)
  writes.addPort(voiceBase + 2, scaled and 255)
  writes.addPort(voiceBase + 3, scaled shr 8)
  let
    mid = (((multiplier and 255) * (preScale shr 8)) +
      ((multiplier shr 8) * (preScale and 255))) and 65535
    other = ((((multiplier shr 8) * (preScale shr 8)) and 255) shl 8) or
      (((multiplier and 255) * (preScale and 255)) shr 8)
  var
    flags = 0xDF'u8 and (PswP or PswI or PswB)
    expectedY = voiceBase + 3
  if ((other and 4095) + (mid and 4095)) > 4095: flags = flags or PswH
  if ((not (other xor mid)) and (other xor scaled) and 32768) != 0: flags = flags or PswV
  if optional:
    expected.low[0x20] = ((outputBase + 5) and 255).uint8
    writes.addPort((outputBase + 5) and 255, 0x31)
    writes.addPort((outputBase + 6) and 255, 0xE2)
    expectedY = (outputBase + 6) and 255
    flags = (flags and (PswP or PswI or PswB)) or adcFlags(outputBase, 5)
  let expectedA = if throughMain: 2 else: 1
  if throughMain:
    expected.low[0xD4 + slot] = 2
    flags = (flags and not PswC) or PswC
  let observed = spc.execute((if throughMain: 0x134E else: 0x13A0), true)
  doAssert observed.exit == ReturnAddress and spc.sp == 0xF1
  doAssert observed.writes == writes, &"init writes slot={slot} voice={voice} variant={variant}"
  spc.checkState(expected)
  doAssert spc.ram[0x200 .. 0x3FF] == channels
  doAssert spc.a.int == expectedA and spc.x.int == slot and spc.y.int == expectedY
  doAssert spc.psw == flags
  for entry in [0x1557'u16, 0x962, 0xC95, 0x6D4, 0x70E, 0x733]:
    doAssert entry in observed.trace
  doAssert (0x110D'u16 in observed.trace) == optional

proc checkImage(image: seq[uint8]): Totals =
  ## Exercise independent bounded oracles against unpatched original or rebuilt code.
  var spc = newSpc()
  for address in 0x500 ..< 0x468B: spc.ram[address] = image[DriverMap + address]
  var ticks, shared, records, setters, external, initialized, finishEntries = 0
  for old in 0 .. 255:
    for limit in 0 .. 255:
      spc.checkTick((old xor limit) and 3, old, limit, (old + limit) and 255,
        old xor limit, (old + limit) and 255, old xor limit, limit and 1)
      inc ticks
  for old in 0 .. 255:
    let next = (old + 1) and 255
    for mode in [0, 1, 0x80, 0x81, 0xFE, 0xFF]:
      for mask in [0, 1, 128]:
        for queued in [0, 1, 128]:
          for limitA in [next, next xor 255]:
            for limitB in [next, next xor 255]:
              spc.checkTick(old and 3, old, limitA, limitB, mode, mask, queued, old and 1)
              inc ticks
      spc.checkTick(old and 3, old, 0, 0, mode, 128, 0, old and 1, true)
      inc shared
  for token in 0 .. 255:
    for slot in 0 .. 3:
      for index in [0, 1, 127, 255]:
        for base in [0, 79, 249, 255]:
          for gate in [0, 1]:
            spc.checkMain(slot, token, index, base, gate, 1, 0)
            inc records
            if spc.pc == 0x1491: inc finishEntries
  for slot in 0 .. 3:
    for period in 0 .. 255:
      spc.checkMain(slot, 42, 255, 255, 1, period, period)
      if spc.pc == 0x1491: inc finishEntries
      spc.checkMain(slot, 42, 255, 255, 1, period, (period - 1) and 255)
      if spc.pc == 0x1491: inc finishEntries
      spc.checkMain(slot, 0, 1, 0, 1, period, 0, true)
      if spc.pc == 0x1491: inc finishEntries
      inc records, 3
    for index in [0, 1, 128]:
      spc.checkMain(slot, 42, index, 255, 1, 1, 0, stream = 0xFFFF)
      inc records
      if spc.pc == 0x1491: inc finishEntries
  for slot in 0 .. 3:
    for value in 0 .. 255:
      spc.prepare(slot, value.uint8)
      spc.x = slot.uint8
      spc.a = value.uint8
      let before = spc.snapshot()
      var expected = before
      expected.high[0x9C + slot] = value.uint8
      let observed = spc.execute(0x1394)
      spc.checkState(expected)
      doAssert observed.exit == ReturnAddress and observed.writes.len == 0
      doAssert spc.a.int == value and spc.x.int == slot and spc.y == 0xD2 and spc.psw == value.uint8
      inc setters
      spc.prepare(slot, value.uint8)
      spc.x = slot.uint8
      spc.a = value.uint8
      spc.y = (value xor 255).uint8
      expected = spc.snapshot()
      expected.high[0xBC + slot] = value.uint8
      expected.high[0xC0 + slot] = (value xor 255).uint8
      discard spc.execute(0x1398)
      spc.checkState(expected)
      doAssert spc.a.int == (value xor 255) and spc.x.int == slot and spc.y.int == (value xor 255)
      doAssert spc.psw == ((value.uint8 and not (PswN or PswZ)) or nz(value xor 255))
      inc setters
  for slot in 0 .. 3:
    spc.prepare(slot)
    spc.ram[0x4B8 + slot] = 0
    spc.ram[0x49C + slot] = 0
    spc.ram[0x450 + slot] = 0
    let observed = spc.execute(0x13A0)
    doAssert observed.exit == 0x1557 and observed.writes.len == 0
    doAssert spc.ram[0x450 + slot] == 1 and spc.ram[0x4B8 + slot] == 1
    doAssert spc.sp == 0xED and spc.ram[0x1EE] == 0xF6 and spc.ram[0x1EF] == 0x13
    inc external
  for (entry, target) in [(0x1348, 0x148B), (0x134B, 0xFB7)]:
    spc.prepare(0)
    let before = spc.snapshot()
    let observed = spc.execute(entry)
    spc.checkState(before)
    doAssert observed.exit.int == target and spc.sp == 0xEF and observed.trace == @[entry.uint16]
    doAssert observed.writes.len == 0
    inc external
  for slot in 0 .. 3:
    for voice in 0 .. 7:
      for variant in 0 .. 15:
        spc.checkCompleteInit(slot, voice, variant, false)
        spc.checkCompleteInit(slot, voice, variant, true)
        inc initialized, 2
  Totals(ticks: ticks, shared: shared, records: records, setters: setters,
    external: external, initialized: initialized, finishEntries: finishEntries)

proc main() =
  ## Require original and fresh byte-identical rebuilt images and report real execution counts.
  var totals: Totals
  for image in engineImages("bin/spc_record_continuations_extract"):
    let checked = checkImage(image)
    totals.ticks += checked.ticks
    totals.shared += checked.shared
    totals.records += checked.records
    totals.setters += checked.setters
    totals.external += checked.external
    totals.initialized += checked.initialized
    totals.finishEntries += checked.finishEntries
  echo &"SPC record continuations passed: {totals.ticks} finite ticks, {totals.shared} shared initialization entries, {totals.records} record paths ({totals.finishEntries} stop at unclaimed finish), {totals.setters} setters, {totals.external} preserved-frame external entries and {totals.initialized} complete initialization chains."

when isMainModule:
  main()
