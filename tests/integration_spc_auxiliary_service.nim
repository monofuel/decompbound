## Auxiliary service counters, original host dispatch and the shared code/table tail.
## Runtime records remain in the user's ROM; fixtures contain authored state only.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  Guard = 0xA5'u8
  PreservedFlags = PswP or PswI or PswB or PswH or PswV

type Totals = object
  counters, fallbacks, filters, arms, callers, selections, chains, chainTicks: int

proc prepare(spc: var Spc, status = 0xDF'u8) =
  ## Dirty authored state while preserving the user's original code and record data.
  for address in 0 .. 0xEF:
    spc.ram[address] = ((address * 37 + 19) and 255).uint8
  for address in 0x400 .. 0x4FF:
    spc.ram[address] = ((address * 19 + 7) and 255).uint8
  for address in 0x1E8 .. 0x1F2:
    spc.ram[address] = Guard
  spc.ram[0x1F0] = 0
  spc.ram[0x1F1] = 0x1E
  spc.ram[0x0E] = 0
  spc.ram[0x0F] = 0
  spc.ram[0x44] = 0x7E
  spc.ram[0x12] = 0x55
  spc.ram[0x0493] = 0x83
  spc.a = 0xA3
  spc.x = 0xA6
  spc.y = 0xD2
  spc.psw = status
  spc.sp = 0xEF

proc execute(spc: var Spc, entry: int): seq[uint16] =
  ## Execute complete original calls and shared returns, rejecting every device access.
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected device read {address:04X}"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, &"unexpected device write {address:04X}={value:02X}"
    false
  spc.pc = entry.uint16
  while spc.pc != ReturnAddress:
    doAssert result.len < 300 and spc.sp in 0xEC'u8 .. 0xF1'u8
    result.add spc.pc
    spc.step()
  doAssert not spc.stopped and spc.sp == 0xF1
  doAssert spc.ram[0x1E8] == Guard and spc.ram[0x1F2] == Guard
  doAssert spc.ram[0x1F0] == 0 and spc.ram[0x1F1] == 0x1E
  spc.readHook = nil
  spc.writeHook = nil

proc nz(value: int): uint8 =
  ## Derive byte N/Z without using CPU implementation helpers.
  (if value == 0: PswZ else: 0'u8) or
    (if value >= 128: PswN else: 0'u8)

proc compareFlags(value, old: int): uint8 =
  ## Predict byte comparison flags independently of the instruction core.
  nz((value - old) and 255) or (if value >= old: PswC else: 0'u8)

proc checkCounterState(spc: var Spc, kind: int) =
  ## Predict an original counter call from its current state without replacing produced fields.
  let
    address = [0x438, 0x43A, 0x439][kind]
    entry = [0x2DAB, 0x2DD5, 0x2DF3][kind]
    count = spc.ram[address].int
    saved = spc.ram[0x493].int
    current = spc.ram[0x53].int
    target = spc.ram[0x20].int
    seed = spc.ram[0x12].int
    restoredX = spc.ram[0x44].int
    status = spc.psw
    next = max(0, count - 1)
  var
    low = spc.ram[0 .. 0xEF]
    high = spc.ram[0x400 .. 0x4FF]
    expectedA = next
    expectedY = spc.y.int
    expectedX = spc.x.int
    flags = (status and PreservedFlags) or PswC or nz(next)
  high[address - 0x400] = next.uint8
  if count == 1:
    expectedA = 0
    flags = (status and PreservedFlags) or PswC or PswZ
    if kind > 0:
      expectedY = if kind == 1: 0xA0 else: 0xF0
      low[0x58] = 0
      low[0x59] = expectedY.uint8
    else:
      low[0x50] = 0
      if saved != 0:
        expectedY = saved
        low[0x52] = 0
        low[0x53] = saved.uint8
      else:
        let
          delta = target - current
          magnitude = 65535 - abs(delta)
          step = (if delta < 0: -magnitude else: magnitude) and 65535
        low[0x54] = 0
        low[0x55] = target.uint8
        low[0x56] = (step and 255).uint8
        low[0x57] = (step shr 8).uint8
        low[0x12] = ((seed shr 1) or (if delta < 0: 128 else: 0)).uint8
        expectedA = step and 255
        expectedY = step shr 8
        expectedX = restoredX
        flags = status and (PswP or PswI or PswB)
        if delta < 0:
          low[0x14] = (magnitude and 255).uint8
          low[0x15] = (magnitude shr 8).uint8
          if step == 0: flags = flags or PswZ
          if step >= 32768: flags = flags or PswN
          if magnitude == 0: flags = flags or PswC
          if (magnitude and 4095) == 0: flags = flags or PswH
          if magnitude == 32768: flags = flags or PswV
        else:
          flags = flags or PswH or PswV or nz(restoredX)
          if (seed and 1) != 0: flags = flags or PswC
  let trace = spc.execute(entry)
  doAssert spc.a.int == expectedA and spc.y.int == expectedY and spc.x.int == expectedX
  doAssert spc.psw == flags
  doAssert spc.ram[0 .. 0xEF] == low and spc.ram[0x400 .. 0x4FF] == high
  doAssert (0x1663'u16 in trace) == (count == 1 and kind == 0)
  doAssert (0x163B'u16 in trace) == (count == 1 and kind == 0)
  doAssert (0x162E'u16 in trace) == (count == 1 and kind > 0)
  doAssert (0xBC7'u16 in trace) == (count == 1 and kind == 0 and saved == 0)

proc checkCounter(spc: var Spc, kind, count, saved, current, target, seed,
    restoredX: int, status: uint8) =
  ## Exercise authored counter states before applying the independent arithmetic oracle.
  spc.prepare(status)
  spc.ram[[0x438, 0x43A, 0x439][kind]] = count.uint8
  spc.ram[0x493] = saved.uint8
  spc.ram[0x53] = current.uint8
  spc.ram[0x20] = target.uint8
  spc.ram[0x12] = seed.uint8
  spc.ram[0x44] = restoredX.uint8
  spc.checkCounterState(kind)

proc checkFilter(spc: var Spc, raw, previous, pending: int, status: uint8) =
  ## Model the masked-input law while leaving the shared code/table tail untouched.
  spc.prepare(status)
  spc.a = raw.uint8
  spc.ram[0x4B7] = previous.uint8
  spc.ram[0x4B3] = pending.uint8
  let
    value = raw and 127
    clear = (value < 8 and previous >= 8) or (value == 7 and previous == 7)
    expectedA = if value == 7: (if previous == 7: 0 else: previous) else: value
    flags = if value == 7: compareFlags(previous, 7) else: compareFlags(value, 7)
  var
    low = spc.ram[0 .. 0xEF]
    high = spc.ram[0x400 .. 0x4FF]
  low[0x20] = value.uint8
  if clear: high[0xB3] = 0
  let trace = spc.execute(0x2E1D)
  for address in 0 .. 0xEF:
    doAssert spc.ram[address] == low[address], &"filter {raw}/{previous}/{pending} low {address:04X}: {spc.ram[address]} != {low[address]}"
  for address in 0x400 .. 0x4FF:
    doAssert spc.ram[address] == high[address - 0x400], &"filter {raw}/{previous}/{pending} high {address:04X}: {spc.ram[address]} != {high[address - 0x400]}"
  doAssert spc.a.int == expectedA and spc.x == 0xA6 and spc.y == 0xD2
  doAssert spc.psw == ((status and PreservedFlags) or flags)
  doAssert (0x2E48'u16 in trace) == (value < 8 and previous >= 8)
  # The original BEQ encoded in table entry zero must execute back into code.
  if value < 8 and previous >= 8:
    let index = trace.find(0x2E48'u16)
    doAssert trace[index + 1] == 0x2E25

proc checkArm(spc: var Spc, command, tempo: int, caller: bool) =
  ## Verify both direct arm entries and the original port-one record dispatcher.
  spc.prepare()
  spc.ram[0x53] = tempo.uint8
  spc.ram[0x4B1] = command.uint8
  spc.ram[0x4D1] = 255
  let
    entry = if command == 5: 0x2DC6 elif command == 7: 0x2DED else: 0x2E0B
    countAddress = if command == 5: 0x438 elif command == 7: 0x43A else: 0x439
    armedCount = if command == 5: 0x70 elif command == 7: 0x28 else: 0x69
    pendingTempo = spc.ram[0x54 .. 0x57]
    master = spc.ram[0x58 .. 0x5E]
    previousSaved = spc.ram[0x493]
    previousPitch = spc.ram[0x50]
    trace = spc.execute(if caller: 0x1198 else: entry)
  doAssert entry.uint16 in trace and spc.ram[countAddress].int == armedCount
  doAssert spc.ram[0x54 .. 0x57] == pendingTempo and spc.ram[0x58 .. 0x5E] == master
  if command == 5:
    doAssert spc.ram[0x50] == 14 and spc.ram[0x493].int == tempo
    doAssert spc.ram[0x52] == 0 and spc.ram[0x53] == 200
    doAssert 0x1663'u16 in trace and 0x1632'u16 in trace and 0xA3B'u16 in trace
    doAssert spc.a == 0 and spc.y == 200
  else:
    doAssert spc.ram[0x50] == previousPitch and spc.ram[0x493] == previousSaved
    doAssert spc.ram[0x53].int == tempo
    doAssert spc.a.int == armedCount
  if caller:
    doAssert 0x12C7'u16 in trace and 0x1317'u16 in trace
    # Structural record bytes stay in the runtime ROM; no extracted header fixture.
    doAssert spc.ram[0x442] == spc.ram[entry - 3]
    doAssert spc.ram[0x443] == spc.ram[entry - 2]
  else:
    doAssert spc.x == 0xA6
    doAssert spc.psw == ((0xDF'u8 and PreservedFlags) or PswC or
      (if command == 5: PswZ else: 0'u8))
    if command != 5: doAssert spc.y == 0xD2

proc checkSelection(spc: var Spc, selection, inhibit: int) =
  ## Check the isolated conditional entry without inferring an unproven original caller.
  spc.prepare()
  spc.ram[4] = selection.uint8
  spc.ram[0x1A] = inhibit.uint8
  let
    oldMask = spc.ram[0x46].int
    pointer = spc.ram[0x2E4C].int + 256 * spc.ram[0x2E4D].int
  var
    low = spc.ram[0 .. 0xEF]
    high = spc.ram[0x400 .. 0x4FF]
  let trace = spc.execute(0x2E11)
  doAssert (0x772'u16 in trace) == (selection == 0x1C)
  if selection == 0x1C:
    low[4] = 2
    low[0x40] = (pointer and 255).uint8
    low[0x41] = (pointer shr 8).uint8
    low[0x0C] = 2
    low[0x46] = (oldMask or (255 xor inhibit)).uint8
    for address in [0x491, 0x4B1, 0x4B5]: high[address - 0x400] = 0
    doAssert spc.a.int == (255 xor inhibit) and spc.x == 4 and spc.y.int == (pointer shr 8)
    doAssert spc.psw == ((0xDF'u8 and (PswP or PswI or PswB)) or
      (compareFlags(255 xor inhibit, oldMask) and (PswN or PswZ)))
  else:
    doAssert spc.a.int == selection and spc.x == 0xA6 and spc.y == 0xD2
    doAssert spc.psw == ((0xDF'u8 and PreservedFlags) or compareFlags(selection, 0x1C))
  doAssert spc.ram[0 .. 0xEF] == low and spc.ram[0x400 .. 0x4FF] == high

proc checkImage(image: seq[uint8]): Totals =
  ## Exercise byte domains and complete original helper paths with authored state.
  var spc = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[DriverMap + address]
  for kind in 0 .. 2:
    for count in 0 .. 255:
      for status in [0'u8, 0xDF'u8]:
        spc.checkCounter(kind, count, 0x83, 0x91, 0x72, 0x55, 0x7E, status)
        inc result.counters
  for current in 0 .. 255:
    for target in 0 .. 255:
      spc.checkCounter(0, 1, 0, current, target, current xor target,
        (current + target) and 255, (if (current and 1) == 0: 0'u8 else: 0xDF'u8))
      inc result.fallbacks
  for saved in 1 .. 255:
    spc.checkCounter(0, 1, saved, 0x91, 0x72, 0x55, 0x7E, 0xDF)
    inc result.counters
  for raw in 0 .. 255:
    for previous in 0 .. 255:
      for pending in [raw, raw xor 0xA5]:
        spc.checkFilter(raw, previous, pending, (if (raw and 1) == 0: 0'u8 else: 0xDF'u8))
        inc result.filters
  for command in [5, 7, 8]:
    for tempo in 0 .. 255:
      spc.checkArm(command, tempo, false)
      inc result.arms
    for tempo in [0, 1, 127, 128, 255]:
      spc.checkArm(command, tempo, true)
      inc result.callers
      let
        kind = if command == 5: 0 elif command == 7: 1 else: 2
        address = [0x438, 0x43A, 0x439][kind]
        count = spc.ram[address].int
      # Preserve the original dispatcher's scratch $20 and all arm output.
      # These are repeated isolated service calls, not an absolute timer model.
      for tick in 0 .. count:
        spc.sp = 0xEF
        spc.checkCounterState(kind)
        inc result.chainTicks
      doAssert spc.ram[address] == 0
      inc result.chains
  for selection in 0 .. 255:
    for inhibit in [0, 0x55, 0x80, 255]:
      spc.checkSelection(selection, inhibit)
      inc result.selections

proc main() =
  ## Require original and fresh byte-identical rebuilt images and report executed cases.
  var totals: Totals
  for image in engineImages("bin/spc_auxiliary_service_extract"):
    let checked = checkImage(image)
    totals.counters += checked.counters
    totals.fallbacks += checked.fallbacks
    totals.filters += checked.filters
    totals.arms += checked.arms
    totals.callers += checked.callers
    totals.selections += checked.selections
    totals.chains += checked.chains
    totals.chainTicks += checked.chainTicks
  echo &"SPC auxiliary service passed: {totals.counters} counter cases, {totals.fallbacks} fallback divisions, {totals.filters} filters, {totals.arms} direct arms, {totals.callers} original arm callers, {totals.selections} conditional selections, {totals.chains} produced-countdown chains and {totals.chainTicks} chain ticks including zero holds."

when isMainModule:
  main()
