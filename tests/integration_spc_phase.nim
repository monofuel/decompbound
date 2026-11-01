import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  StartupEnd = 0x050C'u16
  PhaseEntry = 0x05CD'u16
  UpdateEntry = 0x05D8'u16
  PreviewEntry = 0x05E0'u16
  ClearEnd = 0xE0
  PhaseByte = 0x51
  TempoByte = 0x53
  GuardByte = 0xA5'u8

proc checkStartup(spc: var Spc, seed: int) =
  ## Prove the bootstrap establishes its zero word even from dirty page-one entry.
  for address in 0 ..< 512:
    spc.ram[address] = seed.uint8
  spc.pc = DriverStart.uint16
  spc.sp = 0x47
  spc.a = 0x91
  spc.x = 0x39
  spc.y = 0x67
  spc.psw = seed.uint8
  var steps = 0
  while spc.pc != StartupEnd:
    doAssert steps < 700
    spc.step()
    inc steps
  doAssert steps == 677
  for address in 0 ..< ClearEnd:
    doAssert spc.ram[address] == 0
  for address in ClearEnd ..< 512:
    doAssert spc.ram[address] == seed.uint8
  doAssert spc.a == 0 and spc.x == ClearEnd.uint8 and spc.y == 0x67
  doAssert spc.sp == 0xCF
  let expectedStatus = (seed.uint8 and not (PswP or PswN or PswZ or PswC)) or PswZ or PswC
  doAssert spc.psw == expectedStatus

proc checkPhase(spc: var Spc, timerCount, tempo, oldPhase: int,
    stackPointer = 0xAF) =
  ## Predict the low-product accumulator and its exact update/preview branch.
  let
    product = timerCount * tempo
    increment = product and 255
    sum = oldPhase + increment
    phase = sum and 255
    carry = sum > 255
    poppedStack = (stackPointer + 1) and 255
    stackByte = 0x100 + poppedStack
    beforeStack = 0x100 + stackPointer
    afterStack = 0x100 + ((stackPointer + 2) and 255)
    initialStatus = PswI or PswB or PswC or PswN or PswV or PswH or PswZ
  spc.ram[PhaseByte - 1] = GuardByte
  spc.ram[PhaseByte] = oldPhase.uint8
  spc.ram[PhaseByte + 1] = GuardByte
  spc.ram[TempoByte] = tempo.uint8
  spc.ram[TempoByte + 1] = GuardByte
  spc.ram[beforeStack] = GuardByte
  spc.ram[stackByte] = timerCount.uint8
  spc.ram[afterStack] = GuardByte
  spc.pc = PhaseEntry
  spc.sp = stackPointer.uint8
  spc.x = 0xC7
  spc.a = 0x3B
  spc.y = 0xDA
  spc.psw = initialStatus
  var steps = 0
  while spc.pc notin [UpdateEntry, PreviewEntry]:
    doAssert steps < 7
    spc.step()
    inc steps
  doAssert steps == 7
  doAssert spc.pc == (if carry: UpdateEntry else: PreviewEntry)
  doAssert spc.a.int == phase and spc.ram[PhaseByte].int == phase
  doAssert spc.y.int == product shr 8 and spc.x == 0xC7 and spc.sp.int == poppedStack
  doAssert spc.ram[TempoByte].int == tempo
  doAssert spc.ram[PhaseByte - 1] == GuardByte and spc.ram[PhaseByte + 1] == GuardByte
  doAssert spc.ram[TempoByte + 1] == GuardByte
  doAssert spc.ram[stackByte].int == timerCount
  doAssert spc.ram[beforeStack] == GuardByte and spc.ram[afterStack] == GuardByte
  doAssert (spc.psw and (PswI or PswB or PswP)) == (initialStatus and (PswI or PswB or PswP))
  doAssert ((spc.psw and PswC) != 0) == carry
  doAssert ((spc.psw and PswH) != 0) == ((oldPhase and 15) + (increment and 15) > 15)
  doAssert ((spc.psw and PswV) != 0) ==
    (((not (oldPhase xor increment)) and (oldPhase xor phase) and 128) != 0)
  doAssert ((spc.psw and PswN) != 0) == (phase >= 128)
  doAssert ((spc.psw and PswZ) != 0) == (phase == 0)

proc checkImage(image: seq[uint8]): tuple[startup, timerCounts, wideCounts, stacks: int] =
  ## Execute original code with dirty bootstrap state and synthetic timer operands.
  var spc = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[address + DriverMap]
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, &"phase/startup check unexpectedly wrote I/O ${address:04X}=${value:02X}"
    false
  for seed in 0 .. 255:
    spc.checkStartup(seed)
    inc result.startup
  # Hardware timer counters are four bits. Zero is a synthetic entry edge case;
  # the polling caller normally waits for a nonzero count before pushing it.
  for count in 0 .. 15:
    for tempo in 0 .. 255:
      for phase in 0 .. 255:
        spc.checkPhase(count, tempo, phase)
        inc result.timerCounts
  # Larger authored counts distinguish low-product carry from full-product carry.
  for count in [16, 31, 127, 128, 254, 255]:
    for tempo in [0, 1, 16, 127, 128, 254, 255]:
      for phase in [0, 1, 127, 128, 254, 255]:
        spc.checkPhase(count, tempo, phase)
        inc result.wideCounts
  for stackPointer in 0 .. 255:
    for count in [0, 15]:
      for tempo in [0, 255]:
        for phase in [0, 255]:
          spc.checkPhase(count, tempo, phase, stackPointer)
          inc result.stacks

proc main() =
  ## Verify original and freshly rebuilt startup/phase fragments without audio output.
  var total = 0
  for index, image in engineImages("bin/spc_phase_extract"):
    let
      counts = checkImage(image)
      name = if index == 0: "original" else: "rebuilt"
    total += counts.startup + counts.timerCounts + counts.wideCounts + counts.stacks
    echo &"{name}: {counts.startup} dirty startup, {counts.timerCounts} timer-count/tempo/phase, {counts.wideCounts} wide-count and {counts.stacks} stack cases passed"
  echo &"SPC startup/phase: {total} executed cases across both images"

when isMainModule:
  main()
