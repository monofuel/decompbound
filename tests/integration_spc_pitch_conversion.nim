## Verify the original pitch-table arithmetic with authored curves and integer mathematics.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  PortWrite = tuple[address: uint16, value: uint8]
  Expected = object
    position, pitch, interpolation: int
    halfCarry, overflow: bool

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  ConversionEntry = 0x06BE'u16
  InterpolationEntry = 0x06D4'u16
  ScaleEntry = 0x070E'u16
  ReturnAddress = 0x1E00'u16
  CurveAddress = 0x0EBC
  Guard = 0xA5'u8
  BoundaryPositions = [0, 1, 255, 256, 0x12FF, 0x1300, 0x33FF, 0x3400,
    0x47FF, 0x4800, 0x53FF, 0x5400, 0x7FFF, 0x8000, 0xFFFF]
  Factors = [0, 1, 255, 256, 257, 32768, 65535]
  Curves = [
    [123, 160, 197, 234, 271, 308, 345, 382, 419, 456, 493, 530, 567],
    [0, 65535, 0, 256, 32769, 255, 65280, 32768, 1, 32767, 0, 61441, 43981],
    [65535, 62162, 58789, 55416, 52043, 48670, 45297, 41924, 38551, 35178,
      31805, 28432, 25059],
    [65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535,
      65535, 65535, 65535]]

proc word(spc: Spc, address: int): int =
  ## Read a little-endian word from the synthetic machine state.
  spc.ram[address].int + spc.ram[address + 1].int * 256

proc putWord(spc: var Spc, address, value: int) =
  ## Install a word without depending on SPC arithmetic or assembler code.
  spc.ram[address] = (value and 255).uint8
  spc.ram[address + 1] = ((value shr 8) and 255).uint8

proc expectedConversion(position: int, curve: array[13, int], compensate: bool): Expected =
  ## Express byte-wrapping adjustment, table interpolation and shift limits mathematically.
  let integer = position div 256
  let adjustment = if integer < 19: -2 * (19 - integer)
    elif integer >= 52: integer - 52 else: 0
  result.position = (position + (if compensate: adjustment else: 0)) and 65535
  let
    doubledInteger = (2 * (result.position div 256)) mod 256
    quotient = doubledInteger div 24
    segment = (doubledInteger mod 24) div 2
    base = curve[segment]
    # Only the low byte of the word difference participates in MUL.
    difference = (curve[segment + 1] - base) and 255
    fraction = result.position mod 256
  let increment = difference * fraction div 256
  result.interpolation = (base + increment) and 65535
  result.halfCarry = (base and 4095) + increment > 4095
  result.overflow = ((not (base xor increment)) and
    (base xor result.interpolation) and 32768) != 0
  let doubled = (2 * result.interpolation) and 65535
  # The native loop increments an eight-bit quotient until six, even above six.
  # Those 252..255 right shifts always erase the sixteen-bit result.
  result.pitch = if quotient > 6: 0 else: doubled div (1 shl (6 - quotient))

