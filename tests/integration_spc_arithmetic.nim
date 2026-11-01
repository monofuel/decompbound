## Independent arithmetic checks for original APU $0BC7..$0BE2 and $0E2B..$0E48.
## Contracts come from the user's ROM and the existing core, not authored SPC
## assembly. These calls operate on synthetic RAM and never reach the DSP.

import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  DivideEntry = 0x0BC7'u16
  PhaseEntry = 0x0E2B'u16
  ReturnAddress = 0x1E00'u16
  StackPointer = 0xEF'u8
  StepLimit = 64
  Phases = [0, 1, 2, 127, 128, 254, 255]
  GuardByte = 0xA5'u8
  PreservedStatus = PswI or PswB or PswP
  BoundarySteps = [0, 1, 255, 256, 257, 32767, 32768, 32769, 65280, 65535]
  BoundaryBases = [0, 1, 32767, 32768, 65535]

proc word(spc: Spc, address: int): int =
  ## Read a little-endian RAM word without using the emulated arithmetic.
  spc.ram[address].int or (spc.ram[address + 1].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Set an authored RAM word modulo sixteen bits.
  spc.ram[address] = uint8(value and 255)
  spc.ram[address + 1] = uint8((value shr 8) and 255)

proc execute(spc: var Spc, entry: uint16) =
  ## Execute a bounded math call, preserving return bytes and stack guards.
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1ED] = GuardByte
  spc.ram[0x1F2] = GuardByte
  spc.sp = StackPointer
  spc.pc = entry
  var steps = 0
  while spc.pc != ReturnAddress:
    doAssert steps < StepLimit, &"helper ${entry:04X} exceeded its step budget"
    doAssert spc.sp >= 0xED and spc.sp <= 0xF1,
      &"helper ${entry:04X} escaped its two-byte internal stack allowance"
    spc.step()
    inc steps
  doAssert spc.sp == 0xF1
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1ED] == GuardByte and spc.ram[0x1F2] == GuardByte
  doAssert not spc.stopped

proc expectedQuotient(magnitude, duration: int): int =
  ## Specify unsigned 8.8 division, including the observed SPC zero-divisor law.
  if duration == 0:
    65535 - magnitude
  else:
    magnitude * 256 div duration

