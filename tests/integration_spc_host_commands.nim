## Specify the host-command gate and its distinct history/shared/sign-guard entries.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  Expected = object
    destination, accumulator, countdown: int
    flags: uint8
  Totals = object
    histories, countdowns, shared, guards, exchanges, selections: int

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  HistoryEntry = 0x07F9'u16
  SharedEntry = 0x07FF'u16
  GuardEntry = 0x07F4'u16
  ReturnAddress = 0x1E00'u16
  Preserved = PswP or PswI or PswB or PswH or PswV
  Edges = [0, 1, 127, 128, 255]

proc comparison(left, right: int): uint8 =
  ## Predict byte-comparison flags without updating either operand.
  let difference = (left - right) and 255
  (if left >= right: PswC else: 0'u8) or
    (if difference == 0: PswZ else: 0'u8) or
    (if difference >= 128: PswN else: 0'u8)

proc model(command, previous, sampled, activity, count: int): Expected =
  ## Give special commands priority over change detection and unsigned reset-count routing.
  result.accumulator = command
  result.countdown = count
  if command == 0xF0:
    result.destination = 0x787
    result.flags = PswC or PswZ
  elif command == 0xFF:
    result.destination = 0x7E4
    result.flags = PswC or PswZ
  elif command != 0xF1 and previous != sampled:
    result.destination = 0x7E7
    result.flags = comparison(previous, sampled)
  elif activity == 0:
    result.destination = 0x7E3
    result.accumulator = 0
    result.flags = PswC or PswZ
  elif count == 0:
    result.destination = 0x871
    result.accumulator = 0
    result.flags = PswC or PswZ
  else:
    result.countdown = count - 1
    result.accumulator = count
    result.destination = if count == 1: 0x81A else: 0x7A9
    result.flags = PswC or (if count >= 128: PswN else: 0'u8)

proc frame(spc: var Spc) =
  ## Supply a native caller frame and guards without changing produced command state.
  spc.sp = 0xEF
  spc.ram[0x1F0] = 0
  spc.ram[0x1F1] = 0x1E
  spc.ram[0x1ED] = 0xA5
  spc.ram[0x1F2] = 0xA5

proc prepare(spc: var Spc, command, previous, sampled, activity, count: int,
    status: uint8) =
  ## Install independent authored command, sampled-input and prior-history values.
  spc.frame()
  spc.ram[0] = sampled.uint8
  spc.ram[4] = activity.uint8
  spc.ram[8] = previous.uint8
  spc.ram[0x0C] = count.uint8
  spc.a = command.uint8
  spc.y = previous.uint8
  spc.x = 0xA6
  spc.psw = status

proc verify(spc: var Spc, entry: uint16) =
  ## Execute unchanged code to its real branch boundary, retaining exact history and flags.
  let
    before = spc.ram[0 .. 0xEF]
    status = spc.psw
    oldY = spc.y.int
    guardReturns = entry == GuardEntry and before[8] < 128
    command = if entry == HistoryEntry: before[0].int
      elif entry == GuardEntry: before[8].int else: spc.a.int
    previous = if entry == HistoryEntry: before[8].int else: oldY
    expected = model(command, previous, before[0].int, before[4].int, before[0x0C].int)
    stop = if guardReturns: ReturnAddress else: expected.destination.uint16
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected command-gate hardware read ${address:04X}"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, &"unexpected command-gate hardware write ${address:04X}"
    false
  spc.pc = entry
  var instructions = 0
  while spc.pc != stop:
    doAssert instructions < 20, &"command gate ${entry:04X} at ${spc.pc:04X}"
    spc.step()
    inc instructions
  doAssert spc.x == 0xA6 and not spc.stopped
  doAssert spc.ram[0x1ED] == 0xA5 and spc.ram[0x1F2] == 0xA5
  doAssert spc.ram[0x1F0] == 0 and spc.ram[0x1F1] == 0x1E
  if guardReturns:
    doAssert spc.sp == 0xF1 and spc.a == before[8] and spc.y.int == oldY
    let nz = (if before[8] == 0: PswZ else: 0'u8)
    doAssert spc.psw == ((status and not (PswN or PswZ)) or nz)
    doAssert spc.ram[0 .. 0xEF] == before
  else:
    doAssert spc.sp == 0xEF
    doAssert spc.a.int == expected.accumulator and spc.y.int == previous
    doAssert spc.ram[0x0C].int == expected.countdown
    doAssert spc.psw == ((status and Preserved) or expected.flags)
    for address in 0 .. 0xEF:
      let value = if entry == HistoryEntry and address == 8: before[0].int
        elif address == 0x0C: expected.countdown else: before[address].int
      doAssert spc.ram[address].int == value
  spc.readHook = nil
  spc.writeHook = nil

proc producerChains(spc: var Spc, totals: var Totals) =
  ## Carry real port-exchange output unchanged into history classification and selection setup.
  for input in 0 .. 255:
    for old in Edges:
      spc.prepare(0, old, 0, 1, 2, 0)
      var writes: seq[(uint16, uint8)]
      var reads = 0
      spc.readHook = proc(address: uint16): int =
        doAssert address == 0xF4
        inc reads
        input
      spc.writeHook = proc(address: uint16, value: uint8): bool =
        writes.add (address, value)
        false
      spc.pc = 0x625
      var instructions = 0
      while spc.pc != ReturnAddress:
        doAssert instructions < 10
        spc.step()
        inc instructions
      doAssert reads == 2 and writes == @[(0xF4'u16, 1'u8)]
      doAssert spc.ram[0].int == input and spc.ram[8].int == old
      spc.frame()
      spc.verify(HistoryEntry)
      inc totals.exchanges
  for selection in 0 .. 127:
    spc.prepare(0, 255, selection, 1, 2, 0)
    spc.ram[0x1A] = 0x55
    spc.ram[0x46] = 0x81
    # Author pointer-table entries; no game sequence data is copied into fixtures.
    let cursor = 0x4800 + selection * 2
    spc.ram[0x2E48 + 2 * selection] = (cursor and 255).uint8
    spc.ram[0x2E49 + 2 * selection] = (cursor shr 8).uint8
    spc.verify(HistoryEntry)
    doAssert spc.pc == 0x7E7
    var instructions = 0
    while spc.pc != ReturnAddress:
      doAssert instructions < 35
      spc.step()
      inc instructions
    doAssert spc.ram[4].int == selection and spc.ram[8].int == selection
    doAssert spc.ram[0x40].int + 256 * spc.ram[0x41].int == cursor
    doAssert spc.ram[0x0C] == 2 and spc.ram[0x46] == 0xAB
    doAssert spc.ram[0x491] == 0 and spc.ram[0x4B1] == 0 and spc.ram[0x4B5] == 0
    doAssert spc.sp == 0xF1
    inc totals.selections

proc main() =
  ## Require original and byte-identical rebuilt code for all command and shared-entry matrices.
  var totals: Totals
  for image in engineImages("bin/spc_host_commands_extract"):
    var spc = newSpc()
    for address in DriverStart ..< DriverStart + DriverLength:
      spc.ram[address] = image[DriverMap + address]
    for address in 0 .. 0xEF: spc.ram[address] = 0xA5
    for command in 0 .. 255:
      for previous in 0 .. 255:
        for status in [0'u8, 0xDF'u8]:
          spc.prepare(command, previous, command, 1, 2, status)
          spc.verify(HistoryEntry)
          inc totals.histories
    for activity in 0 .. 255:
      for count in 0 .. 255:
        for command in [0x1C, 0xF1]:
          for status in [0'u8, 0xDF'u8]:
            spc.prepare(command, command, command, activity, count, status)
            spc.verify(HistoryEntry)
            inc totals.countdowns
    for command in 0 .. 255:
      for sampled in 0 .. 255:
        for previous in [sampled, (sampled + 1) and 255]:
          for status in [0'u8, 0xDF'u8]:
            spc.prepare(command, previous, sampled, 1, 2, status)
            spc.verify(SharedEntry)
            inc totals.shared
    for command in 0 .. 255:
      for sampled in Edges:
        for previous in Edges:
          spc.prepare(0, command, sampled, 1, 2, 0xDF)
          spc.y = previous.uint8
          spc.verify(GuardEntry)
          inc totals.guards
    spc.producerChains(totals)
  echo &"SPC host commands passed: {totals.histories} history entries, {totals.countdowns} activity/countdown contexts, " &
    &"{totals.shared} independent shared entries, {totals.guards} sign guards, {totals.exchanges} real exchange chains " &
    &"and {totals.selections} command-to-selection consumers."

when isMainModule:
  main()
