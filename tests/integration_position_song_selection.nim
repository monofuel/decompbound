import
  std/strformat,
  decompbound/cpu,
  ./engine/rebuilt_rom

type
  Fixture = ref object
    bus: Bus
    ports: seq[uint8]

const
  Ram = 0x7E0000
  ReturnPc = 0x4000'u16
  Direct = 0x1E00
  Stack = 0x1FFF
  List = 0x6000

proc putWord(bus: Bus, address, value: int) =
  ## Author a little-endian word without executing a hardware write.
  bus.mem[address] = (value and 255).uint8
  bus.mem[address + 1] = ((value shr 8) and 255).uint8

proc word(bus: Bus, address: int): int =
  ## Read an authored or produced word without hardware side effects.
  bus.mem[address].int or (bus.mem[address + 1].int shl 8)

proc fixture(image: seq[uint8]): Fixture =
  ## Map original code and coherent low WRAM while capturing only actual port-one stores.
  result = Fixture(bus: newBus())
  let state = result
  for index, value in image: state.bus.mem[0xC00000 + index] = value
  state.bus.readHook = proc(address: uint32): int =
    if address < 0x2000: return state.bus.mem[Ram + address.int].int
    doAssert address notin 0x2140'u32 .. 0x2143'u32
    -1
  state.bus.writeHook = proc(address: uint32, value: uint8): bool =
    if address < 0x2000:
      state.bus.mem[Ram + address.int] = value
      return true
    if address == 0x2141:
      state.ports.add value
      return true
    doAssert address notin 0x2140'u32 .. 0x2143'u32
    false

proc frame(state: Fixture, entry, bank: int, near = false): Cpu =
  ## Supply an actual native return frame and preserve the caller's direct page.
  let bus = state.bus
  state.ports.setLen(0)
  bus.putWord(Ram + 0x1FFD, ReturnPc.int - 1)
  bus.mem[Ram + 0x1FFF] = 0xC0
  if near: bus.putWord(Ram + 0x1FFE, ReturnPc.int - 1)
  result = Cpu(pbr: bank.uint8, pc: entry.uint16, dbr: 0x7E,
    d: Direct, s: (if near: 0x1FFD'u16 else: 0x1FFC'u16))

proc runReturn(state: Fixture, host: var Cpu, budget = 1000) =
  ## Run unmodified callees until their real native return, with a finite instruction bound.
  var steps = 0
  while host.pc != ReturnPc or host.pbr != 0xC0:
    doAssert steps < budget, &"budget at {host.pbr:02X}:{host.pc:04X}"
    host.step(state.bus)
    inc steps
  doAssert host.s == Stack and host.d == Direct and host.dbr == 0x7E
  doAssert (host.p and (FlagM or FlagX)) == 0

proc selectData(state: Fixture, first, second, mapByte, offset: int) =
  ## Author only the tiny structural lookup entries needed by a synthetic position.
  let
    bus = state.bus
    index = (first shr 8) + 32 * (second div 128)
  bus.mem[0xDCD637 + index] = mapByte.uint8
  bus.putWord(0xCF58EF + 2 * mapByte, offset)

proc record(state: Fixture, offset, condition, candidate, auxiliary: int) =
  ## Author a tiny four-byte condition/candidate record, not an extracted game asset.
  state.bus.putWord(0xCF0000 + offset, condition)
  state.bus.mem[0xCF0000 + offset + 2] = candidate.uint8
  state.bus.mem[0xCF0000 + offset + 3] = auxiliary.uint8

proc flag(state: Fixture, number: int, enabled: bool) =
  ## Set one event flag using the runtime mask table consumed by the original predicate.
  let
    bitIndex = (number - 1) and 65535
    address = Ram + 0x9C08 + bitIndex div 8
    mask = state.bus.mem[0xC4562F + bitIndex mod 8]
  doAssert mask != 0
  state.bus.mem[address] = if enabled: mask else: 0

proc prepare(state: Fixture, gate, suppress, current, toggle: int) =
  ## Distinguish persistent lookup outputs and notification controls before a call.
  state.bus.putWord(Ram + 0x5DD8, gate)
  state.bus.putWord(Ram + 0x5DDA, suppress)
  state.bus.putWord(Ram + 0x5DD4, current)
  state.bus.putWord(Ram + 0x5DD6, 0xA55A)
  state.bus.putWord(Ram + 0x5E38, 0x1234)
  state.bus.putWord(Ram + 0x5E3A, 0x5678)
  state.bus.mem[Ram + 0x1ACB] = toggle.uint8

