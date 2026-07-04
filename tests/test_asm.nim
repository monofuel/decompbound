## Tests for the 65816 opcode table and assembler/decoder pair.
## The round-trip properties here are the Goal 1 verification core
## (docs/goal-1.md): the tools must be exact inverses of each other.

import
  std/[os, sets],
  decompbound/[opcodes, assembler]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  ResetHandlerFileOffset = 0x8141

proc nativeFlags(m8: bool, x8: bool): FlagState =
  ## Build a native-mode flag state for tests.
  FlagState(m8: m8, x8: x8, emulation: false)

block tableIntegrity:
  # Every opcode has a real mnemonic and every (mnemonic, mode) pair is
  # unique, so findOpcode is a true inverse of the table.
  var seen = initHashSet[(string, AddressingMode)]()
  for opcode in 0..255:
    let info = OpcodeTable[opcode]
    doAssert info.mnemonic.len == 3,
      "opcode " & $opcode & " has bad mnemonic: " & info.mnemonic
    let key = (info.mnemonic, info.mode)
    doAssert key notin seen, "duplicate mnemonic+mode: " & info.mnemonic
    seen.incl key
    doAssert findOpcode(info.mnemonic, info.mode) == opcode

block knownEncodings:
  # Fixtures hand-verified against the W65C816S opcode matrix, mostly taken
  # from real Earthbound boot code bytes.
  let native16 = nativeFlags(false, false)
  let native8 = nativeFlags(true, true)

  proc check(bytes: seq[uint8], flags: FlagState, expected: string) =
    ## Decode bytes and compare formatted output and round-trip.
    let instr = decode(bytes, 0, flags)
    doAssert instr.size == bytes.len,
      expected & ": expected size " & $bytes.len & ", got " & $instr.size
    doAssert formatInstruction(instr) == expected,
      "expected '" & expected & "', got '" & formatInstruction(instr) & "'"
    doAssert encode(instr) == bytes, "round-trip failed for " & expected

  check(@[0x18'u8], native16, "CLC")
  check(@[0xFB'u8], native16, "XCE")
  # Note: reset.nim's comment claims this is "JML $C00080", but the bytes
  # 00 80 C0 are little-endian for $C08000 (file offset 0x8000). Another
  # transcription artifact in the old comments.
  check(@[0x5C'u8, 0x00, 0x80, 0xC0], native16, "JML $C08000")
  check(@[0x22'u8, 0x42, 0x2E, 0xC1], native16, "JSL $C12E42")
  check(@[0xC2'u8, 0x30], native16, "REP #$30")
  check(@[0xE2'u8, 0x20], native16, "SEP #$20")
  check(@[0x9C'u8, 0x45, 0x96], native16, "STZ $9645")
  check(@[0xAD'u8, 0x6C, 0x43], native16, "LDA $436C")
  check(@[0xF0'u8, 0x2A], native16, "BEQ +42")
  check(@[0x29'u8, 0x10, 0x80], native16, "AND #$8010")
  check(@[0xC9'u8, 0x10, 0x80], native16, "CMP #$8010")
  check(@[0xA9'u8, 0x42], native8, "LDA #$42")
  check(@[0xA2'u8, 0x34, 0x12], native16, "LDX #$1234")
  check(@[0xA2'u8, 0x12], native8, "LDX #$12")
  check(@[0xF4'u8, 0x34, 0x12], native16, "PEA $1234")
  check(@[0x54'u8, 0x7E, 0xC0], native16, "MVN $7E,$C0")
  check(@[0x44'u8, 0x7E, 0xC0], native16, "MVP $7E,$C0")
  check(@[0x1A'u8], native16, "INC A")
  check(@[0x8C'u8, 0x00, 0x43], native16, "STY $4300")
  check(@[0x80'u8, 0xFE], native16, "BRA -2")
  check(@[0x03'u8, 0x01], native16, "ORA $01,S")
  check(@[0x13'u8, 0x01], native16, "ORA ($01,S),Y")
  check(@[0x7C'u8, 0x00, 0x90], native16, "JMP ($9000,X)")
  check(@[0xDC'u8, 0x00, 0x90], native16, "JML [$9000]")

block exhaustiveRoundTrip:
  # Every opcode, under all four native flag combinations, must decode and
  # re-encode to identical bytes.
  for m8 in [false, true]:
    for x8 in [false, true]:
      let flags = nativeFlags(m8, x8)
      for opcode in 0..255:
        let data = @[opcode.uint8, 0x11'u8, 0x22, 0x33]
        let instr = decode(data, 0, flags)
        doAssert instr.size >= 1 and instr.size <= 4
        doAssert encode(instr) == data[0..<instr.size],
          "round-trip failed for opcode " & $opcode

block flagTracking:
  # M/X widths must follow REP/SEP through a decoded stream.
  let bytes = @[
    0xC2'u8, 0x30,        # REP #$30: A and X/Y to 16-bit.
    0xA9, 0x10, 0x80,     # LDA #$8010 (3 bytes now).
    0xE2, 0x20,           # SEP #$20: A back to 8-bit.
    0xA9, 0x42,           # LDA #$42 (2 bytes now).
    0xA2, 0x34, 0x12      # LDX #$1234 (X still 16-bit).
  ]
  let instrs = decodeStream(bytes, 0, bytes.len, nativeFlags(true, true))
  doAssert instrs.len == 5
  doAssert instrs[1].size == 3
  doAssert instrs[3].size == 2
  doAssert instrs[4].size == 3
  doAssert encodeStream(instrs) == bytes

block emulationEntry:
  # Reset state is emulation mode: 8-bit widths until XCE + REP.
  let bytes = @[
    0x18'u8,              # CLC.
    0xFB,                 # XCE: enter native mode (still 8-bit M/X).
    0xA9, 0x42,           # LDA #$42 (2 bytes: m8).
    0xC2, 0x30,           # REP #$30.
    0xA9, 0x34, 0x12      # LDA #$1234 (3 bytes now).
  ]
  let instrs = decodeStream(bytes, 0, bytes.len, initFlagState())
  doAssert instrs.len == 5
  doAssert instrs[2].size == 2
  doAssert instrs[4].size == 3
  doAssert encodeStream(instrs) == bytes

block assembleWithLabels:
  # Backward branch: delta resolves relative to the following instruction.
  let backward = assemble(@[
    label("loop"),
    instr("DEX", amImplied),
    instrTo("BNE", amRelative8, "loop"),
    instr("RTS", amImplied)
  ], 0x8000'u32, nativeFlags(true, true))
  doAssert backward == @[0xCA'u8, 0xD0, 0xFD, 0x60]

  # Forward branch across a NOP.
  let forward = assemble(@[
    instrTo("BRA", amRelative8, "done"),
    instr("NOP", amImplied),
    label("done"),
    instr("RTS", amImplied)
  ], 0x8000'u32, nativeFlags(true, true))
  doAssert forward == @[0x80'u8, 0x01, 0xEA, 0x60]

  # Immediate widths follow REP through assembly too.
  let widths = assemble(@[
    instr("REP", amImmediate8, 0x30),
    instr("LDA", amImmediateM, 0x8010),
    instr("SEP", amImmediate8, 0x20),
    instr("LDA", amImmediateM, 0x42)
  ], 0x8000'u32, nativeFlags(true, true))
  doAssert widths == @[0xC2'u8, 0x30, 0xA9, 0x10, 0x80, 0xE2, 0x20, 0xA9, 0x42]

block flagInstructionTracking:
  # REP/SEP touch only the requested status bits.
  var flags = FlagState(m8: true, x8: true, emulation: false)
  flags.applyInstruction(0xC2, 0x20)  # REP #$20: only M goes 16-bit.
  doAssert not flags.m8 and flags.x8
  flags.applyInstruction(0xE2, 0x10)  # SEP #$10: only X back to 8-bit.
  doAssert not flags.m8 and flags.x8
  flags.applyInstruction(0xC2, 0x10)  # REP #$10: X to 16-bit.
  doAssert not flags.m8 and not flags.x8
  # XCE only transitions out of emulation mode (CLC..XCE idiom).
  var emu = initFlagState()
  doAssert emu.emulation and emu.m8 and emu.x8
  emu.applyInstruction(0xFB, 0)
  doAssert not emu.emulation and emu.m8 and emu.x8
  emu.applyInstruction(0xFB, 0)  # A second XCE must not re-enter emulation.
  doAssert not emu.emulation

block assemblerErrors:
  # Branch out of range must raise, not emit garbage.
  var farNodes: seq[AsmNode]
  farNodes.add instrTo("BNE", amRelative8, "far")
  for i in 0..<200:
    farNodes.add instr("NOP", amImplied)
  farNodes.add label("far")
  var branchRaised = false
  try:
    discard assemble(farNodes, 0x8000'u32, nativeFlags(true, true))
  except ValueError:
    branchRaised = true
  doAssert branchRaised

  # Undefined labels must raise.
  var undefinedRaised = false
  try:
    discard assemble(@[instrTo("BRA", amRelative8, "nowhere")],
                     0x8000'u32, nativeFlags(true, true))
  except ValueError:
    undefinedRaised = true
  doAssert undefinedRaised

  # Impossible mnemonic + mode combinations must raise.
  var comboRaised = false
  try:
    discard assemble(@[instr("RTS", amAbsolute, 0x1234)],
                     0x8000'u32, nativeFlags(true, true))
  except ValueError:
    comboRaised = true
  doAssert comboRaised

block decodeRangeBoundary:
  # decodeRange must stop cleanly before an instruction that would cross
  # the range end, and report the covered length.
  let bytes = @[0xEA'u8, 0x5C, 0x11, 0x22, 0x33]  # NOP, then JML.
  let (instrs, covered) = decodeRange(bytes, 0, 2, nativeFlags(true, true))
  doAssert instrs.len == 1
  doAssert covered == 1

block goldBootPath:
  # The strongest fixture: the gold ROM's own reset handler. Only runs
  # locally where the (gitignored, copyrighted) ROM exists; CI has no ROM.
  if fileExists(GoldMasterRom):
    let romStr = readFile(GoldMasterRom)
    var rom = newSeq[uint8](romStr.len)
    for i in 0..<romStr.len:
      rom[i] = romStr[i].uint8

    # The documented boot sequence, decoded from actual bytes with reset
    # entry flags (emulation mode).
    let (instrs, covered) = decodeRange(rom, ResetHandlerFileOffset, 32,
                                        initFlagState())
    doAssert formatInstruction(instrs[0]) == "CLC"
    doAssert formatInstruction(instrs[1]) == "XCE"
    doAssert formatInstruction(instrs[2]) == "JML $C08000"
    doAssert formatInstruction(instrs[3]) == "JML $C08170"
    doAssert formatInstruction(instrs[4]) == "JML $C0814F"
    doAssert formatInstruction(instrs[5]) == "PHP"
    doAssert formatInstruction(instrs[6]) == "REP #$30"

    # Round-trip the covered range back to identical bytes.
    let reencoded = encodeStream(instrs)
    doAssert reencoded == rom[ResetHandlerFileOffset ..< ResetHandlerFileOffset + covered]

    # Round-trip a larger linear sweep of the reset handler region.
    let (regionInstrs, regionCovered) = decodeRange(rom, ResetHandlerFileOffset,
                                                    704, initFlagState())
    doAssert regionCovered > 600
    doAssert encodeStream(regionInstrs) ==
      rom[ResetHandlerFileOffset ..< ResetHandlerFileOffset + regionCovered]
