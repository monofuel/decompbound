import
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverTarget = 0x0500
  DriverLength = 16779
  ConsumerEntry = 0x0C8C'u16
  ReturnAddress = 0x1E00'u16
  CurveBase = 0x0E73
  PositionLimit = 20
  FractionScale = 256

proc coefficient(position: int, curve: seq[int] = @[]): int =
  ## Interpolate either a local ROM curve or an authored curve using integer truncation.
  let
    index = position div FractionScale
    fraction = position mod FractionScale
    lower = if curve.len == 0: index * index div 2 else: curve[index]
    upper = if curve.len == 0: (index + 1) * (index + 1) div 2 else: curve[index + 1]
  lower + ((upper - lower) * fraction div FractionScale)

proc checkConsumer(spc: var Spc, voice, position, flags, volume: int,
    blocked: bool, seedFields = true, callerMask = -1, inhibitMask = -1,
    curve: seq[int] = @[]) =
  ## Execute both original volume writes against independent fixed-point arithmetic.
  let
    channel = voice * 2
    mask = if callerMask < 0: 1 shl voice else: callerMask
  var writes: seq[(uint16, uint8)]
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    writes.add (address, value)
    false
  if seedFields:
    spc.ram[0x330 + channel] = (position mod FractionScale).uint8
    spc.ram[0x331 + channel] = (position div FractionScale).uint8
    spc.ram[0x351 + channel] = flags.uint8
  spc.ram[0x321 + channel] = volume.uint8
  spc.ram[0x47] = mask.uint8
  spc.ram[0x1A] = (if inhibitMask >= 0: inhibitMask elif blocked: mask else: 0).uint8
  spc.ram[0x1F0] = (ReturnAddress and 255).uint8
  spc.ram[0x1F1] = (ReturnAddress shr 8).uint8
  spc.pc = ConsumerEntry
  spc.sp = 0xEF
  spc.x = channel.uint8
  spc.psw = 0
  var steps = 0
  while spc.pc != ReturnAddress:
    doAssert steps < 100
    spc.step()
    inc steps
  doAssert spc.x.int == channel and spc.sp == 0xF1
  doAssert spc.ram[0x10].int + spc.ram[0x11].int * FractionScale == position
  doAssert spc.ram[0x12].int == voice * 16 + 2
  doAssert spc.ram[0x330 + channel].int == position mod FractionScale
  doAssert spc.ram[0x331 + channel].int == position div FractionScale
  doAssert spc.ram[0x351 + channel].int == flags
  var expected: seq[(uint16, uint8)]
  if not blocked:
    for side in 0 .. 1:
      let
        sidePosition = if side == 0: position else: PositionLimit * FractionScale - position
        magnitude = coefficient(sidePosition, curve) * volume div FractionScale
        negative = (flags and (if side == 0: 128 else: 64)) != 0
        value = (if negative: (-magnitude) and 255 else: magnitude).uint8
      expected.add (0xF2'u16, (voice * 16 + side).uint8)
      expected.add (0xF3'u16, value)
  doAssert writes == expected
  spc.writeHook = nil

proc checkCommandConsumer(spc: var Spc, voice, operand, overrideFlag,
    volume, target: int) =
  ## Execute E1 through the dispatcher before checking its actual stereo DSP output.
  let
    channel = voice * 2
    effective = if overrideFlag == 0: operand else: 10
  spc.ram[0x30 + channel] = (target and 255).uint8
  spc.ram[0x31 + channel] = (target shr 8).uint8
  spc.ram[target] = operand.uint8
  spc.ram[0x431] = overrideFlag.uint8
  spc.ram[0x1F0] = (ReturnAddress and 255).uint8
  spc.ram[0x1F1] = (ReturnAddress shr 8).uint8
  spc.pc = 0x0943
  spc.sp = 0xEF
  spc.x = channel.uint8
  spc.a = 0xE1
  spc.psw = 0
  var steps = 0
  while spc.pc != ReturnAddress:
    doAssert steps < 40
    spc.step()
    inc steps
  doAssert spc.ram[0x30 + channel].int + spc.ram[0x31 + channel].int * 256 ==
    ((target + 1) and 0xFFFF)
  doAssert spc.ram[0x20].int == operand
  spc.checkConsumer(voice, (effective and 31) * FractionScale, effective,
    volume, false, false)

proc main() =
  ## Verify original/rebuilt driver output against an authored nonlinear pan curve, silently.
  var
    checks = 0
    commandChecks = 0
  for image in engineImages("bin/spc_pan_extract"):
    var spc = newSpc()
    for address in DriverTarget ..< DriverTarget + DriverLength:
      spc.ram[address] = image[address + DriverMap]
    doAssert spc.ram[CurveBase] == 0 and spc.ram[CurveBase + 20] == 127
    for index in 0 ..< PositionLimit:
      doAssert spc.ram[CurveBase + index] <= spc.ram[CurveBase + index + 1]
    var originalCurve: seq[int]
    for index in 0 .. 21:
      originalCurve.add spc.ram[CurveBase + index].int
    for voice in 0 ..< 8:
      for integer in [0, 1, 10, 19, 20]:
        for fraction in [0, 1, 127, 255]:
          if integer == PositionLimit and fraction != 0:
            continue
          for flags in [0, 64, 128, 192]:
            for volume in [0, 1, 127, 255]:
              spc.checkConsumer(voice, integer * FractionScale + fraction,
                flags, volume, false, curve = originalCurve)
              inc checks
    for index in 0 .. 21:
      spc.ram[CurveBase + index] = (index * index div 2).uint8
    for voice in 0 ..< 8:
      for integer in 0 .. PositionLimit:
        for fraction in [0, 1, 127, 255]:
          if integer == PositionLimit and fraction != 0:
            continue
          for flags in 0 .. 255:
            for volume in [0, 1, 127, 255]:
              for blocked in [false, true]:
                spc.checkConsumer(voice, integer * FractionScale + fraction,
                  flags, volume, blocked)
                inc checks
      for operand in 0 .. 255:
        for overrideFlag in [0, 1, 128, 255]:
          if overrideFlag == 0 and (operand and 31) > PositionLimit:
            continue
          for volume in [0, 127, 255]:
            for target in [0x48FF, 0xFFFF]:
              spc.checkCommandConsumer(voice, operand, overrideFlag, volume, target)
              inc commandChecks
    for voice in [0, 7]:
      for mask in [0, 1, 128, 255]:
        for inhibit in [0, 1, 128, 255]:
          spc.checkConsumer(voice, PositionLimit * FractionScale div 2, 0xC0, 255,
            (mask and inhibit) != 0, callerMask = mask, inhibitMask = inhibit)
          inc checks
  echo "SPC pan: ", checks, " consumer cases and ", commandChecks,
    " E1-to-DSP cases passed on original/rebuilt ROMs."

when isMainModule:
  main()
