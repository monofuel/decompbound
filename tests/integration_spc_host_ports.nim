## Host-port stable sampling, change suppression and original native service calls.
## All input/handshake bytes are authored; no DSP or physical device is attached.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  ReturnAddress = 0x1E00'u16
  StatusMask = PswP or PswI or PswB or PswH or PswV
  StackGuard = 0xA5'u8
  DriverStart = 0x0500
  DriverLength = 16779

type
  PortEvent = tuple[direction: char, address: uint16, value: uint8]
  Observation = object
    reads: int
    writes: seq[(uint16, uint8)]
    trace: seq[uint16]
    events: seq[PortEvent]
  Totals = object
    exchanges, samples, unstable, callers, pending: int

proc prepare(spc: var Spc, status: uint8) =
  ## Dirty only authored state and establish a protected native caller frame.
  for address in 0 .. 0xEF:
    spc.ram[address] = ((address * 37 + 19) and 255).uint8
  for address in 0x490 .. 0x4FF:
    spc.ram[address] = ((address * 19 + 7) and 255).uint8
  for address in 0x1E8 .. 0x1F2:
    spc.ram[address] = StackGuard
  spc.ram[0x1F0] = 0
  spc.ram[0x1F1] = 0x1E
  spc.sp = 0xEF
  spc.psw = status
  spc.a = 0xA3
  spc.y = 0xD2

proc execute(spc: var Spc, entry, stop: uint16, port: int, samples: seq[int]): Observation =
  ## Supply finite sampled input while executing all original instructions and native calls.
  var observed: Observation
  spc.readHook = proc(address: uint16): int =
    doAssert address.int == port and observed.reads < samples.len
    result = samples[observed.reads]
    observed.events.add(('r', address, result.uint8))
    inc observed.reads
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address.int == port
    observed.writes.add((address, value))
    observed.events.add(('w', address, value))
    false
  spc.pc = entry
  while spc.pc != stop:
    doAssert observed.trace.len < 100
    doAssert spc.sp in 0xED'u8 .. 0xF1'u8
    observed.trace.add(spc.pc)
    spc.step()
  doAssert spc.ram[0x1E8] == StackGuard and spc.ram[0x1F2] == StackGuard
  doAssert spc.ram[0x1F0] == 0 and spc.ram[0x1F1] == 0x1E
  spc.readHook = nil
  spc.writeHook = nil
  observed

proc expectedEvents(port: int, inputs: seq[int], publish = -1): seq[PortEvent] =
  ## Require publication before sampling for port zero, and acknowledgement after sampling otherwise.
  if publish >= 0:
    result.add(('w', port.uint16, publish.uint8))
  for value in inputs:
    result.add(('r', port.uint16, value.uint8))
  if publish < 0:
    result.add(('w', port.uint16, inputs[^1].uint8))

