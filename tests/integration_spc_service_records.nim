## Full resident service passes with produced record state and actual APU MMIO hooks.
## Calls stop at $05C6: no saved timer byte, wall-clock cadence or audio output is invented.
import
  std/strformat,
  decompbound/[apu, spc700],
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  Kinds = [0, 2, 4, 6, 8, 10, 12, 14, 16]
  Guard = 0xA5'u8
  Tables = [0, 0x17D5, 0x17C5, 0x16C7]
  TopCalls = [0x1609, 0x2DAB, 0x2DF3, 0x2DD5, 0x11DC, 0x635,
    0x2E1D, 0x11BA, 0x635, 0x1198, 0x635]
  NativeFadeStep = (-((0xC0 - 16) * 256 div 24)) and 65535
    # The authored master level 192 approaches 16 over 24 ticks.

type
  Event = tuple[direction: char, address: uint16, value: uint8]
  Lookup = tuple[port, kind: int]
  Observation = object
    events: seq[Event]
    calls: seq[int]
    lookups: seq[Lookup]
    consumed: array[4, int]
    initializers, ticks, parsers, finishes, nativeReturns, arms, clears: int
    instrumentUpdates, panUpdates, gainUpdates, volumeUpdates, envelopes: int
  Stage = enum
    idle, install, initialize, progress, parseMarker, finish,
    extendedRelease, nativeArm, nativeContinue, expire
  Totals = object
    scenarios, passes, installations, initializations, parserMarkers: int
    finishes, nativeCallbacks, expiries, retargetLookups: int

proc putWord(spc: var Spc, address, value: int) =
  ## Store a tiny authored structural pointer rather than a captured record.
  spc.ram[address] = (value and 255).uint8
  spc.ram[address + 1] = ((value shr 8) and 255).uint8

proc word(spc: Spc, address: int): int =
  ## Read an independently asserted little-endian state field.
  spc.ram[address].int + 256 * spc.ram[address + 1].int

proc parserKind(kind: int): bool =
  ## Identify the four supported raw offsets that share the stream-parser continuation.
  kind in [4, 6, 10, 12]

proc retargetKind(kind: int): bool =
  ## Identify supported raw offsets with the real port-two retarget prelude.
  kind in [10, 12]

proc phaseStage(kind, pass: int): Stage =
  ## Predict finite authored-record progress from its configured limits, not CPU instructions.
  if pass == 1: return install
  if pass == 2: return initialize
  if kind == 8:
    if pass == 3: return nativeArm
    if pass in 4 .. 26: return nativeContinue
    if pass == 27: return expire
  elif parserKind(kind):
    if pass == 5: return parseMarker
    if pass == 9: return finish
    if pass in 3 .. 8: return progress
  elif kind in [14, 16]:
    if pass == 3: return extendedRelease
    if pass == 4: return finish
  else:
    if pass == 3: return progress
    if pass == 4: return finish
  idle

proc addWrite(events: var seq[Event], address, value: int) =
  ## Append one expected MMIO store.
  events.add(('w', address.uint16, value.uint8))

proc addDsp(events: var seq[Event], register, value: int) =
  ## Specify ordered DSP register writes without invoking its sample generator.
  events.addWrite(0xF2, register)
  events.addWrite(0xF3, value and 255)

proc instrumentWrites(events: var seq[Event], base: int) =
  ## Publish the authored sample record's four raw register values.
  for offset, value in [0x23, 0x81, 0x62, 0x43]:
    events.addDsp(base + 4 + offset, value)

proc stereoWrites(events: var seq[Event], base, gain, phase: int) =
  ## The authored constant curve makes each magnitude floor(gain*128/256).
  let magnitude = gain div 2
  events.addDsp(base, if (phase and 128) != 0: -magnitude else: magnitude)
  events.addDsp(base + 1, if (phase and 64) != 0: -magnitude else: magnitude)

