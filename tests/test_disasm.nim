## Tests for the HiROM memory mapping and the control-flow tracer.

import
  std/[os, sets, tables],
  decompbound/[assembler, disasm, memmap, opcodes]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"

block memoryMapping:
  # Canonical ROM banks.
  doAssert snesToFile(0xC00000'u32) == 0x000000
  doAssert snesToFile(0xC08000'u32) == 0x008000
  doAssert snesToFile(0xC10000'u32) == 0x010000
  doAssert snesToFile(0xEFFFFF'u32) == 0x2FFFFF
  # Bank 0 upper half mirrors the ROM (where the vectors live).
  doAssert snesToFile(0x008141'u32) == 0x008141
  doAssert snesToFile(0x00FFFC'u32) == 0x00FFFC
  # Full-bank mirrors at $40-$7D.
  doAssert snesToFile(0x400000'u32) == 0x000000
  doAssert snesToFile(0x7D8000'u32) == 0x3D8000
  # Not ROM: bank 0 lower half (WRAM/MMIO) and the WRAM banks.
  doAssert snesToFile(0x001000'u32) == -1
  doAssert snesToFile(0x7E0000'u32) == -1
  doAssert snesToFile(0x7F8000'u32) == -1
  # File offsets map back to canonical bank $C0 addresses.
  doAssert fileToSnes(0x8000) == 0xC08000'u32
  doAssert snesToFile(fileToSnes(0x123456)) == 0x123456

block branchTargets:
  let native = FlagState(m8: false, x8: false, emulation: false)

  proc target(bytes: seq[uint8], snesAddr: uint32): int64 =
    ## Decode the first instruction and resolve its branch target.
    branchTargetSnes(decode(bytes, 0, native), snesAddr)

  # BEQ +42 from $C08100: next is $C08102, target $C0812C.
  doAssert target(@[0xF0'u8, 0x2A], 0xC08100'u32) == 0xC0812C
  # BRA -2 loops onto itself.
  doAssert target(@[0x80'u8, 0xFE], 0xC08100'u32) == 0xC08100
  # Branches wrap within the bank.
  doAssert target(@[0x80'u8, 0x10], 0xC0FFF8'u32) == 0xC0000A
  # JSR stays in the current program bank.
  doAssert target(@[0x20'u8, 0x34, 0x12], 0xC08000'u32) == 0xC01234
  # JML/JSL carry their full 24-bit target.
  doAssert target(@[0x5C'u8, 0x00, 0x80, 0xC0], 0x008143'u32) == 0xC08000
  doAssert target(@[0x22'u8, 0x42, 0x2E, 0xC1], 0xC08000'u32) == 0xC12E42
  # Returns and indirect jumps have no static target.
  doAssert target(@[0x60'u8], 0xC08000'u32) == -1
  doAssert target(@[0x6C'u8, 0x00, 0x90], 0xC08000'u32) == -1

block syntheticTrace:
  # A tiny fake ROM: boot code at 0x8000 calls a subroutine at 0x8010,
  # then stops. A declared data region must not be traced.
  var rom = newSeq[uint8](0x10000)
  let boot = @[
    0x18'u8,             # CLC.
    0xFB,                # XCE.
    0xC2, 0x30,          # REP #$30.
    0x20, 0x10, 0x80,    # JSR $8010.
    0xDB                 # STP.
  ]
  let sub = @[
    0xA9'u8, 0x34, 0x12, # LDA #$1234 (16-bit: flags inherited via JSR).
    0x60                 # RTS.
  ]
  for i, b in boot:
    rom[0x8000 + i] = b
  for i, b in sub:
    rom[0x8010 + i] = b

  let analysis = analyzeControlFlow(rom, @[0x8000],
                                    @[(start: 0x9000, last: 0x90FF)])
  for i in 0x8000..0x8007:
    doAssert analysis.byteTypes[i] == Code
  for i in 0x8010..0x8013:
    doAssert analysis.byteTypes[i] == Code
  # The LDA decoded as 3 bytes proves flag state propagated through the JSR.
  doAssert analysis.byteTypes[0x8014] == Unknown
  doAssert analysis.crossReferences[0x8010] == @[0x8004]
  for i in 0x9000..0x90FF:
    doAssert analysis.byteTypes[i] == Data

block entryFlagRecording:
  # The tracer must record the flag state each run started with; this is
  # what gives generated modules observed entry states instead of guesses.
  var rom = newSeq[uint8](0x10000)
  let boot = @[
    0x18'u8,             # CLC.
    0xFB,                # XCE.
    0xC2, 0x30,          # REP #$30.
    0x20, 0x10, 0x80,    # JSR $8010.
    0xDB                 # STP.
  ]
  for i, b in boot:
    rom[0x8000 + i] = b
  rom[0x8010] = 0x60  # RTS.

  let analysis = analyzeControlFlow(rom, @[0x8000])
  doAssert analysis.entryFlagStates[0x8000] == initFlagState()
  # The subroutine inherits native 16-bit state through the JSR.
  doAssert analysis.entryFlagStates[0x8010] ==
    FlagState(m8: false, x8: false, emulation: false)

block frontierRecording:
  # Computed jumps must be recorded as frontier sites, not silently dropped.
  var rom = newSeq[uint8](0x10000)
  let code = @[
    0x6C'u8, 0x20, 0x00,  # JMP ($0020): indirect, statically unfollowable.
    0x60                  # RTS (unreachable, but keeps the region tidy).
  ]
  for i, b in code:
    rom[0x8000 + i] = b
  let analysis = analyzeControlFlow(rom, @[0x8000])
  doAssert analysis.frontier.len == 1
  doAssert analysis.frontier[0].fileOffset == 0x8000
  doAssert formatInstruction(analysis.frontier[0].instr) == "JMP ($0020)"

block paddingDetection:
  var rom = newSeq[uint8](512)
  for i in 0..<200:
    rom[i] = 0xFF
  rom[300] = 0x42
  var analysis = analyzeControlFlow(rom, @[])
  detectPadding(rom, analysis, minRunLength = 64)
  doAssert analysis.byteTypes[0] == Padding
  doAssert analysis.byteTypes[199] == Padding
  doAssert analysis.byteTypes[200] == Padding  # Zero run after the 0xFF run.
  doAssert analysis.byteTypes[300] == Unknown  # Lone byte, not a run.

block labelFormatting:
  let native = FlagState(m8: false, x8: false, emulation: false)
  var labels = initHashSet[int]()
  labels.incl 0x8000
  # A branch to a labeled offset formats as the label.
  let bra = decode(@[0x80'u8, 0xFE], 0, native)  # BRA -2 at $C08000.
  doAssert formatWithLabels(bra, 0xC08000'u32, labels) == "BRA label_008000"
  # A branch to an unlabeled offset keeps numeric form.
  let bne = decode(@[0xD0'u8, 0x10], 0, native)
  doAssert formatWithLabels(bne, 0xC08100'u32, labels) == "BNE +16"

block controlFlowClassification:
  let native = FlagState(m8: false, x8: false, emulation: false)
  # Returns and unconditional jumps end a linear run.
  doAssert decode(@[0x60'u8], 0, native).endsRun          # RTS.
  doAssert decode(@[0x5C'u8, 0, 0x80, 0xC0], 0, native).endsRun  # JML.
  doAssert decode(@[0x80'u8, 0x10], 0, native).endsRun    # BRA.
  doAssert decode(@[0xDB'u8], 0, native).endsRun          # STP.
  # Calls and conditional branches fall through.
  doAssert not decode(@[0x20'u8, 0x00, 0x90], 0, native).endsRun  # JSR.
  doAssert not decode(@[0xF0'u8, 0x10], 0, native).endsRun        # BEQ.
  doAssert decode(@[0xF0'u8, 0x10], 0, native).isControlFlow
  doAssert not decode(@[0xEA'u8], 0, native).isControlFlow        # NOP.

block goldTrace:
  # Trace the real ROM from its reset vector; only runs where the
  # (gitignored, copyrighted) gold ROM exists. CI has no ROM.
  if fileExists(GoldMasterRom):
    let romStr = readFile(GoldMasterRom)
    var rom = newSeq[uint8](romStr.len)
    for i in 0..<romStr.len:
      rom[i] = romStr[i].uint8

    let resetVector = rom[0xFFFC].int or (rom[0xFFFD].int shl 8)
    doAssert resetVector == 0x8141

    let analysis = analyzeControlFlow(rom, @[0x8141],
                                      @[(start: 0xFFB0, last: 0xFFFF)])
    # The tracer must follow JML $C08000 across the bank boundary.
    doAssert analysis.byteTypes[0x8000] == Code
    doAssert analysis.byteTypes[0x8141] == Code
    # The header stays data.
    doAssert analysis.byteTypes[0xFFB0] == Data
    # Static tracing from reset alone discovers a large body of code.
    var codeBytes = 0
    for byteType in analysis.byteTypes:
      if byteType == Code:
        codeBytes += 1
    doAssert codeBytes > 100_000
