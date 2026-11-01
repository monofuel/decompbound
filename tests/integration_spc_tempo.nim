## Independently verify original tempo commands, tick arithmetic and phase routing.
## All streams/state are synthetic; the driver executes silently in plain SPC RAM.

import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  DispatchEntry = 0x0943'u16
  TickEntry = 0x08F6'u16
  TickExit = 0x0905'u16
  UpdateEntry = 0x07F9'u16
  PhaseEntry = 0x05CD'u16
  PhaseUpdateExit = 0x05DB'u16
  PhaseNoCarryExit = 0x05E0'u16
  ReturnAddress = 0x1E00'u16
  GuardByte = 0xA5'u8
  Durations = [0, 1, 2, 3, 127, 255]
  ByteEdges = [0, 1, 127, 128, 254, 255]
  WordEdges = [0, 1, 255, 256, 32767, 32768, 65534, 65535]

proc word(spc: Spc, address: int): int =
  ## Read a little-endian word without using emulated arithmetic.
  spc.ram[address].int or (spc.ram[address + 1].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Store authored state modulo sixteen bits.
  spc.ram[address] = uint8(value and 255)
  spc.ram[address + 1] = uint8((value shr 8) and 255)

proc prepareStack(spc: var Spc) =
  ## Install a synthetic caller return and guards below the deepest native call.
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1EB] = GuardByte
  spc.ram[0x1F2] = GuardByte
  spc.sp = 0xEF

proc execute(spc: var Spc, entry, stop: uint16, budget: int) =
  ## Execute unmodified driver instructions within a bounded stack and instruction budget.
  spc.pc = entry
  var steps = 0
  while spc.pc != stop:
    doAssert steps < budget, &"tempo entry ${entry:04X} exceeded its step budget"
    doAssert spc.sp in 0xEC'u8 .. 0xF1'u8
    spc.step()
    inc steps
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1EB] == GuardByte and spc.ram[0x1F2] == GuardByte
  doAssert not spc.stopped

proc expectedStep(current, target, duration: int): int =
  ## Specify signed full-byte displacement divided into an 8.8 step.
  let
    delta = target - current
    quotient = if duration == 0: 65535 - abs(delta) else: abs(delta) * 256 div duration
  (if delta < 0: -quotient else: quotient) and 65535

proc checkCommand(spc: var Spc, opcode, channel, stream, currentWord,
    operand, target, oldDuration: int) =
  ## Verify full E7/E8 dispatch, byte consumption, preserved neighbors and state fields.
  let pointer = 0x30 + channel
  for address in 0 .. 0xEF:
    spc.ram[address] = uint8((address * 37 + 11) and 255)
  spc.putWord(0x0E, 0)      # The shared signed divide subtracts from this explicit base.
  spc.ram[0x44] = channel.uint8
  spc.putWord(pointer, stream)
  spc.putWord(0x52, currentWord)
  spc.ram[0x54] = oldDuration.uint8
  spc.ram[0x55] = 0xC3
  spc.putWord(0x56, 0xB47D)
  spc.ram[stream] = operand.uint8
  spc.ram[(stream + 1) and 65535] = target.uint8
  spc.ram[(stream + 2) and 65535] = 0x6A
  let before = spc.ram[0 .. 0xEF]
  spc.prepareStack()
  spc.x = channel.uint8
  spc.a = opcode.uint8
  spc.y = 0xA6
  spc.psw = PswI or PswB or PswC
  spc.execute(DispatchEntry, ReturnAddress, 80)
  let consumed = if opcode == 0xE7: 1 else: 2
  doAssert spc.word(pointer) == ((stream + consumed) and 65535)
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.word(0x0E) == 0 and spc.ram[0x44].int == channel
  if opcode == 0xE7:
    doAssert spc.word(0x52) == operand * 256
    doAssert spc.ram[0x54].int == oldDuration
    doAssert spc.ram[0x55] == 0xC3 and spc.word(0x56) == 0xB47D
    doAssert spc.a == 0 and spc.y.int == operand
  else:
    let step = expectedStep(currentWord shr 8, target, operand)
    doAssert spc.word(0x52) == currentWord
    doAssert spc.ram[0x54].int == operand and spc.ram[0x55].int == target
    doAssert spc.word(0x56) == step,
      $[currentWord, target, operand, step, spc.word(0x56)]
    doAssert spc.a.int + 256 * spc.y.int == step
  for address in 0 .. 0xEF:
    let changed = address in pointer .. pointer + 1 or address in 0x52 .. 0x53 or
      (opcode == 0xE8 and address in [0x12, 0x14, 0x15, 0x54, 0x55, 0x56, 0x57])
    if not changed:
      doAssert spc.ram[address] == before[address], &"tempo command changed DP ${address:02X}"
  doAssert spc.ram[stream].int == operand
  doAssert spc.ram[(stream + 1) and 65535].int == target
  doAssert spc.ram[(stream + 2) and 65535] == 0x6A
  doAssert (spc.psw and (PswI or PswB or PswP)) == (PswI or PswB)

