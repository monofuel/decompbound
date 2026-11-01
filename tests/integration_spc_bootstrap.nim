## Verify full original/rebuilt startup from dirty state without audio playback.
import
  std/strformat,
  decompbound/[apu, dsp, spc700],
  ./engine/rebuilt_rom

type PortWrite = tuple[address: uint16, value: uint8]

const
  DriverStart = 0x0500
  DriverLength = 16779
  DriverPayload = 0x260042
  StartupExit = 0x0546'u16
  InstructionBudget = 40000

proc dirtyByte(address, seed: int): uint8 =
  ## Give every untouched byte a repeatable synthetic guard value.
  ((address * 37 + seed * 19 + 113) and 255).uint8

proc appendDsp(writes: var seq[PortWrite], register, value: int) =
  ## Append a named-register DSP address/data transaction.
  writes.add (0xF2'u16, register.uint8)
  writes.add (0xF3'u16, value.uint8)

proc expectedPorts(oldEdl: int): seq[PortWrite] =
  ## Specify startup hardware effects without copying descriptor-table bytes.
  result.add (0xF2'u16, 0x7D'u8)
  if oldEdl != 1:
    for register in [0x4D, 0x0D, 0x3C, 0x2C]: result.appendDsp(register, 0)
    result.appendDsp(0x6C, 0x20)
    result.appendDsp(0x7D, 1)
  result.appendDsp(0x6D, 0xF7)
  result.appendDsp(0x0C, 0x70)
  result.appendDsp(0x1C, 0x70)
  result.appendDsp(0x5D, 0x6C)
  result.add (0xF1'u16, 0xF0'u8)
  result.add (0xFA'u16, 0x10'u8)
  result.add (0xF1'u16, 1'u8)

proc checkStartup(rom: seq[uint8], oldEdl, status, seed: int): int =
  ## Run all original startup instructions, including real callees, from dirty RAM.
  var
    spc = newSpc()
    writes: seq[PortWrite]
    reads = 0
    timerEnabled = [true, true, true]
    timerTargets = [0x71, 0x82, 0x93]
    inputPorts = [0x51, 0x62, 0x73, 0x84]
    iplMapped = true
    timerResetCount = 0
    minimumSp = 255
  for address in 0 .. 65535: spc.ram[address] = dirtyByte(address, seed)
  for index in 0 ..< DriverLength: spc.ram[DriverStart + index] = rom[DriverPayload + index]
  let before = spc.ram[]
  spc.a = seed.uint8
  spc.x = (255 - seed).uint8
  spc.y = (seed xor 0xA5).uint8
  spc.sp = (seed xor 0x5A).uint8
  spc.psw = status.uint8
  spc.iplEnabled = true
  spc.pc = DriverStart.uint16
  spc.readHook = proc(address: uint16): int =
    doAssert address == 0xF3 and reads == 0
    doAssert writes == @[(0xF2'u16, 0x7D'u8)]
    inc reads
    oldEdl
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    writes.add (address, value)
    if address == 0xF1:
      iplMapped = (value and 0x80) != 0
      for timer in 0 .. 2:
        let enabled = (value.int and (1 shl timer)) != 0
        if enabled and not timerEnabled[timer]: inc timerResetCount
        timerEnabled[timer] = enabled
      if (value and 0x10) != 0:
        inputPorts[0] = 0
        inputPorts[1] = 0
      if (value and 0x20) != 0:
        inputPorts[2] = 0
        inputPorts[3] = 0
    elif address == 0xFA: timerTargets[0] = value.int
    true
  while spc.pc != StartupExit:
    doAssert result < InstructionBudget, &"startup stalled at ${spc.pc:04X}"
    spc.step()
    # The bootstrap sets SP before it performs any CALL.
    if (spc.pc >= 0x0504 and spc.pc < 0x050C) or result > 5:
      minimumSp = min(minimumSp, spc.sp.int)
    inc result
  doAssert reads == 1 and writes == expectedPorts(oldEdl)
  doAssert timerEnabled == [true, false, false]
  doAssert timerTargets == [16, 0x82, 0x93] and timerResetCount == 1
  doAssert inputPorts == [0, 0, 0, 0]
  # Model CONTROL effects from our I/O layer without constructing a DSP/APU.
  doAssert not iplMapped
  doAssert spc.a == 1 and spc.x == 0 and spc.y == 0x5D and spc.sp == 0xCF
  doAssert minimumSp == (if oldEdl == 1: 0xCD else: 0xCB), &"minimum SP ${minimumSp:02X}"
  doAssert spc.ram[0x1CF] == 0x05 and spc.ram[0x1CE] == 0x30
  if oldEdl != 1:
    doAssert spc.ram[0x1CD] == 0x0B and spc.ram[0x1CC] == 0x65
  else:
    doAssert spc.ram[0x1CD] == before[0x1CD] and spc.ram[0x1CC] == before[0x1CC]
  doAssert spc.psw == ((status.uint8 and (PswI or PswB)) or PswC or PswH)
  for address in 0 .. 0xDF:
    let expected = case address
      of 0x18, 0x19: 0x55
      of 0x25: 0xFF
      of 0x48: 0x20
      of 0x4C: (if oldEdl == 1: 0 else: 255 - (oldEdl and 15))
      of 0x4D: 1
      of 0x53: 16
      else: 0
    doAssert spc.ram[address].int == expected, &"DP ${address:02X}"
  for address in 0 .. 65535:
    if address <= 0xDF or address in 0x1CC .. 0x1CF: continue
    # These four immediates come from executed $2FC8 initialization.
    # TODO: Identify the auxiliary configuration fields' game-level meanings.
    let expected = if address in 0x420 .. 0x4FF or address in 0xE800 .. 0xFEFF:
      case address
        of 0x4D1: 0x1D'u8
        of 0x4D2: 9'u8
        of 0x4D3: 0x80'u8
        of 0x4D4: 0xC0'u8
        else: 0'u8
      else: before[address]
    doAssert spc.ram[address] == expected, &"RAM ${address:04X}"

proc checkApu(rom: seq[uint8], oldEdl: uint8, initiallyEnabled: bool): int =
  ## Exercise real CONTROL/DSP hooks without running a sample mixer or device.
  let machine = newApu()
  for address in 0 .. 65535: machine.spc.ram[address] = dirtyByte(address, oldEdl.int)
  for index in 0 ..< DriverLength:
    machine.spc.ram[DriverStart + index] = rom[DriverPayload + index]
  machine.portsIn = [0x51'u8, 0x62, 0x73, 0x84]
  machine.portsOut = [0x15'u8, 0x26, 0x37, 0x48]
  machine.spc.iplEnabled = true
  machine.spc.pc = DriverStart.uint16
  machine.spc.psw = 255
  machine.dsp.write(0x7D, oldEdl)
  machine.dsp.write(0x6C, 0x40)
  for register in [0x4D'u8, 0x0D, 0x3C, 0x2C]: machine.dsp.write(register, 0xA6)
  for timer in 0 .. 2:
    machine.setTimerSnapshot(timer, TimerSnapshot(enabled: initiallyEnabled,
      target: (0x71 + timer).uint8, internal: 7, counter: 11, accum: 19))
  var
    controlWrites = 0
    targetWrites = 0
  while machine.spc.pc != StartupExit:
    doAssert result < InstructionBudget
    let
      pc = machine.spc.pc
      oldControlCount = controlWrites
    machine.spc.step()
    inc result
    if pc == 0x0532:
      inc controlWrites
      doAssert machine.portsIn == [0'u8, 0, 0, 0]
      doAssert machine.spc.iplEnabled
      for timer in 0 .. 2:
        let state = machine.getTimerSnapshot(timer)
        doAssert not state.enabled and state.internal == 7 and state.counter == 11
        doAssert state.target == (0x71 + timer).uint8 and state.accum == 19
    elif pc == 0x0537:
      inc targetWrites
      doAssert controlWrites == 1
      doAssert machine.getTimerSnapshot(0).target == 16
      for timer in 0 .. 2: doAssert not machine.getTimerSnapshot(timer).enabled
    elif pc == 0x053E:
      inc controlWrites
      doAssert oldControlCount == 1 and targetWrites == 1
      doAssert not machine.spc.iplEnabled
  doAssert controlWrites == 2 and targetWrites == 1
  doAssert machine.portsIn == [0'u8, 0, 0, 0]
  doAssert machine.portsOut == [0x15'u8, 0x26, 0x37, 0x48]
  for timer in 0 .. 2:
    let state = machine.getTimerSnapshot(timer)
    doAssert state.enabled == (timer == 0)
    doAssert state.target == (if timer == 0: 16'u8 else: (0x71 + timer).uint8)
    doAssert state.internal == (if timer == 0: 0'u8 else: 7'u8)
    doAssert state.counter == (if timer == 0: 0'u8 else: 11'u8)
    doAssert state.accum == 19
  doAssert machine.dsp.read(0x7D) == 1
  doAssert machine.dsp.read(0x6D) == 0xF7
  doAssert machine.dsp.read(0x0C) == 0x70 and machine.dsp.read(0x1C) == 0x70
  doAssert machine.dsp.read(0x5D) == 0x6C
  doAssert machine.dsp.read(0x6C) == (if oldEdl == 1: 0x40'u8 else: 0x20'u8)
  for register in [0x4D'u8, 0x0D, 0x3C, 0x2C]:
    doAssert machine.dsp.read(register) == (if oldEdl == 1: 0xA6'u8 else: 0'u8)
  # No tickTimers/runSample call occurs here: configuration is the tested scope.

proc main() =
  ## Check both images, every readback/status byte, and real I/O configuration.
  var
    instructions = 0
    startups = 0
    apuContexts = 0
  for image in engineImages("bin/spc_bootstrap_extract"):
    for value in 0 .. 255:
      instructions += checkStartup(image, value, value xor 0xA5, value)
      inc startups
      instructions += checkStartup(image, 1, value, 255 - value)
      inc startups
    for oldEdl in [0'u8, 1, 15, 16, 255]:
      for initiallyEnabled in [false, true]:
        instructions += checkApu(image, oldEdl, initiallyEnabled)
        inc apuContexts
  echo &"SPC bootstrap passed: {startups} dirty original/rebuilt startups, " &
    &"{apuContexts} real APU configuration contexts, {instructions} executed instructions."

when isMainModule:
  main()
