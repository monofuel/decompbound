## Verify stream-free service adapters and countdown expiry on both ROM images.
import
  std/[strformat, tables],
  decompbound/[apu, spc700],
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x500
  DriverLength = 16779
  ReturnAddress = 0x4000'u16
  RetainedFlags = PswI or PswB or PswH or PswV

type PortWrite = tuple[address: uint16, value: uint8]

proc word(spc: Spc, address: int): int =
  ## Read a synthetic little-endian word.
  spc.ram[address].int or (spc.ram[address + 1].int shl 8)

proc signedStep(delta, duration: int): int =
  ## Calculate the independent integer quotient, including zero-divisor behavior.
  let magnitude = if duration == 0: 65535 - abs(delta) else: abs(delta) * 256 div duration
  (if delta < 0: -magnitude else: magnitude) and 65535

proc prepare(spc: var Spc, channel, seed, status: int) =
  ## Guard low memory, arrange a real caller frame, and initialize divider prerequisites.
  for address in 0 .. 0x4FF:
    spc.ram[address] = ((address * 37 + seed * 19 + 113) and 255).uint8
  spc.ram[0x0E] = 0
  spc.ram[0x0F] = 0
  spc.ram[0x44] = channel.uint8
  spc.ram[0x1F0] = 0
  spc.ram[0x1F1] = 0x40
  spc.sp = 0xEF
  spc.a = seed.uint8
  spc.x = channel.uint8
  spc.y = (seed xor 0xA5).uint8
  spc.psw = status.uint8

proc run(spc: var Spc, entry: int, allowControl = false): seq[PortWrite] =
  ## Execute unchanged original helpers and real shared tails with a bounded stack.
  var writes: seq[PortWrite]
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected read ${address:04X}"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert allowControl and address == 0xF1 and value == 0x31
    writes.add (address, value)
    true
  spc.pc = entry.uint16
  var instructions = 0
  while spc.pc != ReturnAddress:
    doAssert instructions < 150, &"entry ${entry:04X} PC ${spc.pc:04X}"
    doAssert spc.sp >= 0xEB
    spc.step()
    inc instructions
  doAssert spc.sp == 0xF1 and spc.word(0x1F0) == ReturnAddress.int
  result = writes

proc guarded(spc: Spc, before: array[0x10000, uint8], changes: Table[int, int],
             scratch: openArray[int] = []) =
  ## Assert explicit mathematical outputs and every unrelated low-memory neighbor.
  for address in 0 .. 0x4FF:
    if address in 0x1EC .. 0x1EF or address in scratch: continue
    let expected = if changes.hasKey(address): changes[address].uint8 else: before[address]
    doAssert spc.ram[address] == expected, &"changed ${address:04X}: {spc.ram[address]} vs {expected}"

proc checkCountdown(spc: var Spc): int =
  ## Exhaust every countdown/mask byte and both carry inputs through real reset callees.
  for count in 0 .. 255:
    for mask in 0 .. 255:
      let status = if (mask and 1) == 0: 0 else: 0xDF
      spc.prepare(6, mask, status)
      spc.ram[0x491] = count.uint8
      for address in [0x1A, 0x46, 0x47, 0x5E]: spc.ram[address] = mask.uint8
      let before = spc.ram[]
      let ports = spc.run(0x1609, true)
      let expectedCount = if count in [0, 255]: 0 else: count - 1
      var changes = {0x491: expectedCount}.toTable
      if count == 1:
        doAssert ports == @[(0xF1'u16, 0x31'u8)]
        for address in 0x4B0 .. 0x4B7: changes[address] = 0
        changes[0x1A] = mask and 31
        for address in [0x46, 0x47, 0x5E]: changes[address] = mask or 224
      else: doAssert ports.len == 0
      spc.guarded(before, changes)
      doAssert spc.a.int == expectedCount and spc.x == 6 and spc.y == (mask xor 0xA5).uint8
      doAssert (spc.psw and RetainedFlags) == (status.uint8 and RetainedFlags)
      doAssert (spc.psw and PswC) != 0
      doAssert ((spc.psw and PswZ) != 0) == (expectedCount == 0)
      doAssert ((spc.psw and PswN) != 0) == (expectedCount >= 128)
      inc result