proc checkConversion(spc: var Spc, position, curveIndex, channel, status, factor: int,
    chain, blocked: bool, entry: uint16) =
  ## Run unpatched conversion alone or its actual scaling/guarded-port continuation.
  let expected = expectedConversion(position, Curves[curveIndex], entry == ConversionEntry)
  for address in 0 .. 0xEF:
    spc.ram[address] = ((address * 37 + 11) and 255).uint8
  for address in 0x200 .. 0x3AF:
    spc.ram[address] = Guard
  for index, value in Curves[curveIndex]:
    spc.putWord(CurveAddress + index * 2, value)
  spc.putWord(0x10, position)
  spc.putWord(0x14, 0x5AA5)
  spc.putWord(0x220 + channel, factor)
  spc.ram[0x47] = (1 shl (channel div 2)).uint8
  spc.ram[0x1A] = (if blocked: spc.ram[0x47] else: 0)
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1EC] = Guard
  spc.ram[0x1F2] = Guard
  let
    beforeDp = spc.ram[0 .. 0xEF]
    beforeArrays = spc.ram[0x200 .. 0x3AF]
    beforeCurve = spc.ram[CurveAddress .. CurveAddress + 25]
  var
    writes: seq[PortWrite]
    reads = 0
    steps = 0
  spc.readHook = proc(address: uint16): int =
    inc reads
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    writes.add (address, value)
    false
  spc.pc = entry
  spc.sp = 0xEF
  spc.a = 0xA6
  spc.y = 0xC3
  spc.x = channel.uint8
  spc.psw = status.uint8
  let
    stop = if chain: ReturnAddress else: ScaleEntry
    # The DSP helper adds PUSH A below its two-byte native CALL frame.
    deepestStack = if chain: 0xEC'u8 else: 0xED'u8
  while spc.pc != stop:
    doAssert steps < 1600, &"conversion stalled at ${spc.pc:04X} for ${position:04X}"
    doAssert spc.sp in deepestStack .. 0xF1'u8
    spc.step()
    inc steps
  doAssert not spc.stopped and reads == 0
  doAssert spc.x.int == channel and spc.sp == (if chain: 0xF1 else: 0xEF)
  doAssert spc.word(0x10) == expected.position
  doAssert spc.word(0x14) == expected.pitch
  doAssert (spc.psw and (PswP or PswI or PswB)).int ==
    (status and (PswP or PswI or PswB).int)
  if chain:
    let scaled = ((expected.pitch.uint32 * factor.uint32) shr 8).int and 65535
    doAssert spc.word(0x16) == scaled
    if blocked:
      doAssert writes.len == 0
    else:
      doAssert writes == @[(0xF2'u16, (channel * 8 + 2).uint8),
        (0xF3'u16, (scaled and 255).uint8),
        (0xF2'u16, (channel * 8 + 3).uint8),
        (0xF3'u16, (scaled shr 8).uint8)]
  else:
    doAssert writes.len == 0
    doAssert spc.a.int == (expected.pitch and 255)
    doAssert spc.y.int == (expected.interpolation shr 8)
    doAssert (spc.psw and (PswC or PswN or PswZ)) == (PswC or PswZ)
    doAssert ((spc.psw and PswH) != 0) == expected.halfCarry
    doAssert ((spc.psw and PswV) != 0) == expected.overflow
  for address in 0 .. 0xEF:
    let changed = address in [0x10, 0x11, 0x14, 0x15] or
      (chain and address in [0x16, 0x17])
    if not changed:
      doAssert spc.ram[address] == beforeDp[address], &"conversion changed DP ${address:02X}"
  doAssert spc.ram[0x200 .. 0x3AF] == beforeArrays
  doAssert spc.ram[CurveAddress .. CurveAddress + 25] == beforeCurve
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1EC] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil

proc main() =
  ## Verify complete position domains plus original conversion-to-DSP interactions on both images.
  var directCases, chainedCases = 0
  for image in engineImages("bin/spc_pitch_conversion_extract"):
    var spc = newSpc()
    for index in 0 ..< DriverLength:
      spc.ram[DriverStart + index] = image[DriverPayload + index]
    for entry in [ConversionEntry, InterpolationEntry]:
      for curveIndex in 0 ..< Curves.len:
        for position in 0 .. 65535:
          let
            channel = 2 * ((position + curveIndex) and 7)
            status = [0, PswI.int or PswB.int, PswC.int or PswH.int or PswV.int][position mod 3]
          spc.checkConversion(position, curveIndex, channel, status, 256, false, false, entry)
          inc directCases
      for curveIndex in 0 ..< Curves.len:
        for position in BoundaryPositions:
          for channel in countup(0, 14, 2):
            for factor in Factors:
              for blocked in [false, true]:
                spc.checkConversion(position, curveIndex, channel,
                  PswI.int or PswB.int or PswV.int or PswH.int, factor, true, blocked, entry)
                inc chainedCases
  echo &"SPC pitch conversion passed: {directCases} direct entries and {chainedCases} conversion-to-DSP chains across original/rebuilt images."

when isMainModule:
  main()