proc expectedOutput(kind, port, phase: int, stage: Stage): seq[Event] =
  ## Predict only this finite fixture's real output; record finish restores saved fields.
  let
    base = (port + 4) * 16
    baselinePhase = phase xor 0xC0
  case stage
  of initialize:
    result.instrumentWrites(base)
    result.stereoWrites(base, 156, phase)
    # Constant word $4567 doubles to $8ACE. Raw integer 12 gives quotient1;
    # extended integer1 gives quotient0. The authored multiplier is exactly1.
    let pitch = if kind in [14, 16]: 0x8ACE shr 6 else: 0x8ACE shr 5
    result.addDsp(base + 2, pitch and 255)
    result.addDsp(base + 3, pitch shr 8)
    if kind in [14, 16]:
      result.addDsp(base + 5, 0)
      result.addDsp(base + 6, 0)
      result.addDsp(base + 7, 0x23)
  of parseMarker:
    # E0 selects instrument0; E1 consumes control4A with old gain156;
    # ED consumes gain100 with that newly produced control, then C9 returns.
    result.instrumentWrites(base)
    result.stereoWrites(base, 156, 0x40)
    result.stereoWrites(base, 100, 0x40)
  of extendedRelease:
    result.addDsp(base, 0)
    result.addDsp(base + 1, 0)
  of finish:
    result.stereoWrites(base, 64, baselinePhase)
    result.instrumentWrites(base)
  else:
    discard

proc fixture(image: seq[uint8], kind, port, phase: int): Apu =
  ## Author disjoint records/tables/curves once; later passes never rewrite driver state.
  result = newApu()
  for address in DriverStart ..< DriverStart + DriverLength:
    result.spc.ram[address] = image[DriverMap + address]
  for address in 0 .. 0x4FF:
    result.spc.ram[address] = 0
  for address in [0x1D0, 0x1F0, 0x1F1, 0x1F2]:
    result.spc.ram[address] = Guard
  result.spc.sp = 0xEF
  result.spc.psw = 0xDF
  result.spc.ram[0x19] = 0x55
  result.spc.ram[0x44] = 14
  result.spc.ram[0x53] = 0x34
  result.spc.ram[0x59] = 0xC0
  for voice in 0 .. 7:
    let channel = voice * 2
    result.spc.ram[0x221 + channel] = 1
    result.spc.ram[0x321 + channel] = 64
    result.spc.ram[0x331 + channel] = 10
  result.spc.ram[0x351 + (port + 4) * 2] = (phase xor 0xC0).uint8
  for offset, value in [0x23, 0x81, 0x62, 0x43, 1, 0]:
    result.spc.ram[0x6E00 + offset] = value.uint8
  for index in 0 .. 21:
    result.spc.ram[0xE73 + index] = 128
  for index in 0 .. 12:
    result.spc.putWord(0xEBC + 2 * index, 0x4567)
  for slot in 1 .. 3:
    result.spc.ram[0x4D0 + slot] = 3
    result.spc.putWord(Tables[slot], 0x148A)
  let
    pointer = 0x5000 + kind * 256 + port * 32
    firstKind = if kind == 8: 0 else: kind
    limit = if parserKind(kind) or kind in [14, 16]: 4 else: 3
    state = [limit, 2, 0, 156, phase or 10, 12, 0x35]
  result.spc.putWord(Tables[port], pointer)
  result.spc.putWord(Tables[port] + 2, 0x15F6)
  result.spc.ram[pointer - 1] = firstKind.uint8
  if parserKind(kind):
    let record = [0, 156, phase or 10, 0x35, 0x7F, 12]
    for offset, value in record:
      result.spc.ram[pointer + offset] = value.uint8
    for offset, value in [0xE0, 0, 0xE1, 0x4A, 0xED, 100, 0xC9, 0]:
      result.spc.ram[pointer + 6 + offset] = value.uint8
    if retargetKind(kind): result.spc.putWord(pointer - 3, 0x148A)
  else:
    for offset, value in state:
      result.spc.ram[pointer + offset] = value.uint8
    if kind in [14, 16]:
      result.spc.putWord(pointer - 5, 0x6A00)
      result.spc.putWord(pointer - 3, 0x6800)
      result.spc.ram[pointer + 5] = 1
      result.spc.ram[pointer + 6] = 1
      for offset, value in [0x23, 0x7F, 0]:
        result.spc.ram[0x6800 + offset] = value.uint8
      result.spc.ram[0x6A00] = 0x1D

