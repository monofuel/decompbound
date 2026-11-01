## Reset extents, upper-voice release masks and real prelude/expiry consumers.
## Original code and actual APU hooks run without timer advancement or audio output.
import
  std/strformat,
  decompbound/[spc700, apu],
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  Guard = 0xA5'u8
  ReleaseEntries = [(0x1453, 0xE0), (0x145D, 0x20), (0x146B, 0x40), (0x1479, 0x80)]

type
  Totals = object
    clears, releases, flags, expiries, preludes, returns, flushes, hardware: int
  State = tuple[low, high: seq[uint8]]
  Observation = object
    writes: seq[(uint16, uint8)]
    trace: seq[uint16]

proc load(spc: var Spc, image: seq[uint8]) =
  ## Load the user's original driver without touching its runtime record data.
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[DriverMap + address]

proc prepare(spc: var Spc, seed: int, status: uint8) =
  ## Author distinct state bytes and protect a native caller frame.
  for address in 0 .. 0xEF:
    spc.ram[address] = ((address * 37 + seed * 19 + 7) and 255).uint8
  for address in 0x400 .. 0x4FF:
    spc.ram[address] = ((address * 19 + seed * 37 + 11) and 255).uint8
  for address in 0x1E8 .. 0x1F2:
    spc.ram[address] = Guard
  spc.ram[0x1F0] = 0
  spc.ram[0x1F1] = 0x1E
  spc.a = (seed xor 0xA5).uint8
  spc.x = ((seed * 3) and 255).uint8
  spc.y = ((seed * 7) and 255).uint8
  spc.psw = status
  spc.sp = 0xEF

proc snapshot(spc: Spc): State =
  ## Copy only authored low RAM and the auxiliary-state page.
  (spc.ram[0 .. 0xEF], spc.ram[0x400 .. 0x4FF])

proc clearExpected(state: var State, full: bool) =
  ## Specify the two reset extents independently of their store instructions.
  for address in 0xB0 .. 0xB7:
    state.high[address] = 0
  if full:
    for address in [0x491, 0x438, 0x439, 0x43A, 0x4C8, 0x4C9, 0x4CA, 0x4CB]:
      state.high[address - 0x400] = 0

proc releaseExpected(state: var State, mask: int) =
  ## Specify the exact selected bits while preserving every unselected byte and bit.
  state.low[0x1A] = (state.low[0x1A].int and (255 xor mask)).uint8
  for address in [0x46, 0x47, 0x5E]:
    state.low[address] = (state.low[address].int or mask).uint8
  for bit in 5 .. 7:
    if (mask and (1 shl bit)) != 0:
      state.high[0xB0 + bit] = 0

proc checkState(spc: Spc, expected: State) =
  ## Assert all unaffected neighbors as well as the intended changed fields.
  doAssert spc.ram[0 .. 0xEF] == expected.low
  doAssert spc.ram[0x400 .. 0x4FF] == expected.high

