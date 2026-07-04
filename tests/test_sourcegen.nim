## Tests for the source generator: the tool that turns ROM disassembly
## into the Nim assembler-DSL modules under src/decompbound/generated/.
## These run on synthetic ROMs, no gold master needed.

import
  std/strutils,
  decompbound/[opcodes, sourcegen]

proc nativeFlags(): FlagState =
  ## Native-mode 16-bit flag state for tests.
  FlagState(m8: false, x8: false, emulation: false)

block basicGeneration:
  # A small region at file 0x8000 (SNES $C08000) with an internal branch
  # and an external jump.
  var rom = newSeq[uint8](0x10000)
  let code = @[
    0xA9'u8, 0x00, 0x10,  # LDA #$1000 (16-bit).
    0xD0, 0xFB,           # BNE -5 (back to region start).
    0x5C, 0x00, 0x90, 0xC1,  # JML $C19000 (outside the region).
    0x60                  # RTS.
  ]
  for i, b in code:
    rom[0x8000 + i] = b

  let (source, covered, instructions) = generateModuleSource(
    rom, 0x8000, code.len, "generateTest", nativeFlags())
  doAssert covered == code.len
  doAssert instructions == 4
  doAssert "proc generateTest*(): seq[uint8] =" in source
  # The backward branch resolves to an in-region label.
  doAssert "label(\"loc_C08000\")" in source
  doAssert "instrTo(\"BNE\", amRelative8, \"loc_C08000\")" in source
  # The external JML stays numeric.
  doAssert "instr(\"JML\", amAbsoluteLong, 0xC19000)" in source
  # No data tail was needed.
  doAssert "result.add @[" notin source

block mirroredBankRegression:
  # Regression: gold encodes some long jumps through mirrored banks
  # (e.g. JML $809470 = file 0x9470 = canonical $C09470). Labeling such a
  # jump would re-encode it into the canonical bank and change the byte.
  # It must stay numeric even when the target is inside the region.
  var rom = newSeq[uint8](0x10000)
  let code = @[
    0x5C'u8, 0x08, 0x80, 0x80,  # JML $808008: mirrored-bank encoding.
    0xEA,                       # NOP.
    0xEA,                       # NOP.
    0xEA,                       # NOP.
    0xEA,                       # NOP (file 0x8008 = the JML target).
    0x60                        # RTS.
  ]
  for i, b in code:
    rom[0x8000 + i] = b

  let (source, _, _) = generateModuleSource(
    rom, 0x8000, code.len, "generateTest", nativeFlags())
  doAssert "instr(\"JML\", amAbsoluteLong, 0x808008)" in source
  doAssert "instrTo(\"JML\"" notin source

  # The canonical encoding of the same jump does get a label.
  var rom2 = rom
  rom2[0x8003] = 0xC0  # JML $C08008.
  let (source2, _, _) = generateModuleSource(
    rom2, 0x8000, code.len, "generateTest", nativeFlags())
  doAssert "instrTo(\"JML\", amAbsoluteLong, \"loc_C08008\")" in source2

block dataTail:
  # A region boundary that cuts an instruction mid-operand must emit the
  # remainder as a declared data tail, never as a truncated instruction.
  var rom = newSeq[uint8](0x10000)
  rom[0x8000] = 0xEA  # NOP.
  rom[0x8001] = 0x5C  # JML: needs 3 operand bytes, but the region ends.
  rom[0x8002] = 0x11
  rom[0x8003] = 0x22

  let (source, covered, instructions) = generateModuleSource(
    rom, 0x8000, 4, "generateTest", nativeFlags())
  doAssert covered == 1
  doAssert instructions == 1
  doAssert "result.add @[0x5C'u8, 0x11'u8, 0x22'u8]" in source

block entryFlagWidths:
  # Entry flag state changes how immediates decode; the generated source
  # must carry the same state so assembly reproduces identical bytes.
  var rom = newSeq[uint8](0x10000)
  rom[0x8000] = 0xA9  # LDA immediate.
  rom[0x8001] = 0x42
  rom[0x8002] = 0x60  # RTS (consumed as the high byte in 16-bit mode).

  let (source8, _, instr8) = generateModuleSource(
    rom, 0x8000, 3, "generateTest",
    FlagState(m8: true, x8: true, emulation: false))
  doAssert instr8 == 2
  doAssert "LDA #$42" in source8
  doAssert "m8: true" in source8

  let (source16, _, instr16) = generateModuleSource(
    rom, 0x8000, 3, "generateTest", nativeFlags())
  doAssert instr16 == 1
  doAssert "LDA #$6042" in source16
  doAssert "m8: false" in source16