proc runPass(machine: Apu): Observation =
  ## Execute the original entire resident pass with real APU hooks and no timer/frame tail.
  var observed: Observation
  let
    originalRead = machine.spc.readHook
    originalWrite = machine.spc.writeHook
  machine.spc.readHook = proc(address: uint16): int =
    doAssert address in [0xF5'u16, 0xF6, 0xF7]
    result = originalRead(address)
    observed.events.add(('r', address, result.uint8))
  machine.spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address in [0xF1'u16, 0xF2, 0xF3, 0xF5, 0xF6, 0xF7]
    observed.events.add(('w', address, value))
    originalWrite(address, value)
  machine.spc.pc = 0x596
  var instructions = 0
  while machine.spc.pc != 0x5C6:
    doAssert instructions < 2500, &"service stalled at {machine.spc.pc:04X}"
    doAssert machine.spc.sp in 0xD1'u8 .. 0xEF'u8
    let pc = machine.spc.pc.int
    if pc in TopCalls: observed.calls.add pc
    case pc
    of 0x11DC: observed.consumed[3] = machine.spc.ram[0x4B3].int
    of 0x11BA: observed.consumed[2] = machine.spc.ram[0x4B2].int
    of 0x1198: observed.consumed[1] = machine.spc.ram[0x4B1].int
    of 0x1258: observed.lookups.add((machine.spc.ram[0x2E].int, machine.spc.x.int))
    of 0x1557: inc observed.initializers
    of 0x13A0: inc observed.ticks
    of 0xFB7: inc observed.parsers
    of 0x1491: inc observed.finishes
    of 0x148A: inc observed.nativeReturns
    of 0x15F6: inc observed.arms
    of 0x1438: inc observed.clears
    of 0x1130: inc observed.instrumentUpdates
    of 0x10B6: inc observed.panUpdates
    of 0x1124: inc observed.gainUpdates
    of 0x1144: inc observed.volumeUpdates
    of 0x110D: inc observed.envelopes
    else: discard
    machine.spc.step()
    inc instructions
  machine.spc.readHook = originalRead
  machine.spc.writeHook = originalWrite
  doAssert not machine.spc.stopped and machine.spc.sp == 0xEF
  for address in [0x1D0, 0x1F0, 0x1F1, 0x1F2]:
    doAssert machine.spc.ram[address] == Guard
  observed

proc checkScenario(image: seq[uint8], kind, port, phase: int): Totals =
  ## Follow produced state through complete passes, with host writes as the sole external mutation.
  let
    machine = fixture(image, kind, port, phase)
    channel = (port + 4) * 2
    mask = 1 shl (port + 4)
    baselinePhase = phase xor 0xC0
    lastPass = if kind == 8: 28 elif retargetKind(kind): 12
      elif parserKind(kind): 10 else: 5
    initialChannels = machine.spc.ram[0x200 .. 0x3FF]
  var
    host: array[4, uint8]
    lastSample: array[4, uint8]
    pending: array[4, int]
    expectedRegs = machine.dsp.regs
    selectedRegister = machine.dspAddr.int
  host[port] = (if (phase and 128) != 0: 0x81 else: 1)
  for pass in 0 .. lastPass:
    if kind == 8 and pass == 2:
      host[port] = (if (phase and 128) != 0: 0x82 else: 2)
    if retargetKind(kind):
      if pass == 10: host[2] = 0
      if pass == 11: host[2] = (if (phase and 128) != 0: 0x81 else: 1)
    # Host inputs are the only values assigned between passes. Every byte of
    # copied record/configuration, progress and channel state is left produced.
    machine.portsIn = host
    let
      stage = phaseStage(kind, pass)
      output = expectedOutput(kind, port, phase, stage)
      control = stage == expire
    if control:
      host = [0'u8, 0, 0, 0] # Actual CONTROL31 clears the real APU input latches.
    var
      expectedEvents: seq[Event]
      expectedConsumed = pending
      expectedLookups: seq[Lookup]
    if control:
      expectedEvents.addWrite(0xF1, 0x31)
      expectedConsumed = [0, 0, 0, 0]
    if stage == install:
      expectedLookups.add((port, if kind == 8: 0 else: kind))
      if retargetKind(kind) and port == 3:
        expectedConsumed[2] = 1
        expectedLookups.add((2, 8))
    if retargetKind(kind) and port == 1 and pass == 2:
      expectedLookups.add((2, 8))
    if retargetKind(kind) and pass == 12:
      expectedLookups.add((2, 8))
    if stage == nativeArm: expectedLookups.add((port, 8))
    var
      nextPending: array[4, int]
      lastReturn = 0
      lastCompare = 0
      lastOld = 0
    for slot in countdown(3, 1):
      if slot == port: expectedEvents.add output
      let value = host[slot].int
      expectedEvents.add(('r', (0xF4 + slot).uint16, value.uint8))
      expectedEvents.add(('r', (0xF4 + slot).uint16, value.uint8))
      expectedEvents.addWrite(0xF4 + slot, value)
      nextPending[slot] = if value == lastSample[slot].int: 0 else: value
      if slot == 1:
        lastReturn = nextPending[slot]
        lastOld = lastSample[slot].int
        lastCompare = (value - lastSample[slot].int) and 255
      lastSample[slot] = value.uint8
    if stage == install and retargetKind(kind) and port == 1:
      nextPending[2] = 1 # Produced AFTER port-two sampling; consumed next pass.
    let observed = machine.runPass()
    let context = &"kind={kind} port={port} phase={phase} pass={pass}"
    doAssert observed.events == expectedEvents, context & " MMIO order/data"
    doAssert observed.calls == @TopCalls, context & " full service call order"
    doAssert observed.consumed == expectedConsumed, context & " copied-input latency"
    doAssert observed.lookups == expectedLookups, context & " real lookup/retarget route"
    pending = nextPending
    for slot in 1 .. 3:
      doAssert machine.spc.ram[0x4B0 + slot].int == pending[slot], context & " copied input"
      doAssert machine.spc.ram[0x4A4 + slot] == lastSample[slot], context & " sampled history"
      doAssert machine.portsOut[slot] == host[slot]
    doAssert machine.portsIn == host
    doAssert machine.spc.x == 1 and machine.spc.a.int == lastReturn
    let statusNZ = (if lastCompare == 0: PswZ else: 0'u8) or
      (if lastCompare >= 128: PswN else: 0'u8)
    # Stable input pairs compare equal internally, then the old sampled byte is
    # compared. Its C follows unsigned new>=old; N/Z follow wrapped difference.
    let lastReads = observed.events[^3 .. ^1]
    doAssert lastReads[0].address == 0xF5 and lastReads[1].address == 0xF5
    let expectedCarry = if host[1].int >= lastOld: PswC else: 0'u8
    doAssert (machine.spc.psw and (PswC or PswN or PswZ)) == (expectedCarry or statusNZ), context
    doAssert (machine.spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
    var progressValue = 0
    if kind == 8:
      if pass >= 2: progressValue = 1
    elif kind in [14, 16]:
      progressValue = if pass < 2: 0 else: min(pass - 1, 3)
    elif parserKind(kind):
      if pass in 2 .. 8: progressValue = (pass - 1) mod 4
    elif pass in 2 .. 3:
      progressValue = pass - 1
    let
      done = if kind == 8: pass >= 27 elif parserKind(kind): pass >= 9 else: pass >= 4
      active = pass >= 1 and not done
      cursor = if parserKind(kind): (if pass >= 9: 8 elif pass >= 5: 7 else: 0)
        elif kind in [14, 16]: (if pass < 2: 0 else: min(pass - 1, 3)) else: 0
      currentGain = if pass < 2: 64 elif kind == 8: 156 elif done: 64
        elif parserKind(kind) and pass >= 5: 100 else: 156
      currentPhase = if pass < 2: baselinePhase elif kind == 8: phase elif done: baselinePhase
        elif parserKind(kind) and pass >= 5: 0x40 else: phase
    doAssert machine.spc.ram[0x4B4 + port].int == (if active: 1 else: 0), context & " active slot"
    doAssert machine.spc.ram[0x4B8 + port].int == progressValue, context & " retained progress"
    doAssert machine.spc.ram[0xD0 + port].int == cursor and machine.spc.ram[0xD4 + port] == 0
    doAssert machine.spc.ram[0x450 + port].int == (if pass >= 2: 1 else: 0)
    doAssert machine.spc.ram[0x454 + port].int == (if kind in [14, 16] and pass >= 1: 1 else: 0)
    doAssert machine.spc.ram[0x49C + port].int ==
      (if kind in [6, 12] and pass >= 2: 0x81 elif kind in [6, 12] and pass == 1: 1 else: 0)
    doAssert machine.spc.ram[0x4C8 + port].int ==
      (if parserKind(kind) and pass in 5 .. 8: 0xC9 else: 0)
    var expectedChannels = initialChannels
    expectedChannels[0x121 + channel] = currentGain.uint8
    expectedChannels[0x151 + channel] = currentPhase.uint8
    doAssert machine.spc.ram[0x200 .. 0x3FF] == expectedChannels, context & " channel neighbors/restore"
    if pass >= 2:
      doAssert machine.spc.ram[0x4E0 + channel] == 64
      doAssert machine.spc.ram[0x4F0 + channel].int == baselinePhase
    if pass >= 1:
      var state = [if parserKind(kind) or kind in [14, 16]: 4 else: 3,
        2, 0, 156, phase or 10, 12, 0x35]
      if kind in [14, 16]:
        state[5] = 1
        state[6] = 1
        doAssert machine.spc.word(0x26) == 0x6800 and machine.spc.word(0x28) == 0x6A00
        doAssert machine.spc.ram[0x2C] == 1 and machine.spc.word(0x458 + port * 2) == 0
      if parserKind(kind) and pass >= 5:
        state[3] = 100
        state[4] = 0x4A
      for index, value in state:
        doAssert machine.spc.ram[0x460 + port * 8 + index].int == value, context & " live config"
    let expectedOff = if stage == expire or (kind == 8 and pass >= 27): 0xE0
      elif pass >= 1: mask else: 0
    doAssert machine.spc.ram[0x46].int == expectedOff
    doAssert machine.spc.ram[0x45].int == (if pass >= 2: mask else: 0)
    doAssert machine.spc.ram[0x1A].int == (if pass >= 1 and not done: mask else: 0)
    doAssert machine.spc.ram[0x5E].int ==
      (if kind == 8 and pass >= 27: 0xE0 elif done: mask else: 0)
    doAssert machine.spc.ram[0x49].int == (if kind in [14, 16] and pass in 2 .. 3: mask else: 0)
    if kind in [14, 16] and pass >= 2: doAssert machine.spc.ram[0x48] == 0x1D
    if retargetKind(kind) and pass >= 1: doAssert machine.spc.word(0x17C5) == 0x148A
    if kind == 8:
      let remaining = if pass < 3 or pass >= 27: 0 else: 27 - pass
      doAssert machine.spc.ram[0x491].int == remaining
      doAssert machine.spc.ram[0x492].int == (if pass >= 3: 1 else: 0)
      doAssert machine.spc.ram[0x5A].int == (if pass >= 3: 24 else: 0)
      if pass >= 3:
        doAssert machine.spc.ram[0x5B] == 16 and machine.spc.word(0x5C) == NativeFadeStep
        doAssert machine.spc.word(0x440 + port * 2) == 0x148A
      doAssert machine.spc.word(0x58) == 0xC000
    for event in output:
      if event.address == 0xF2: selectedRegister = event.value.int
      elif event.address == 0xF3: expectedRegs[selectedRegister and 127] = event.value
    doAssert machine.dsp.regs == expectedRegs, context & " actual DSP register application"
    let expectedNative = (if stage == nativeContinue: 1 else: 0) +
      (if retargetKind(kind) and ((port == 3 and pass == 1) or
        (port == 1 and pass == 2) or pass == 12): 1 else: 0)
    doAssert observed.nativeReturns == expectedNative, context & " native continuation"
    doAssert observed.arms == (if stage == nativeArm: 1 else: 0)
    doAssert observed.clears == (if control: 1 else: 0)
    doAssert observed.initializers == (if stage == initialize: 1 else: 0)
    doAssert observed.ticks == (if stage in [initialize, progress, parseMarker, finish,
      extendedRelease]: 1 else: 0)
    doAssert observed.parsers == (if parserKind(kind) and pass in 2 .. 9: 1 else: 0)
    doAssert observed.finishes == (if stage == finish: 1 else: 0)
    doAssert observed.instrumentUpdates == (if stage == parseMarker: 1 else: 0)
    doAssert observed.panUpdates == (if stage == parseMarker: 2 else: 0)
    doAssert observed.gainUpdates == (if kind in [14, 16] and stage == initialize: 1 else: 0)
    doAssert observed.volumeUpdates == (if stage == extendedRelease: 1 else: 0)
    doAssert observed.envelopes == (if kind in [14, 16] and stage == initialize: 1 else: 0)
    for timer in 0 .. 2:
      let snapshot = machine.getTimerSnapshot(timer)
      doAssert snapshot.counter == 0 and snapshot.internal == 0 and snapshot.accum == 0
      doAssert snapshot.enabled == (kind == 8 and pass >= 27 and timer == 0)
    inc result.passes
    if stage == install: inc result.installations
    if stage == initialize: inc result.initializations
    if stage == parseMarker: inc result.parserMarkers
    if stage == finish: inc result.finishes
    result.nativeCallbacks += observed.nativeReturns
    if stage == expire: inc result.expiries
    if retargetKind(kind):
      for lookup in observed.lookups:
        if lookup == (2, 8): inc result.retargetLookups
  inc result.scenarios

proc main() =
  ## Require byte-identical original/rebuilt images and count complete service-pass chains.
  var totals: Totals
  for image in engineImages("bin/spc_service_records_extract"):
    for kind in Kinds:
      for port in 1 .. 3:
        for phase in [0, 0x40, 0x80, 0xC0]:
          let checked = checkScenario(image, kind, port, phase)
          totals.scenarios += checked.scenarios
          totals.passes += checked.passes
          totals.installations += checked.installations
          totals.initializations += checked.initializations
          totals.parserMarkers += checked.parserMarkers
          totals.finishes += checked.finishes
          totals.nativeCallbacks += checked.nativeCallbacks
          totals.expiries += checked.expiries
          totals.retargetLookups += checked.retargetLookups
  echo &"SPC service records passed: {totals.scenarios} scenarios, {totals.passes} full service passes, {totals.installations} installs, {totals.initializations} initializations, {totals.parserMarkers} parser marker scans, {totals.finishes} full finishes, {totals.nativeCallbacks} native continuations/returns, {totals.expiries} service expiries and {totals.retargetLookups} retarget-fed native lookups."

when isMainModule:
  main()