proc execute(spc: var Spc, entry: int, stop = ReturnAddress,
    installHooks = true): Observation =
  ## Run original helpers and native calls; optional real APU hooks stay attached.
  var observed: Observation
  if installHooks:
    spc.readHook = proc(address: uint16): int =
      doAssert false, &"unexpected I/O read {address:04X}"
      -1
    spc.writeHook = proc(address: uint16, value: uint8): bool =
      doAssert address in [0xF1'u16, 0xF2'u16, 0xF3'u16]
      observed.writes.add((address, value))
      false
  spc.pc = entry.uint16
  while spc.pc != stop:
    doAssert observed.trace.len < 250 and spc.sp in 0xEB'u8 .. 0xF1'u8
    observed.trace.add spc.pc
    spc.step()
  doAssert not spc.stopped
  doAssert spc.ram[0x1E8] == Guard and spc.ram[0x1F2] == Guard
  doAssert spc.ram[0x1F0] == 0 and spc.ram[0x1F1] == 0x1E
  if stop == ReturnAddress:
    doAssert spc.sp == 0xF1
  if installHooks:
    spc.readHook = nil
    spc.writeHook = nil
  observed

proc returnedFlags(status: uint8): uint8 =
  ## MOV A,zero changes only N/Z, retaining every other status bit.
  (status and not (PswN or PswZ)) or PswZ

proc addPort(writes: var seq[(uint16, uint8)], register, value: int) =
  ## Append one independently expected DSP register transaction.
  writes.add((0xF2'u16, register.uint8))
  writes.add((0xF3'u16, value.uint8))

proc checkImage(image: seq[uint8]): Totals =
  ## Verify full mask domains and original prelude/expiry chains with authored state.
  var
    spc = newSpc()
    clears, releases, flags, expiries, preludes, returns, flushes, hardware = 0
  spc.load(image)
  for entry in [0x141A, 0x1438]:
    for seed in 0 .. 255:
      let status = seed.uint8
      spc.prepare(seed, status)
      let originalX = spc.x
      let originalY = spc.y
      var expected = spc.snapshot()
      expected.clearExpected(entry == 0x141A)
      let observed = spc.execute(entry)
      spc.checkState(expected)
      doAssert observed.writes.len == 0 and spc.a == 0 and spc.x == originalX and spc.y == originalY
      doAssert spc.psw == returnedFlags(status)
      inc clears
  for (entry, mask) in ReleaseEntries:
    for inhibit in 0 .. 255:
      for pending in 0 .. 255:
        let status = if (pending and 1) == 0: 0'u8 else: 0xDF'u8
        spc.prepare(inhibit, status)
        spc.ram[0x1A] = inhibit.uint8
        spc.ram[0x46] = pending.uint8
        spc.ram[0x47] = (inhibit xor pending).uint8
        spc.ram[0x5E] = ((inhibit + pending) and 255).uint8
        let originalX = spc.x
        let originalY = spc.y
        var expected = spc.snapshot()
        expected.releaseExpected(mask)
        let observed = spc.execute(entry)
        spc.checkState(expected)
        doAssert observed.writes.len == 0 and spc.a == 0 and spc.x == originalX and spc.y == originalY
        doAssert spc.psw == returnedFlags(status)
        inc releases
    for status in 0 .. 255:
      if (status and PswP.int) == 0:
        spc.prepare(status, status.uint8)
        var expected = spc.snapshot()
        expected.releaseExpected(mask)
        discard spc.execute(entry)
        spc.checkState(expected)
        doAssert spc.psw == returnedFlags(status.uint8)
        inc flags
  for count in 0 .. 255:
    for status in [0'u8, 0xDF'u8]:
      spc.prepare(count, status)
      spc.ram[0x491] = count.uint8
      let originalX = spc.x
      let originalY = spc.y
      let next = if count in [0, 255]: 0 else: count - 1
      var expected = spc.snapshot()
      expected.high[0x91] = next.uint8
      if count == 1:
        expected.clearExpected(false)
        expected.releaseExpected(0xE0)
      let observed = spc.execute(0x1609)
      spc.checkState(expected)
      doAssert observed.writes == (if count == 1: @[(0xF1'u16, 0x31'u8)] else: @[])
      doAssert (0x1438'u16 in observed.trace) == (count == 1)
      doAssert (0x1453'u16 in observed.trace) == (count == 1)
      doAssert 0x141A'u16 notin observed.trace
      doAssert spc.a.int == next and spc.x == originalX and spc.y == originalY
      let nz = (if next == 0: PswZ else: 0'u8) or (if next >= 128: PswN else: 0'u8)
      doAssert spc.psw == ((status and not (PswC or PswN or PswZ)) or PswC or nz)
      inc expiries
  for seed in 0 .. 255:
    spc.prepare(seed, (if (seed and 1) == 0: 0'u8 else: 0xDF'u8))
    let originalX = spc.x
    let status = spc.psw
    var expected = spc.snapshot()
    expected.clearExpected(true)
    expected.releaseExpected(0xE0)
    let observed = spc.execute(0x75E, 0xEE1)
    spc.checkState(expected)
    doAssert observed.writes == @[(0xF2'u16, 0x5C'u8), (0xF3'u16, 0xFF'u8)]
    doAssert spc.a == 0 and spc.x == originalX and spc.y == 0x5C
    doAssert spc.psw == returnedFlags(status)
    doAssert spc.sp == 0xED and spc.ram[0x1EE] == 0x6E and spc.ram[0x1EF] == 7
    doAssert 0x141A'u16 in observed.trace and 0x1453'u16 in observed.trace
    inc preludes
  for status in 0 .. 255:
    spc.prepare(status, status.uint8)
    let before = spc.snapshot()
    let originalA = spc.a
    let originalX = spc.x
    let originalY = spc.y
    let observed = spc.execute(0x148A)
    spc.checkState(before)
    doAssert observed.trace == @[0x148A'u16] and observed.writes.len == 0
    doAssert spc.a == originalA and spc.x == originalX and spc.y == originalY and spc.psw == status.uint8
    inc returns
  # Real native dispatch of port-one input six, without modifying any record bytes.
  spc.prepare(0, 0xDF)
  spc.ram[0x4B1] = 6
  spc.ram[0x4D1] = 255
  let native = spc.execute(0x1198)
  let index = native.trace.find(0x148A'u16)
  doAssert index > 0 and native.trace[index - 1] == 0x1317
  doAssert index == native.trace.high and native.writes.len == 0
  inc returns
  for (entry, mask) in ReleaseEntries:
    for inhibit in [0, 1, 127, 128, 255]:
      for pending in [0, 1, 127, 128, 255]:
        spc.prepare(inhibit, 0xDF)
        spc.ram[0x1A] = inhibit.uint8
        spc.ram[0x46] = pending.uint8
        spc.ram[0x1B] = 0
        spc.ram[0x4C] = 0
        spc.ram[0x4D] = 0
        discard spc.execute(entry)
        let before = spc.snapshot()
        doAssert before.low[0x46].int == (pending or mask)
        var expected: seq[(uint16, uint8)]
        for (register, source) in [(0x5C, 0x46), (0x2D, 0x4B), (0x3D, 0x49),
            (0x5C, 0x0E), (0x4C, 0x45), (0x6C, 0x48), (0x4D, 0x4A),
            (0x0D, 0x4E), (0x3C, 0x63), (0x2C, 0x61)]:
          expected.addPort(register, before.low[source].int)
        spc.sp = 0xEF
        let observed = spc.execute(0x546, 0x579)
        doAssert observed.writes == expected and spc.sp == 0xEF
        doAssert spc.ram[0x46] == 0
        inc flushes
  # Run the expiry through actual APU MMIO hooks without advancing timers or DSP samples.
  for enables in 0 .. 7:
    for count in [0, 1, 2, 255]:
      let machine = newApu()
      machine.spc.load(image)
      machine.spc.prepare(3, 0xDF)
      machine.spc.ram[0x491] = count.uint8
      machine.spc.iplEnabled = true
      machine.portsIn = [0x11'u8, 0x22, 0x33, 0x44]
      machine.portsOut = [0xA1'u8, 0xB2, 0xC3, 0xD4]
      for timer in 0 .. 2:
        machine.setTimerSnapshot(timer, TimerSnapshot(enabled: (enables and (1 shl timer)) != 0,
          target: (7 + timer).uint8, internal: (19 + timer).uint8,
          counter: (5 + timer).uint8, accum: 61 + timer))
      let dspBefore = machine.dsp.regs
      let originalWrite = machine.spc.writeHook
      var writes: seq[(uint16, uint8)]
      machine.spc.writeHook = proc(address: uint16, value: uint8): bool =
        writes.add((address, value))
        originalWrite(address, value)
      discard machine.spc.execute(0x1609, installHooks = false)
      doAssert writes == (if count == 1: @[(0xF1'u16, 0x31'u8)] else: @[])
      doAssert machine.portsIn == (if count == 1: [0'u8, 0, 0, 0] else: [0x11'u8, 0x22, 0x33, 0x44])
      doAssert machine.portsOut == [0xA1'u8, 0xB2, 0xC3, 0xD4]
      doAssert machine.spc.iplEnabled == (count != 1)
      doAssert machine.dsp.regs == dspBefore
      for timer in 0 .. 2:
        let beforeEnabled = (enables and (1 shl timer)) != 0
        let actual = machine.getTimerSnapshot(timer)
        let reset = count == 1 and timer == 0 and not beforeEnabled
        doAssert actual.enabled == (if count == 1: timer == 0 else: beforeEnabled)
        doAssert actual.internal.int == (if reset: 0 else: 19 + timer)
        doAssert actual.counter.int == (if reset: 0 else: 5 + timer)
        doAssert actual.target.int == 7 + timer and actual.accum == 61 + timer
      inc hardware
  Totals(clears: clears, releases: releases, flags: flags, expiries: expiries,
    preludes: preludes, returns: returns, flushes: flushes, hardware: hardware)

proc main() =
  ## Require original and fresh byte-identical rebuilt images and count actual checks.
  var totals: Totals
  for image in engineImages("bin/spc_reset_helpers_extract"):
    let checked = checkImage(image)
    totals.clears += checked.clears
    totals.releases += checked.releases
    totals.flags += checked.flags
    totals.expiries += checked.expiries
    totals.preludes += checked.preludes
    totals.returns += checked.returns
    totals.flushes += checked.flushes
    totals.hardware += checked.hardware
  echo &"SPC reset helpers passed: {totals.clears} reset cases, {totals.releases} mask cases, {totals.flags} flag cases, {totals.expiries} countdown paths, {totals.preludes} prelude chains, {totals.returns} RET entries/callers, {totals.flushes} release-to-flush chains and {totals.hardware} real APU CONTROL cases."

when isMainModule:
  main()