proc tick(spc: var Spc) =
  ## Check one direct update fragment, with final-tick snap and zero-counter freeze.
  let
    current = spc.word(0x52)
    duration = spc.ram[0x54].int
    target = spc.ram[0x55].int
    step = spc.word(0x56)
    remaining = max(0, duration - 1)
    expected = if duration == 0: current elif remaining == 0: target * 256
      else: (current + step) and 65535
    before = spc.ram[0 .. 0xEF]
  spc.prepareStack()
  spc.x = 0xA6
  spc.y = 0xC3
  spc.a = 0x5A
  spc.psw = PswI or PswB or PswC or PswZ
  spc.execute(TickEntry, TickExit, 16)
  doAssert spc.sp == 0xEF and spc.x == 0xA6
  doAssert spc.word(0x52) == expected and spc.ram[0x54].int == remaining
  doAssert spc.ram[0x55].int == target and spc.word(0x56) == step
  for address in 0 .. 0xEF:
    if address notin [0x52, 0x53, 0x54]:
      doAssert spc.ram[address] == before[address], &"tempo tick changed DP ${address:02X}"

proc prepareUpdate(spc: var Spc, active: int) =
  ## Configure an unchanged command and eight absent streams for a silent full update.
  for address in 0 .. 0xEF:
    spc.ram[address] = 0
  spc.ram[0x04] = active.uint8
  spc.prepareStack()
  spc.psw = 0

proc checkUpdateGate(spc: var Spc, active, current, duration, step, target: int) =
  ## Verify the actual $07F9 path gates tempo updates on nonzero active byte $04.
  spc.prepareUpdate(active)
  spc.putWord(0x52, current)
  spc.ram[0x54] = duration.uint8
  spc.ram[0x55] = target.uint8
  spc.putWord(0x56, step)
  spc.execute(UpdateEntry, ReturnAddress, 250)
  let
    enabled = active != 0 and duration != 0
    remaining = if enabled: duration - 1 else: duration
    expected = if not enabled: current elif remaining == 0: target * 256
      else: (current + step) and 65535
  doAssert spc.sp == 0xF1
  doAssert spc.word(0x52) == expected and spc.ram[0x54].int == remaining
  doAssert spc.ram[0x04].int == active
  doAssert spc.ram[0x55].int == target and spc.word(0x56) == step
  for voice in 0 ..< 8:
    doAssert spc.word(0x30 + voice * 2) == 0

proc checkPhaseOrder(spc: var Spc, zeroTempo: bool) =
  ## Verify phase uses the prior tempo and can stall normal carry-driven updates at zero.
  spc.prepareUpdate(1)
  let oldTempo = if zeroTempo: 0 else: 4
  spc.putWord(0x52, oldTempo * 256 + 127)
  spc.ram[0x54] = 2
  spc.ram[0x55] = 20
  spc.putWord(0x56, 3 * 256)
  spc.ram[0x51] = 250
  # $05CD pops the timer-count byte before calling $07F9 on phase carry.
  spc.ram[0x1EF] = (if zeroTempo: 15'u8 else: 2'u8)
  spc.sp = 0xEE
  let stop = if zeroTempo: PhaseNoCarryExit else: PhaseUpdateExit
  spc.execute(PhaseEntry, stop, 280)
  doAssert spc.sp == 0xEF
  doAssert spc.ram[0x51].int == (if zeroTempo: 250 else: 2)
  doAssert spc.ram[0x54].int == (if zeroTempo: 2 else: 1)
  doAssert spc.word(0x52) == (oldTempo + (if zeroTempo: 0 else: 3)) * 256 + 127
  if not zeroTempo:
    # Poll once more without a carry: the new tempo is used, but no tick occurs.
    spc.ram[0x1EF] = 1
    spc.sp = 0xEE
    spc.execute(PhaseEntry, PhaseNoCarryExit, 20)
    doAssert spc.ram[0x51] == 9 and spc.ram[0x54] == 1
    doAssert spc.word(0x52) == 7 * 256 + 127