proc checkDivide(spc: var Spc, magnitude, duration: int, negative: bool,
    subtractionBase = 0, restoredX = 0xA6, seed = 0x55) =
  ## Check arithmetic, sign storage, DP scratch and status of the original division helper.
  let
    quotient = expectedQuotient(magnitude, duration)
    expected = (if negative: subtractionBase - quotient else: quotient) and 65535
    initialStatus = (if (magnitude xor duration) mod 2 == 0: PswI else: PswB) or
      PswN or PswZ or PswH or PswV or (if negative: 0'u8 else: PswC)
  # Negative results are base-minus-quotient; mathematical negation needs base zero.
  spc.putWord(0x0E, subtractionBase)
  spc.putWord(0x10, 0xB47D)
  spc.putWord(0x14, 0x6AC3)
  spc.ram[0x12] = seed.uint8
  spc.ram[0x13] = 0x35
  spc.ram[0x44] = restoredX.uint8 # Saved caller X, independently of divisor X.
  let before = spc.ram[0 .. 0xEF]
  spc.a = uint8((if negative: -magnitude else: magnitude) and 255)
  spc.y = 0xC7
  spc.x = duration.uint8
  spc.psw = initialStatus
  spc.execute(DivideEntry)
  doAssert spc.a.int + 256 * spc.y.int == expected,
    $[magnitude, duration, negative.int, subtractionBase, expected, spc.a.int, spc.y.int]
  doAssert spc.x.int == restoredX
  doAssert spc.word(0x0E) == subtractionBase
  doAssert spc.word(0x10) == 0xB47D
  doAssert spc.ram[0x12].int == ((seed shr 1) or (if negative: 128 else: 0))
  doAssert spc.word(0x14) == (if negative: quotient else: 0x6AC3)
  for address in 0 .. 0xEF:
    if address notin [0x12, 0x14, 0x15]:
      doAssert spc.ram[address] == before[address], &"division changed DP ${address:02X}"
  doAssert (spc.psw and PreservedStatus) == (initialStatus and PreservedStatus)
  if negative:
    # SUBW reports subtraction flags for the explicit base-minus-quotient result.
    doAssert ((spc.psw and PswC) != 0) == (subtractionBase >= quotient)
    doAssert ((spc.psw and PswH) != 0) ==
      ((subtractionBase and 4095) >= (quotient and 4095))
    doAssert ((spc.psw and PswV) != 0) ==
      (((subtractionBase xor quotient) and (subtractionBase xor expected) and 32768) != 0)
    doAssert ((spc.psw and PswN) != 0) == (expected >= 32768)
    doAssert ((spc.psw and PswZ) != 0) == (expected == 0)
  else:
    # Restoring X sets N/Z, while carry still comes from the old DP $12 bit 0.
    doAssert ((spc.psw and PswC) != 0) == ((seed and 1) != 0)
    doAssert ((spc.psw and PswN) != 0) == (restoredX >= 128)
    doAssert ((spc.psw and PswZ) != 0) == (restoredX == 0)
    doAssert ((spc.psw and PswV) != 0) == (duration == 0)
    doAssert ((spc.psw and PswH) != 0) ==
      (duration == 0 or (duration and 15) <= ((magnitude mod duration) and 15))

proc expectedOffset(rawStep, phase: int): int =
  ## Scale a signed sixteen-bit step toward zero, without intermediate byte arithmetic.
  let
    signedStep = if rawStep < 32768: rawStep else: rawStep - 65536
    magnitude = abs(signedStep) * phase div 256
  if signedStep < 0: -magnitude else: magnitude

proc checkPhase(spc: var Spc, rawStep, phase: int, base = 0, seed = 0x35) =
  ## Check full signed phase scaling, accumulation, preserved inputs and final ADDW status.
  let
    offset = expectedOffset(rawStep, phase)
    offsetWord = offset and 65535
    expected = (base + offset) and 65535
    initialStatus = (if (rawStep xor phase) mod 2 == 0: PswI else: PswB) or
      PswN or PswZ or PswH or PswV or PswC
  spc.putWord(0x0E, 0)      # Both shared sign-adjustment calls require this zero base.
  spc.putWord(0x10, base)
  spc.ram[0x12] = 0xA6
  spc.ram[0x13] = seed.uint8
  spc.putWord(0x14, 0xC35A)
  spc.ram[0x44] = 0xE1
  spc.ram[0x51] = phase.uint8
  let before = spc.ram[0 .. 0xEF]
  spc.a = uint8(rawStep and 255)
  spc.y = uint8(rawStep shr 8)
  spc.x = 0xA6
  spc.psw = initialStatus
  spc.execute(PhaseEntry)
  doAssert spc.word(0x10) == expected and spc.a.int + 256 * spc.y.int == expected,
    $[rawStep, phase, base, offset, expected, spc.word(0x10)]
  doAssert spc.x == 0xA6
  doAssert spc.word(0x0E) == 0
  doAssert spc.ram[0x12].int == (rawStep shr 8)
  doAssert spc.ram[0x13].int == (seed or 128)
  doAssert spc.ram[0x51].int == phase
  for address in 0 .. 0xEF:
    if address notin [0x10, 0x11, 0x12, 0x13, 0x14, 0x15]:
      doAssert spc.ram[address] == before[address], &"phase scaling changed DP ${address:02X}"
  doAssert (spc.psw and PreservedStatus) == (initialStatus and PreservedStatus)
  doAssert ((spc.psw and PswC) != 0) == (base + offsetWord > 65535)
  doAssert ((spc.psw and PswH) != 0) ==
    ((base and 4095) + (offsetWord and 4095) > 4095)
  doAssert ((spc.psw and PswV) != 0) ==
    (((not (base xor offsetWord)) and (base xor expected) and 32768) != 0)
  doAssert ((spc.psw and PswN) != 0) == (expected >= 32768)
  doAssert ((spc.psw and PswZ) != 0) == (expected == 0)

proc checkImage(image: seq[uint8]): tuple[division, subtractionBases, phases,
    accumulations: int] =
  ## Exercise original driver code with synthetic arithmetic inputs and no DSP access.
  var spc = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[DriverMap + address]
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, &"math helper unexpectedly wrote I/O ${address:04X}=${value:02X}"
    false
  for magnitude in 0 .. 255:
    for duration in 0 .. 255:
      for negative in [false, true]:
        spc.checkDivide(magnitude, duration, negative,
          seed = (if (magnitude xor duration) mod 2 == 0: 0x2A else: 0x55))
        inc result.division
  for magnitude in [0, 1, 127, 128, 254, 255]:
    for duration in [0, 1, 2, 3, 127, 128, 254, 255]:
      for negative in [false, true]:
        for base in BoundaryBases:
          for restoredX in [0, 1, 14, 127, 128, 255]:
            for seed in [0, 1, 0x7E, 0xFF]:
              spc.checkDivide(magnitude, duration, negative, base, restoredX, seed)
              inc result.subtractionBases
  for rawStep in 0 .. 65535:
    for phase in Phases:
      spc.checkPhase(rawStep, phase)
      inc result.phases
  for rawStep in BoundarySteps:
    for phase in Phases:
      for base in BoundaryBases:
        for seed in [0, 127, 128, 255]:
          spc.checkPhase(rawStep, phase, base, seed)
          inc result.accumulations

proc main() =
  ## Verify both freshly loaded ROM images against independent signed arithmetic laws.
  var total = 0
  for index, image in engineImages("bin/spc_arithmetic_extract"):
    let
      counts = checkImage(image)
      cases = counts.division + counts.subtractionBases + counts.phases + counts.accumulations
      name = if index == 0: "original" else: "rebuilt"
    total += cases
    echo &"{name}: {counts.division} division, {counts.subtractionBases} subtraction-base/status, {counts.phases} signed-phase and {counts.accumulations} accumulation cases passed"
  echo &"SPC arithmetic: {total} executed cases across both images"

when isMainModule:
  main()
