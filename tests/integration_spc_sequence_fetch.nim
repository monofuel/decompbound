import
  decompbound/[rom_pipeline, spc700]

const
  DriverPayload = 0x260042
  DriverTarget = 0x0500
  DriverLength = 16779
  FetchEntry = 0x0955'u16
  ReturnAddress = 0x1E00'u16
  StreamTargets = [0x4800, 0x48FF, 0x4FFF, 0xFFFE, 0xFFFF]

proc checkFetch(spc: var Spc, voice, page, carry, target, value: int) =
  ## Execute the ROM's advancing fetch helper with synthetic sequence and return bytes.
  let pointer = page + 0x30 + voice * 2
  spc.ram[pointer] = (target and 255).uint8
  spc.ram[pointer + 1] = (target shr 8).uint8
  spc.ram[target] = value.uint8
  spc.ram[0x1F0] = (ReturnAddress and 255).uint8
  spc.ram[0x1F1] = (ReturnAddress shr 8).uint8
  spc.pc = FetchEntry
  spc.sp = 0xEF
  spc.x = (voice * 2).uint8
  spc.y = 0xA5
  spc.a = 0x5A
  spc.psw = PswH or PswV or carry.uint8 or (if page == 0: 0'u8 else: PswP)
  let preserved = spc.psw
  var steps = 0
  while spc.pc != ReturnAddress:
    doAssert steps < 10
    spc.step()
    inc steps
  let next = (target + 1) and 0xFFFF
  doAssert spc.ram[pointer].int + (spc.ram[pointer + 1].int shl 8) == next
  doAssert spc.a == value.uint8 and spc.y == value.uint8
  doAssert spc.x == (voice * 2).uint8 and spc.sp == 0xF1
  doAssert (spc.psw and not (PswN or PswZ)) == preserved
  doAssert ((spc.psw and PswN) != 0) == (value >= 128)
  doAssert ((spc.psw and PswZ) != 0) == (value == 0)

proc checkDispatch(spc: var Spc, rom: seq[uint8], voice, command, target, operand: int) =
  ## Verify command-table dispatch and optional first-operand fetch without executing the handler.
  let
    pointer = 0x30 + voice * 2
    entry = DriverPayload - DriverTarget + 0x0B23 + ((command * 2) and 255)
    handler = rom[entry].int or (rom[entry + 1].int shl 8)
    hasOperand = rom[DriverPayload - DriverTarget + 0x0BC1 + (command and 127)] != 0
  spc.ram[pointer] = (target and 255).uint8
  spc.ram[pointer + 1] = (target shr 8).uint8
  spc.ram[target] = operand.uint8
  spc.pc = 0x0943
  spc.sp = 0xEF
  spc.x = (voice * 2).uint8
  spc.a = command.uint8
  spc.y = 0
  spc.psw = 0
  var
    steps = 0
    returned = false
  while not returned:
    doAssert steps < 25
    returned = spc.pc == 0x095E
    spc.step()
    inc steps
  doAssert spc.pc.int == handler and spc.sp == 0xEF
  doAssert spc.x == (voice * 2).uint8
  doAssert spc.ram[pointer].int + (spc.ram[pointer + 1].int shl 8) ==
    ((target + (if hasOperand: 1 else: 0)) and 65535)
  doAssert spc.a.int == (if hasOperand: operand else: 0)
  doAssert spc.y.int == (if hasOperand: operand else: 0)

proc checkCommandE1(spc: var Spc, voice, operand, overrideFlag, target: int) =
  ## Execute command E1 through dispatch and verify its channel fields and single operand.
  let
    channel = voice * 2
    pointer = 0x30 + channel
    effective = (if overrideFlag == 0: operand else: 10)
  for index in 0 ..< 16:
    spc.ram[0x330 + index] = 0xA5
    spc.ram[0x350 + index] = 0x5A
  spc.ram[0x431] = overrideFlag.uint8
  spc.ram[pointer] = (target and 255).uint8
  spc.ram[pointer + 1] = (target shr 8).uint8
  spc.ram[target] = operand.uint8
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
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.ram[pointer].int + (spc.ram[pointer + 1].int shl 8) == ((target + 1) and 65535)
  doAssert spc.ram[0x20].int == operand
  doAssert spc.ram[0x431].int == overrideFlag
  for index in 0 ..< 16:
    doAssert spc.ram[0x330 + index].int ==
      (if index == channel: 0 elif index == channel + 1: effective and 31 else: 0xA5)
    doAssert spc.ram[0x350 + index].int ==
      (if index == channel + 1: effective else: 0x5A)

proc main() =
  ## Sweep stream bytes, voice offsets, both direct pages, carry, and pointer boundaries.
  let rom = readGoldBaserom()
  var spc = newSpc()
  doAssert rom[DriverPayload - 4].int + (rom[DriverPayload - 3].int shl 8) == DriverLength
  doAssert rom[DriverPayload - 2].int + (rom[DriverPayload - 1].int shl 8) == DriverTarget
  for index in 0 ..< DriverLength:
    spc.ram[DriverTarget + index] = rom[DriverPayload + index]
  for voice in 0 ..< 8:
    for page in [0, 256]:
      for carry in 0 .. 1:
        for target in StreamTargets:
          for value in 0 .. 255:
            spc.checkFetch(voice, page, carry, target, value)
  for voice in 0 ..< 8:
    for command in 0xE0 .. 0xFF:
      for target in [0x48FF, 0xFFFF]:
        for operand in [0, 1, 127, 128, 255]:
          spc.checkDispatch(rom, voice, command, target, operand)
  for voice in 0 ..< 8:
    for operand in 0 .. 255:
      for overrideFlag in [0, 1, 128, 255]:
        for target in [0x48FF, 0xFFFF]:
          spc.checkCommandE1(voice, operand, overrideFlag, target)

when isMainModule:
  main()