proc checkImage(image: seq[uint8]): tuple[setters, fades, ticks, transitions,
    gates, phaseOrders, replacements: int] =
  ## Exercise original command dispatch and silent full-update contexts on one ROM.
  var spc = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[DriverMap + address]
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, &"tempo test unexpectedly wrote I/O ${address:04X}=${value:02X}"
    false
  for operand in 0 .. 255:
    for voice in 0 ..< 8:
      for oldDuration in [0, 1, 255]:
        for stream in [0x48FF, 0xFFFF]:
          spc.checkCommand(0xE7, voice * 2, stream, 0xB47D, operand, 0x6A, oldDuration)
          inc result.setters
  for current in 0 .. 255:
    for target in 0 .. 255:
      let
        duration = Durations[(current + target) mod Durations.len]
        fraction = (current * 37 + target * 19) and 255
      spc.checkCommand(0xE8, ((current xor target) and 7) * 2,
        (if (current + target) mod 2 == 0: 0x48FF else: 0xFFFF),
        current * 256 + fraction, duration, target, 255)
      inc result.fades
  for duration in 0 .. 255:
    for target in 0 .. 255:
      spc.checkCommand(0xE8, ((duration xor target) and 7) * 2, 0x48FF,
        128 * 256 + ((duration + target) and 255), duration, target, 1)
      inc result.fades
  for current in ByteEdges:
    for target in ByteEdges:
      for duration in Durations:
        for fraction in [0, 127, 255]:
          spc.checkCommand(0xE8, 14, 0xFFFF, current * 256 + fraction,
            duration, target, 255)
          inc result.fades
          for index in 0 .. duration:
            spc.tick()
            inc result.ticks
          doAssert spc.word(0x52) ==
            (if duration == 0: current * 256 + fraction else: target * 256)
          inc result.transitions
  for current in WordEdges:
    for step in WordEdges:
      for duration in [0, 1, 2, 255]:
        for target in [0, 1, 127, 255]:
          spc.putWord(0x52, current)
          spc.ram[0x54] = duration.uint8
          spc.ram[0x55] = target.uint8
          spc.putWord(0x56, step)
          spc.tick()
          inc result.ticks
  for active in [0, 1, 128, 255]:
    for current in WordEdges:
      for duration in [0, 1, 2, 255]:
        spc.checkUpdateGate(active, current, duration, 0xFFFF, 127)
        inc result.gates
  for operand in [0, 1, 127, 255]:
    spc.checkCommand(0xE7, 0, 0x48FF, 0x1234, operand, 0, 2)
    spc.tick()             # E7 leaves the prior fade active from the new tempo word.
    inc result.ticks
    doAssert spc.word(0x52) == ((operand * 256 + 0xB47D) and 65535)
    inc result.replacements
  for zeroTempo in [false, true]:
    spc.checkPhaseOrder(zeroTempo)
    inc result.phaseOrders

proc main() =
  ## Report actually executed tempo cases for original and freshly rebuilt driver images.
  for index, image in engineImages("bin/spc_tempo_extract"):
    let
      counts = checkImage(image)
      name = if index == 0: "original" else: "rebuilt"
    echo &"{name}: {counts.setters} E7, {counts.fades} E8, {counts.ticks} ticks, {counts.transitions} complete direct-tick transitions, {counts.gates} active gates, {counts.phaseOrders} phase-order contexts and {counts.replacements} active-fade replacements passed"

when isMainModule:
  main()