proc checkAdapters(spc: var Spc): int =
  ## Cover every byte and all voices with stream-free setters and pending-field adapters.
  for channel in countup(0, 14, 2):
    for value in 0 .. 255:
      for entry in [0x162E, 0x1632, 0x164A, 0x165F, 0x1663, 0x1666,
                    0x166A, 0x1678, 0x167D, 0x1692, 0x1698]:
        let
          parameter = (value * 73 + 41) and 255
          other = value xor 0xC5
          status = if (value and 1) == 0: 0 else: 0xDF
        spc.prepare(channel, value, status)
        spc.ram[0x20] = parameter.uint8
        spc.ram[0x21] = other.uint8
        let before = spc.ram[]
        var
          changes = initTable[int, int]()
          expectedA = value
          expectedY = spc.y.int
        case entry
        of 0x162E:
          changes[0x58] = 0; changes[0x59] = value
          expectedA = 0; expectedY = value
        of 0x1632:
          changes[0x493] = before[0x53].int
          changes[0x52] = 0; changes[0x53] = value
          expectedA = 0; expectedY = value
        of 0x164A, 0x165F:
          let depth = if entry == 0x164A: other else: 0
          if entry == 0x164A:
            changes[0x2B0 + channel] = value
            changes[0x2A1 + channel] = parameter
          changes[0xB1 + channel] = depth
          changes[0x2C1 + channel] = depth
          changes[0x2B1 + channel] = 0
          expectedA = 0
        of 0x1663: changes[0x50] = value
        of 0x1666: changes[0x2F0 + channel] = value
        of 0x166A:
          changes[0x300 + channel] = 0; changes[0x301 + channel] = value
          expectedA = 0
        of 0x1678, 0x167D:
          changes[0x290 + channel] = ord(entry == 0x1678)
          changes[0x281 + channel] = value
          changes[0x280 + channel] = parameter
          changes[0x291 + channel] = other
          expectedA = other
        of 0x1692:
          changes[0x280 + channel] = 0; expectedA = 0
        of 0x1698:
          changes[0x351 + channel] = value
          changes[0x331 + channel] = value and 31
          changes[0x330 + channel] = 0; expectedA = 0
        else: doAssert false
        doAssert spc.run(entry).len == 0
        spc.guarded(before, changes)
        doAssert spc.a.int == expectedA and spc.x.int == channel and spc.y.int == expectedY
        let expectedStatus = if entry in [0x1663, 0x1666]: status.uint8
          else: (status.uint8 and not (PswN or PswZ)) or
            (if expectedA == 0: PswZ elif expectedA >= 128: PswN else: 0'u8)
        doAssert spc.psw == expectedStatus, &"entry ${entry:04X} flags"
        inc result

proc checkFades(spc: var Spc): int =
  ## Check target/duration domains against host quotients and preservation contracts.
  for duration in 0 .. 255:
    for target in 0 .. 255:
      for entry in [0x166E, 0x169B]:
        let
          channel = ((duration xor target) and 7) * 2
          current = [0, 1, 127, 128, 254, 255][(duration + target) mod 6]
          override = if (duration and 1) == 0: 0 else: 1
          effective = if entry == 0x169B and override != 0: 10 else: target
          step = signedStep(effective - current, duration)
          base = if entry == 0x166E: 0x300 else: 0x330
          stepBase = base + 16
          targetBase = base + 32
          counter = if entry == 0x166E: 0x90 else: 0x91
        spc.prepare(channel, duration, 0xDF)
        spc.ram[0x20] = target.uint8
        spc.ram[0x44] = 0xC4 # The adapter, rather than the fixture, must save X.
        spc.ram[base + 1 + channel] = current.uint8
        spc.ram[0x431] = override.uint8
        let before = spc.ram[]
        var changes = {0x44: channel, counter + channel: duration,
          targetBase + channel: effective, stepBase + channel: step and 255,
          stepBase + 1 + channel: step shr 8}.toTable
        if entry == 0x169B: changes[0x20] = effective
        doAssert spc.run(entry).len == 0
        if effective < current: spc.guarded(before, changes, [0x12, 0x14, 0x15])
        else: spc.guarded(before, changes, [0x12])
        doAssert spc.x.int == channel and spc.a.int == (step shr 8) and spc.y.int == (step shr 8)
        doAssert (spc.psw and (PswI or PswB or PswP)) == (0xDF'u8 and (PswI or PswB or PswP))
        doAssert ((spc.psw and PswN) != 0) == ((step shr 8) >= 128)
        doAssert ((spc.psw and PswZ) != 0) == ((step shr 8) == 0)
        inc result

proc checkRestore(spc: var Spc): int =
  ## Distinguish saved-tempo restoration from the zero-saved disabled-step path.
  for saved in 0 .. 255:
    for target in 0 .. 255:
      let
        channel = (target and 7) * 2
        current = target xor 0xA5
      spc.prepare(channel, target, 0xDF)
      spc.ram[0x493] = saved.uint8
      spc.ram[0x53] = current.uint8
      spc.ram[0x20] = target.uint8
      let before = spc.ram[]
      var changes = initTable[int, int]()
      if saved != 0:
        changes[0x52] = 0; changes[0x53] = saved
      else:
        let step = signedStep(target - current, 0)
        changes[0x54] = 0; changes[0x55] = target
        changes[0x56] = step and 255; changes[0x57] = step shr 8
      doAssert spc.run(0x163B).len == 0
      if saved != 0: spc.guarded(before, changes)
      elif target < current: spc.guarded(before, changes, [0x12, 0x14, 0x15])
      else: spc.guarded(before, changes, [0x12])
      doAssert spc.x.int == channel
      if saved != 0:
        doAssert spc.a == 0 and spc.y.int == saved
        doAssert spc.psw == ((0xDF'u8 and not (PswN or PswZ)) or PswZ)
      else:
        let
          step = signedStep(target - current, 0)
          nzValue = if target < current: step else: channel
        doAssert spc.word(0x56) == step
        doAssert spc.a.int == (step and 255) and spc.y.int == (step shr 8)
        doAssert ((spc.psw and PswZ) != 0) == (nzValue == 0)
        doAssert ((spc.psw and PswN) != 0) ==
          (if target < current: step >= 32768 else: channel >= 128)
      inc result

proc checkRealExpiry(image: seq[uint8]): int =
  ## Preserve real I/O hooks to verify CONTROL effects without mixing samples.
  for count in [0, 1, 2, 255]:
    for initialEnabled in [0, 1, 7]:
      let machine = newApu()
      for index in 0 ..< DriverLength:
        machine.spc.ram[DriverStart + index] = image[DriverMap + DriverStart + index]
      machine.spc.prepare(6, 0xA5, 0xDF)
      machine.spc.ram[0x491] = count.uint8
      for address in [0x1A, 0x46, 0x47, 0x5E]: machine.spc.ram[address] = 0xA5
      machine.portsIn = [1'u8, 2, 3, 4]
      machine.portsOut = [5'u8, 6, 7, 8]
      machine.spc.iplEnabled = true
      for timer in 0 .. 2:
        machine.setTimerSnapshot(timer, TimerSnapshot(
          enabled: (initialEnabled and (1 shl timer)) != 0,
          target: (17 + timer).uint8, internal: 7, counter: 11, accum: 19))
      let hardwareWrite = machine.spc.writeHook
      var writes: seq[PortWrite]
      machine.spc.writeHook = proc(address: uint16, value: uint8): bool =
        writes.add (address, value)
        hardwareWrite(address, value)
      machine.spc.pc = 0x1609
      var instructions = 0
      while machine.spc.pc != ReturnAddress:
        doAssert instructions < 100
        machine.spc.step()
        inc instructions
      doAssert machine.spc.sp == 0xF1
      doAssert machine.portsOut == [5'u8, 6, 7, 8]
      if count == 1:
        doAssert writes == @[(0xF1'u16, 0x31'u8)]
        doAssert machine.portsIn == [0'u8, 0, 0, 0] and not machine.spc.iplEnabled
        doAssert machine.spc.ram[0x1A] == 5
        for address in [0x46, 0x47, 0x5E]: doAssert machine.spc.ram[address] == 0xE5
        for address in 0x4B0 .. 0x4B7: doAssert machine.spc.ram[address] == 0
      else:
        doAssert writes.len == 0
        doAssert machine.portsIn == [1'u8, 2, 3, 4] and machine.spc.iplEnabled
      for timer in 0 .. 2:
        let
          state = machine.getTimerSnapshot(timer)
          wasEnabled = (initialEnabled and (1 shl timer)) != 0
          enabled = if count == 1: timer == 0 else: wasEnabled
          reset = count == 1 and timer == 0 and not wasEnabled
        doAssert state.enabled == enabled and state.target == (17 + timer).uint8
        doAssert state.internal == (if reset: 0'u8 else: 7'u8)
        doAssert state.counter == (if reset: 0'u8 else: 11'u8)
        doAssert state.accum == 19
      inc result

proc tickUntil(spc: var Spc, entry, stop: uint16) =
  ## Run an unchanged bounded tick fragment before any stereo/DSP continuation.
  spc.sp = 0xEF
  spc.pc = entry
  var instructions = 0
  while spc.pc != stop:
    doAssert instructions < 150 and spc.sp >= 0xEB
    spc.step()
    inc instructions
  doAssert spc.sp == 0xEF

proc checkProducedTicks(spc: var Spc): int =
  ## Keep actual adapter-produced parameters through volume/pan and tempo ticks.
  for channel in countup(0, 14, 2):
    for target in [0, 1, 127, 255]:
      for entry in [0x166E, 0x169B]:
        let
          base = if entry == 0x166E: 0x300 else: 0x330
          counter = if entry == 0x166E: 0x90 else: 0x91
          expected = (0x8055 + signedStep(target - 128, 1)) and 65535
        spc.prepare(channel, 1, 0xDF)
        spc.ram[0x20] = target.uint8
        spc.ram[0x431] = 0
        spc.ram[base + channel] = 0x55
        spc.ram[base + 1 + channel] = 128
        spc.ram[0x47] = (1 shl (channel div 2)).uint8
        spc.ram[0x5E] = 0
        spc.ram[0xC1 + channel] = 0
        spc.ram[0x59] = 255
        spc.ram[0x210 + channel] = 255
        doAssert spc.run(entry).len == 0
        let producedStep = spc.word(base + 16 + channel)
        if entry == 0x166E: spc.tickUntil(0x0C40, 0x0C79)
        else: spc.tickUntil(0x0C79, 0x0C86)
        doAssert spc.ram[counter + channel] == 0
        doAssert spc.word(base + channel) == expected # Last tick retains fraction.
        doAssert spc.word(base + 16 + channel) == producedStep
        doAssert spc.ram[base + 32 + channel].int == target
        doAssert spc.ram[0x5E] == spc.ram[0x47]
        if entry == 0x166E:
          let
            scaled = (((255 * 255 div 256) * 255 div 256) * (expected shr 8)) div 256
            gain = scaled * scaled div 256
          doAssert spc.ram[0x321 + channel].int == gain
        inc result
      spc.prepare(channel, target, 0xDF)
      spc.ram[0x53] = 10
      spc.ram[0x54] = 2
      spc.ram[0x55] = 41
      spc.ram[0x56] = 0x80
      spc.ram[0x57] = 1
      doAssert spc.run(0x1632).len == 0
      spc.tickUntil(0x08F6, 0x0905)
      doAssert spc.word(0x52) == ((target * 256 + 0x180) and 65535)
      doAssert spc.ram[0x54] == 1 and spc.ram[0x493] == 10
      doAssert spc.run(0x163B).len == 0
      spc.tickUntil(0x08F6, 0x0905)
      doAssert spc.word(0x52) == 41 * 256 and spc.ram[0x54] == 0
      inc result

proc main() =
  ## Require byte-identical fresh rebuilds and count only completed behavior checks.
  var
    countdowns, adapters, fades, restores, hardware, chains: int
  for image in engineImages("bin/spc_service_control_extract"):
    var spc = newSpc()
    for index in 0 ..< DriverLength:
      spc.ram[DriverStart + index] = image[DriverMap + DriverStart + index]
    countdowns += spc.checkCountdown()
    adapters += spc.checkAdapters()
    fades += spc.checkFades()
    restores += spc.checkRestore()
    hardware += checkRealExpiry(image)
    chains += spc.checkProducedTicks()
  echo &"SPC service control passed: {countdowns} countdown/mask cases, " &
    &"{adapters} parameter adapters, {fades} fades, {restores} tempo restores, " &
    &"{hardware} real APU expiry contexts, {chains} adapter-to-tick chains " &
    "across original/rebuilt images."

when isMainModule:
  main()