proc assertOutput(state: Fixture, candidate, pointer, suppress, current, toggle: int) =
  ## Compare published values and notifications with a host-level selection oracle.
  let
    bus = state.bus
    notify = suppress == 0 and candidate != current
  doAssert bus.word(Ram + 0x5DD6) == candidate
  doAssert bus.word(Ram + 0x5E38) == pointer
  doAssert bus.word(Ram + 0x5E3A) == 0xCF
  doAssert bus.word(Ram + 0x5DD4) == current
  doAssert bus.word(Ram + 0x5DDA) == suppress
  doAssert bus.word(Ram + 0x5DD8) == 0
  doAssert state.ports == (if notify: @[(toggle or 2).uint8] else: @[])
  doAssert bus.mem[Ram + 0x1ACB].int == (if notify: toggle xor 128 else: toggle)

proc checkPositions(state: Fixture): int =
  ## Sweep all second-coordinate words and all map-byte indices through real division and lookup.
  for second in 0 .. 65535:
    let
      first = ((second * 73) xor 0xA55A) and 65535
      mapByte = second and 255
      candidate = (second xor (second shr 8)) and 255
      suppress = if (second and 1) == 0: 0 else: 1
      current = if (second and 2) == 0: candidate else: candidate xor 128
      toggle = second and 255
    state.selectData(first, second, mapByte, List or (second and 0x8000))
    state.record(List, 0, candidate, 0x45)
    state.prepare(0, suppress, current, toggle)
    var host = state.frame(0x68F4, 0xC0)
    host.a = first.uint16
    host.x = second.uint16
    host.y = 0xACED
    state.runReturn(host)
    state.assertOutput(candidate, List, suppress, current, toggle)
    doAssert host.x.int == candidate and host.y == 2
    inc result

proc checkConditions(state: Fixture): int =
  ## Check polarity, flag-number edges, first-match ordering and unconditional termination.
  for number in [0, 1, 2, 8, 9, 255, 256, 32767]:
    for high in [false, true]:
      let condition = number or (if high: 0x8000 else: 0)
      for enabled in [false, true]:
        for candidate in 0 .. 255:
          let
            matches = condition == 0 or enabled == (condition > 0x8000)
            selected = if matches: candidate else: candidate xor 255
            pointer = if matches: List else: List + 4
          state.selectData(0x1234, 0xABCD, 17, List)
          state.record(List, condition, candidate, 0x53)
          state.record(List + 4, 0, candidate xor 255, 0x71)
          state.flag(number, enabled)
          state.prepare(0, 0, 0x100, candidate)
          var host = state.frame(0x68F4, 0xC0)
          host.a = 0x1234
          host.x = 0xABCD
          state.runReturn(host)
          state.assertOutput(selected, pointer, 0, 0x100, candidate)
          inc result

proc checkInhibit(state: Fixture): int =
  ## Verify inhibited lookup preserves prior output words and never accesses asset tables or ports.
  for gate in [1, 256, 65535]:
    for status in 0 .. 255:
      state.prepare(gate, status, 0x1267, 0x5A)
      var host = state.frame(0x68F4, 0xC0)
      host.a = 0xABCD
      host.x = (if (status and FlagX.int) != 0: 0x34'u16 else: 0x1234'u16)
      host.y = (if (status and FlagX.int) != 0: 0x78'u16 else: 0x5678'u16)
      host.p = (status and not FlagD.int).uint8
      let oldX = host.x
      let oldY = host.y
      state.runReturn(host)
      doAssert state.bus.word(Ram + 0x5DD6) == 0xA55A
      doAssert state.bus.word(Ram + 0x5E38) == 0x1234
      doAssert state.bus.word(Ram + 0x5E3A) == 0x5678
      doAssert host.x == oldX and host.y == oldY and state.ports.len == 0
      doAssert host.p.int == ((status and not (FlagD or FlagM or FlagX or FlagC or FlagV or FlagN or FlagZ).int) or FlagC.int)
      inc result