proc compareFlags(value, old: int): uint8 =
  ## Predict flags from the final unsigned byte subtraction, without changing A.
  let difference = (value - old) and 255
  (if value >= old: PswC else: 0'u8) or
    (if difference == 0: PswZ else: 0'u8) or
    (if difference >= 128: PswN else: 0'u8)

proc checkPending(spc: var Spc, port: int, status: uint8) =
  ## Observe twenty unequal pairs still polling, without patching code or forcing a return.
  spc.prepare(status)
  spc.x = port.uint8
  spc.ram[4] = 0x5A
  let
    before = spc.ram[0 .. 0xEF]
    arrays = spc.ram[0x490 .. 0x4FF]
    loopAddress = if port == 0: 0x62A'u16 else: 0x63A'u16
  var
    reads = 0
    events: seq[PortEvent]
  spc.readHook = proc(address: uint16): int =
    doAssert address.int == 0xF4 + port
    result = reads and 1
    events.add(('r', address, result.uint8))
    inc reads
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address.int == 0xF4 + port
    events.add(('w', address, value))
    false
  spc.pc = if port == 0: 0x625'u16 else: 0x635'u16
  spc.step()
  spc.step()
  doAssert spc.pc == loopAddress
  for attempt in 0 ..< 20:
    spc.step()
    spc.step()
    spc.step()
    doAssert spc.pc == loopAddress and spc.sp == 0xEF and not spc.stopped
  doAssert reads == 40
  var expected: seq[PortEvent]
  if port == 0:
    expected.add(('w', 0xF4'u16, 0x5A'u8))
  for index in 0 ..< 40:
    expected.add(('r', (0xF4 + port).uint16, (index and 1).uint8))
  doAssert events == expected
  doAssert spc.a == 0 and spc.x.int == port and spc.y == 0xD2
  doAssert spc.psw == ((status and StatusMask) or PswN)
  for address in 0 .. 0xEF:
    if port > 0 and address == 0x20:
      doAssert spc.ram[address] == arrays[0x4A4 + port - 0x490]
    else:
      doAssert spc.ram[address] == before[address]
  doAssert spc.ram[0x490 .. 0x4FF] == arrays
  doAssert spc.ram[0x1E8] == StackGuard and spc.ram[0x1F2] == StackGuard
  doAssert spc.ram[0x1F0] == 0 and spc.ram[0x1F1] == 0x1E
  spc.readHook = nil
  spc.writeHook = nil

proc checkImage(image: seq[uint8]): Totals =
  ## Exhaust byte domains, sampled pairs and actual bounded service caller sites.
  var spc = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[DriverMap + address]

  for activity in 0 .. 255:
    for input in 0 .. 255:
      let status = if (activity and 1) == 0: 0'u8 else: 0xDF'u8
      spc.prepare(status)
      spc.x = 0x96
      spc.ram[4] = activity.uint8
      let before = spc.ram[0 .. 0xEF]
      let got = spc.execute(0x625, ReturnAddress, 0xF4, @[input, input])
      doAssert got.reads == 2 and got.writes == @[(0xF4'u16, activity.uint8)]
      doAssert got.events == expectedEvents(0xF4, @[input, input], activity)
      doAssert got.trace == @[0x625'u16, 0x627, 0x62A, 0x62D, 0x630, 0x632, 0x634]
      doAssert spc.a.int == input and spc.ram[0].int == input and spc.x == 0x96 and spc.y == 0xD2 and
          spc.sp == 0xF1
      doAssert spc.psw == ((status and StatusMask) or PswC or PswZ)
      for address in 1 .. 0xEF:
        doAssert spc.ram[address] == before[address]
      inc result.exchanges

  for port in 1 .. 3:
    for old in 0 .. 255:
      for input in 0 .. 255:
        let status = if ((old xor input) and 1) == 0: 0'u8 else: 0xDF'u8
        spc.prepare(status)
        spc.x = port.uint8
        spc.ram[0x4A4 + port] = old.uint8
        let before = spc.ram[0 .. 0xEF]
        let got = spc.execute(0x635, ReturnAddress, 0xF4 + port, @[input, input])
        let changed = if input == old: 0 else: input
        doAssert got.reads == 2 and got.writes == @[((0xF4 + port).uint16, input.uint8)]
        doAssert got.events == expectedEvents(0xF4 + port, @[input, input])
        doAssert spc.a.int == changed and spc.ram[0x4A0 + port].int == changed
        doAssert spc.ram[0x4A4 + port].int == input and spc.ram[port].int == input and spc.ram[0x20].int == old
        doAssert spc.x.int == port and spc.y == 0xD2 and spc.sp == 0xF1
        doAssert spc.psw == ((status and StatusMask) or compareFlags(input, old))
        for address in 0 .. 0xEF:
          if address notin [port, 0x20]:
            doAssert spc.ram[address] == before[address]
        for address in 0x490 .. 0x4FF:
          if address notin [0x4A4 + port, 0x4A0 + port]:
            doAssert spc.ram[address] == ((address * 19 + 7) and 255).uint8
        inc result.samples

  for port in 0 .. 3:
    for value in [0, 1, 127, 128, 255]:
      for status in [0'u8, 0xDF'u8]:
        spc.prepare(status)
        spc.x = port.uint8
        spc.ram[0x4A4 + port] = value.uint8
        spc.ram[4] = 0x5A
        let entry = if port == 0: 0x625'u16 else: 0x635'u16
        let got = spc.execute(entry, ReturnAddress, 0xF4 + port, @[0, 1, 254, 255, value, value])
        doAssert got.reads == 6 and got.writes.len == 1
        doAssert got.events == expectedEvents(0xF4 + port, @[0, 1, 254, 255, value, value],
          (if port == 0: 0x5A else: -1))
        doAssert spc.a.int == (if port == 0: value else: 0)
        doAssert spc.ram[port].int == value and spc.x.int == port and spc.y == 0xD2 and spc.sp == 0xF1
        doAssert spc.psw == ((status and StatusMask) or PswC or PswZ)
        if port > 0:
          doAssert spc.ram[0x4A4 + port].int == value and spc.ram[0x4A0 + port] == 0
        inc result.unstable

  for port in 0 .. 3:
    for status in [0'u8, 0xDF'u8]:
      spc.checkPending(port, status)
      inc result.pending

  for (entry, stop, port) in [
      (0x5A5'u16, 0x5AD'u16, 3),
      (0x5B3'u16, 0x5BB'u16, 2),
      (0x5BE'u16, 0x5C6'u16, 1)]:
    for old in [0, 1, 127, 128, 255]:
      for value in [0, 1, 127, 128, 255]:
        spc.prepare(0xDF)
        spc.x = 0xAA
        spc.ram[0x4A4 + port] = old.uint8
        let got = spc.execute(entry, stop, 0xF4 + port, @[value, value])
        doAssert 0x635'u16 in got.trace and 0x653'u16 in got.trace
        doAssert spc.sp == 0xEF and spc.x.int == port and
          spc.ram[0x4B0 + port].int == (if old == value: 0 else: value)
        doAssert got.events == expectedEvents(0xF4 + port, @[value, value])
        doAssert spc.a.int == (if old == value: 0 else: value) and spc.y == 0xD2
        doAssert spc.psw == ((0xDF'u8 and StatusMask) or compareFlags(value, old))
        inc result.callers

proc main() =
  ## Require original and fresh byte-identical rebuilt images and report actual execution counts.
  var totals: Totals
  for image in engineImages("bin/spc_host_ports_extract"):
    let checked = checkImage(image)
    totals.exchanges += checked.exchanges
    totals.samples += checked.samples
    totals.unstable += checked.unstable
    totals.callers += checked.callers
    totals.pending += checked.pending
  echo &"SPC host ports passed: {totals.exchanges} port-zero exchanges, {totals.samples} indexed samples, {totals.unstable} unstable-pair retries, {totals.callers} real service callers and {totals.pending} finite never-stable observations."

when isMainModule:
  main()
