import
  decompbound/[rom_pipeline, spc700]

const
  DriverPayload = 0x260042
  DriverTarget = 0x0500
  DriverLength = 16779
  ScaleEntry = 0x070E'u16
  ReturnAddress = 0x1E00'u16
  BoundaryWords = [0, 1, 127, 128, 255, 256, 257, 32767, 32768, 65280, 65534, 65535]

proc checkScale(spc: var Spc, voice, pitch, factor: int, blocked: bool) =
  ## Compare original driver multiplication and pitch-port writes with fixed-point arithmetic.
  let
    channel = voice * 2
    expected = ((pitch.uint32 * factor.uint32) shr 8) and 65535
    mask = 1 shl voice
  var writes: seq[(uint16, uint8)]
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    writes.add (address, value)
    false
  spc.ram[0x14] = (pitch and 255).uint8
  spc.ram[0x15] = (pitch shr 8).uint8
  spc.ram[0x220 + channel] = (factor and 255).uint8
  spc.ram[0x221 + channel] = (factor shr 8).uint8
  spc.ram[0x47] = mask.uint8
  spc.ram[0x1A] = (if blocked: mask else: 0).uint8
  spc.ram[0x1F0] = (ReturnAddress and 255).uint8
  spc.ram[0x1F1] = (ReturnAddress shr 8).uint8
  spc.pc = ScaleEntry
  spc.sp = 0xEF
  spc.x = channel.uint8
  spc.psw = 0
  var steps = 0
  while spc.pc != ReturnAddress:
    doAssert steps < 80
    spc.step()
    inc steps
  doAssert spc.ram[0x16].uint32 + (spc.ram[0x17].uint32 shl 8) == expected
  doAssert spc.x.int == channel and spc.sp == 0xF1
  if blocked:
    doAssert writes.len == 0
  else:
    doAssert writes == @[(0xF2'u16, (voice * 16 + 2).uint8),
      (0xF3'u16, (expected and 255).uint8),
      (0xF2'u16, (voice * 16 + 3).uint8),
      (0xF3'u16, (expected shr 8).uint8)]
  spc.writeHook = nil

proc main() =
  ## Exercise pitch scaling against the user's original uploaded driver.
  let rom = readGoldBaserom()
  var spc = newSpc()
  doAssert rom[DriverPayload - 4].int + (rom[DriverPayload - 3].int shl 8) == DriverLength
  doAssert rom[DriverPayload - 2].int + (rom[DriverPayload - 1].int shl 8) == DriverTarget
  for index in 0 ..< DriverLength:
    spc.ram[DriverTarget + index] = rom[DriverPayload + index]
  for voice in 0 ..< 8:
    for pitch in BoundaryWords:
      for factor in BoundaryWords:
        for blocked in [false, true]:
          spc.checkScale(voice, pitch, factor, blocked)
  for pitch in 0 .. 65535:
    for factor in [0, 1, 255, 256, 257, 32768, 65535]:
      spc.checkScale(0, pitch, factor, false)

when isMainModule:
  main()