proc checkWrapper(state: Fixture): int =
  ## Execute the actual wrapper/lookup return path with an equal produced candidate and no stand-ins.
  for candidate in 0 .. 255:
    state.selectData(0x4321, 0x8765, candidate, List)
    state.record(List, 0, candidate, 0x65)
    state.prepare(0, 0xBEEF, candidate, 0x80)
    state.bus.putWord(Ram + 0x9877, 0x4321)
    state.bus.putWord(Ram + 0x987B, 0x8765)
    var host = state.frame(0x3C25, 0xC0, near = true)
    state.runReturn(host)
    state.assertOutput(candidate, List, 0, candidate, 0x80)
    inc result
  # Changed candidate proves suppression and the exact external handoff; external
  # C08756/consumer effects are deliberately not represented as a completed call.
  for candidate in 0 .. 255:
    state.selectData(0x4321, 0x8765, candidate, List)
    state.record(List, 0, candidate, 0x65)
    state.prepare(0, 0, candidate xor 255, 0x80)
    var host = state.frame(0x3C25, 0xC0, near = true)
    var steps = 0
    while host.pc != 0x8756:
      doAssert steps < 300
      host.step(state.bus)
      inc steps
    doAssert state.bus.word(Ram + 0x5DD6) == candidate
    doAssert state.bus.word(Ram + 0x5DDA) == 1 and state.ports.len == 0
    doAssert host.pbr == 0xC0 and host.s == 0x1FFA and host.d == Direct
    inc result
  # Inhibited lookup retains stale output; the wrapper still compares that word.
  for gate in [1, 256, 65535]:
    for equal in [false, true]:
      state.prepare(gate, 0xBEEF, if equal: 0xA55A else: 0x1234, 0x80)
      var host = state.frame(0x3C25, 0xC0, near = true)
      if equal:
        state.runReturn(host)
        doAssert state.bus.word(Ram + 0x5DDA) == 0
      else:
        var steps = 0
        while host.pc != 0x8756:
          doAssert steps < 50
          host.step(state.bus)
          inc steps
        doAssert host.pbr == 0xC0 and host.s == 0x1FFA and host.d == Direct
        doAssert state.bus.word(Ram + 0x5DDA) == 1
      doAssert state.bus.word(Ram + 0x5DD6) == 0xA55A
      doAssert state.bus.word(Ram + 0x5E38) == 0x1234
      doAssert state.bus.word(Ram + 0x5E3A) == 0x5678
      doAssert state.bus.word(Ram + 0x5DD8) == gate and state.ports.len == 0
      inc result

proc checkSetter(state: Fixture): int =
  ## Sweep every gate word and all incoming status bits through the original RTL setter.
  for value in 0 .. 65535:
    let
      status = value and 255
      x = if (status and FlagX.int) != 0: 0x56 else: 0x1256
      y = if (status and FlagX.int) != 0: 0x78 else: 0x3478
    var host = state.frame(0xFD45, 0xC4)
    host.a = value.uint16
    host.x = x.uint16
    host.y = y.uint16
    host.p = status.uint8
    state.bus.putWord(Ram + 0xB547, 0x1234)
    state.bus.putWord(Ram + 0xB54B, 0x5678)
    state.runReturn(host, 4)
    doAssert state.bus.word(Ram + 0xB549) == value
    doAssert state.bus.word(Ram + 0xB547) == 0x1234
    doAssert state.bus.word(Ram + 0xB54B) == 0x5678
    doAssert host.a.int == value and host.x.int == x and host.y.int == y
    doAssert host.p.int == (status and not (FlagM or FlagX or FlagC).int)
    doAssert state.ports.len == 0
    inc result

