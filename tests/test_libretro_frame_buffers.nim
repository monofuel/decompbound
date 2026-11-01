import std/unittest

include ../src/libretro/core

const
  ProgramStart = 0x8000
  TransitionLine = 80
  InstructionsPerLine = 150
  DisplayColor = 0x03E0'u16

proc acceptPixels(command: cuint, data: pointer): bool {.cdecl.} =
  ## Select the standard software transport for synthetic frame coverage checks.
  command == RetroEnvSetPixelFormat and data != nil and
    cast[ptr cuint](data)[] == RetroPixelFormatXrgb8888

proc displayProgram(value: uint8): seq[uint8] =
  ## Generate an authored ROM that changes INIDISP after eighty visible scanlines.
  result = newSeq[uint8](RomSize)
  let change = ProgramStart + TransitionLine * InstructionsPerLine
  for offset in ProgramStart..<change: result[offset] = 0xEA
  let code = [0xA9'u8, value, 0x8D, 0x00, 0x21,
    0x4C, ((change + 5) and 0xFF).uint8, ((change + 5) shr 8).uint8]
  for offset, byte in code: result[change + offset] = byte
  result[0xFFD5] = 0x21
  result[0xFFFC] = (ProgramStart and 0xFF).uint8
  result[0xFFFD] = (ProgramStart shr 8).uint8

proc checkBlanking(start, finish: uint8) =
  ## Compare the actual frame entry point with the original unconditional-clear caller.
  var
    rom = displayProgram(finish)
    info = RetroGameInfo(data: addr rom[0], size: rom.len.csize_t)
  retro_set_environment(acceptPixels)
  retro_init()
  defer: retro_deinit()
  doAssert retro_load_game(addr info)
  defer: retro_unload_game()
  let
    reference = newSnesBus(rom)
    expected = newImage(ScreenWidth, ScreenHeight)
  defer: releaseHooks(reference)
  var referenceCpu = reference.resetCpu()
  for hardware in [reference, machine]:
    hardware.ppuRegs[0] = start
    hardware.cgram[0] = DisplayColor
  for frame in 0..<2:
    expected.fill(rgbx(0, 0, 0, 255))
    frameImage.fill(rgbx(97, 11, 193, 255))
    stepReplayFrame(reference, referenceCpu, expected)
    retro_run()
    doAssert frameImage.data == expected.data,
      "Frame initialization changed for INIDISP " & $start & " -> " & $finish
    doAssert machine.ppuRegs[0] == finish
    if frame == 0 and start == ForceBlankMask and finish == 15:
      doAssert expected[0, 0] != expected[0, ScreenHeight - 1],
        "The synthetic display program did not exercise partial-frame unblanking."

suite "Libretro frame initialization coverage":
  test "ordinary, blank and midframe display transitions match the old caller":
    for (start, finish) in [(15'u8, 15'u8), (0x80'u8, 0x80'u8),
        (0x80'u8, 15'u8), (15'u8, 0x80'u8)]:
      checkBlanking(start, finish)