proc checkPositionGate(state: Fixture): int =
  ## Feed the actual setter output to the original position-change decision without rewriting its gate.
  for gate in [0, 1, 256, 65535]:
    for firstChanged in [false, true]:
      for secondChanged in [false, true]:
        for low in 0 .. 255:
          var setter = state.frame(0xFD45, 0xC4)
          setter.a = gate.uint16
          state.runReturn(setter, 4)
          state.bus.putWord(Ram + 0x9877, 0x5600 + low)
          state.bus.putWord(Ram + 0x987B, 0x7800 + low)
          state.bus.putWord(Ram + 0x5D5C, if firstChanged: 0x55 else: 0x56)
          state.bus.putWord(Ram + 0x5D5E, if secondChanged: 0x77 else: 0x78)
          var host = state.frame(0x524E, 0xC0)
          var steps = 0
          while host.pc notin [0x527C'u16, 0x3C25'u16]:
            doAssert steps < 30
            host.step(state.bus)
            inc steps
          let selected = gate != 0 and (firstChanged or secondChanged)
          doAssert (host.pc == 0x3C25) == selected
          doAssert state.bus.word(Ram + 0x5D5C) == 0x56
          doAssert state.bus.word(Ram + 0x5D5E) == 0x78
          doAssert state.bus.word(Ram + 0xB549) == gate
          doAssert host.s == (if selected: 0x1FFA'u16 else: 0x1FFC'u16)
          doAssert host.d == Direct and state.ports.len == 0
          if selected: doAssert state.bus.word(Ram + 0x1FFB) == 0x527B
          inc result

proc checkRecordEdges(state: Fixture): int =
  ## Exercise odd pointers, offset masking and condition advances across the initial 15-bit range.
  for offset in [0, 1, 0x7FFB, 0x7FFF]:
    for maskBit in [0, 0x8000]:
      for enabled in [false, true]:
        state.selectData(0x1234, 0x5678, 254, offset or maskBit)
        state.record(offset, 0x8001, 0x64, 0x35)
        state.record(offset + 4, 0, 0x73, 0x24)
        state.flag(1, enabled)
        state.prepare(0, 1, 0, 0x80)
        var host = state.frame(0x68F4, 0xC0)
        host.a = 0x1234
        host.x = 0x5678
        state.runReturn(host)
        state.assertOutput(if enabled: 0x64 else: 0x73,
          if enabled: offset else: offset + 4, 1, 0, 0x80)
        inc result
  # Reach the actual low-word wrap from a legal masked initial offset. The
  # generated unmatched records are synthetic, not a stored game script.
  state.selectData(0x1234, 0x5678, 254, 0xFFFF)
  for offset in countup(0x7FFF, 0xFFFF, 4):
    state.record(offset, 0x8001, 0x64, 0x35)
  state.record(3, 0, 0x73, 0x24)
  state.record(0x10003, 0, 0x51, 0x42) # Distinguish erroneous bank-carry advancement.
  state.flag(1, false)
  state.prepare(0, 1, 0, 0x80)
  var host = state.frame(0x68F4, 0xC0)
  host.a = 0x1234
  host.x = 0x5678
  state.runReturn(host, 2_000_000)
  state.assertOutput(0x73, 3, 1, 0, 0x80)
  inc result

proc checkPositionCaller(state: Fixture): int =
  ## Execute the original global-position adapter through lookup and its actual RTL return.
  for candidate in 0 .. 255:
    state.selectData(0x2143, 0x6587, candidate, List)
    state.record(List, 0, candidate, 0x76)
    state.prepare(0, 0, candidate xor 128, candidate)
    state.bus.putWord(Ram + 0x9877, 0x2143)
    state.bus.putWord(Ram + 0x987B, 0x6587)
    var host = state.frame(0x69F7, 0xC0)
    state.runReturn(host)
    state.assertOutput(candidate, List, 0, candidate xor 128, candidate)
    doAssert host.a.int == candidate
    inc result

proc main() =
  ## Require both original and freshly rebuilt engine images and report actual bounded contexts.
  for imageIndex, image in engineImages("bin/position_song_selection_extract"):
    let name = if imageIndex == 0: "original" else: "rebuilt"
    let state = fixture(image)
    let
      positions = state.checkPositions()
      conditions = state.checkConditions()
      inhibited = state.checkInhibit()
      wrappers = state.checkWrapper()
      setters = state.checkSetter()
      decisions = state.checkPositionGate()
      edges = state.checkRecordEdges()
      callers = state.checkPositionCaller()
    echo &"{name}: {positions} position/division, {conditions} conditional-list, {inhibited} inhibited and {wrappers} wrapper, {setters} setter, {decisions} produced-gate decision and {edges} record-edge and {callers} actual-position-caller contexts passed"

when isMainModule:
  main()
