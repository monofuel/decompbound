## The 65816 opcode table: the single source of truth for the assembler,
## the disassembler, and (later) the emulator CPU core. All three derive from
## this table so they structurally cannot disagree. See docs/goal-1.md.
##
## Reference: WDC W65C816S datasheet opcode matrix. All 256 opcodes are
## defined; the 65816 has no undefined opcodes.

type
  AddressingMode* = enum
    amImplied            ## No operand (CLC, RTS, ...).
    amAccumulator        ## Operates on A (INC A, ASL A, ...), no operand.
    amImmediateM         ## Immediate, width depends on the M flag (LDA #).
    amImmediateX         ## Immediate, width depends on the X flag (LDX #).
    amImmediate8         ## Immediate, always 1 byte (REP, SEP, BRK, COP, WDM).
    amDirectPage         ## dp.
    amDirectPageX        ## dp,X.
    amDirectPageY        ## dp,Y.
    amDpIndirect         ## (dp).
    amDpIndirectX        ## (dp,X).
    amDpIndirectY        ## (dp),Y.
    amDpIndirectLong     ## [dp].
    amDpIndirectLongY    ## [dp],Y.
    amAbsolute           ## abs.
    amAbsoluteX          ## abs,X.
    amAbsoluteY          ## abs,Y.
    amAbsoluteLong       ## al (24-bit).
    amAbsoluteLongX      ## al,X.
    amAbsIndirect        ## (abs) - JMP.
    amAbsIndirectX       ## (abs,X) - JMP/JSR.
    amAbsIndirectLong    ## [abs] - JML.
    amStackRelative      ## sr,S.
    amStackRelativeY     ## (sr,S),Y.
    amRelative8          ## 8-bit branch offset.
    amRelative16         ## 16-bit branch offset (BRL, PER).
    amBlockMove          ## MVN/MVP: two bank bytes (dst, src).

  OpcodeInfo* = object
    mnemonic*: string
    mode*: AddressingMode

  FlagState* = object
    ## Tracked processor flag state for operand width decisions.
    m8*: bool  ## Accumulator/memory in 8-bit mode.
    x8*: bool  ## Index registers in 8-bit mode.
    emulation*: bool  ## 6502 emulation mode (forces m8 and x8).

const
  OpcodeTable*: array[256, OpcodeInfo] = [
    # 0x00-0x0F.
    OpcodeInfo(mnemonic: "BRK", mode: amImmediate8),
    OpcodeInfo(mnemonic: "ORA", mode: amDpIndirectX),
    OpcodeInfo(mnemonic: "COP", mode: amImmediate8),
    OpcodeInfo(mnemonic: "ORA", mode: amStackRelative),
    OpcodeInfo(mnemonic: "TSB", mode: amDirectPage),
    OpcodeInfo(mnemonic: "ORA", mode: amDirectPage),
    OpcodeInfo(mnemonic: "ASL", mode: amDirectPage),
    OpcodeInfo(mnemonic: "ORA", mode: amDpIndirectLong),
    OpcodeInfo(mnemonic: "PHP", mode: amImplied),
    OpcodeInfo(mnemonic: "ORA", mode: amImmediateM),
    OpcodeInfo(mnemonic: "ASL", mode: amAccumulator),
    OpcodeInfo(mnemonic: "PHD", mode: amImplied),
    OpcodeInfo(mnemonic: "TSB", mode: amAbsolute),
    OpcodeInfo(mnemonic: "ORA", mode: amAbsolute),
    OpcodeInfo(mnemonic: "ASL", mode: amAbsolute),
    OpcodeInfo(mnemonic: "ORA", mode: amAbsoluteLong),
    # 0x10-0x1F.
    OpcodeInfo(mnemonic: "BPL", mode: amRelative8),
    OpcodeInfo(mnemonic: "ORA", mode: amDpIndirectY),
    OpcodeInfo(mnemonic: "ORA", mode: amDpIndirect),
    OpcodeInfo(mnemonic: "ORA", mode: amStackRelativeY),
    OpcodeInfo(mnemonic: "TRB", mode: amDirectPage),
    OpcodeInfo(mnemonic: "ORA", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "ASL", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "ORA", mode: amDpIndirectLongY),
    OpcodeInfo(mnemonic: "CLC", mode: amImplied),
    OpcodeInfo(mnemonic: "ORA", mode: amAbsoluteY),
    OpcodeInfo(mnemonic: "INC", mode: amAccumulator),
    OpcodeInfo(mnemonic: "TCS", mode: amImplied),
    OpcodeInfo(mnemonic: "TRB", mode: amAbsolute),
    OpcodeInfo(mnemonic: "ORA", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "ASL", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "ORA", mode: amAbsoluteLongX),
    # 0x20-0x2F.
    OpcodeInfo(mnemonic: "JSR", mode: amAbsolute),
    OpcodeInfo(mnemonic: "AND", mode: amDpIndirectX),
    OpcodeInfo(mnemonic: "JSL", mode: amAbsoluteLong),
    OpcodeInfo(mnemonic: "AND", mode: amStackRelative),
    OpcodeInfo(mnemonic: "BIT", mode: amDirectPage),
    OpcodeInfo(mnemonic: "AND", mode: amDirectPage),
    OpcodeInfo(mnemonic: "ROL", mode: amDirectPage),
    OpcodeInfo(mnemonic: "AND", mode: amDpIndirectLong),
    OpcodeInfo(mnemonic: "PLP", mode: amImplied),
    OpcodeInfo(mnemonic: "AND", mode: amImmediateM),
    OpcodeInfo(mnemonic: "ROL", mode: amAccumulator),
    OpcodeInfo(mnemonic: "PLD", mode: amImplied),
    OpcodeInfo(mnemonic: "BIT", mode: amAbsolute),
    OpcodeInfo(mnemonic: "AND", mode: amAbsolute),
    OpcodeInfo(mnemonic: "ROL", mode: amAbsolute),
    OpcodeInfo(mnemonic: "AND", mode: amAbsoluteLong),
    # 0x30-0x3F.
    OpcodeInfo(mnemonic: "BMI", mode: amRelative8),
    OpcodeInfo(mnemonic: "AND", mode: amDpIndirectY),
    OpcodeInfo(mnemonic: "AND", mode: amDpIndirect),
    OpcodeInfo(mnemonic: "AND", mode: amStackRelativeY),
    OpcodeInfo(mnemonic: "BIT", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "AND", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "ROL", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "AND", mode: amDpIndirectLongY),
    OpcodeInfo(mnemonic: "SEC", mode: amImplied),
    OpcodeInfo(mnemonic: "AND", mode: amAbsoluteY),
    OpcodeInfo(mnemonic: "DEC", mode: amAccumulator),
    OpcodeInfo(mnemonic: "TSC", mode: amImplied),
    OpcodeInfo(mnemonic: "BIT", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "AND", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "ROL", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "AND", mode: amAbsoluteLongX),
    # 0x40-0x4F.
    OpcodeInfo(mnemonic: "RTI", mode: amImplied),
    OpcodeInfo(mnemonic: "EOR", mode: amDpIndirectX),
    OpcodeInfo(mnemonic: "WDM", mode: amImmediate8),
    OpcodeInfo(mnemonic: "EOR", mode: amStackRelative),
    OpcodeInfo(mnemonic: "MVP", mode: amBlockMove),
    OpcodeInfo(mnemonic: "EOR", mode: amDirectPage),
    OpcodeInfo(mnemonic: "LSR", mode: amDirectPage),
    OpcodeInfo(mnemonic: "EOR", mode: amDpIndirectLong),
    OpcodeInfo(mnemonic: "PHA", mode: amImplied),
    OpcodeInfo(mnemonic: "EOR", mode: amImmediateM),
    OpcodeInfo(mnemonic: "LSR", mode: amAccumulator),
    OpcodeInfo(mnemonic: "PHK", mode: amImplied),
    OpcodeInfo(mnemonic: "JMP", mode: amAbsolute),
    OpcodeInfo(mnemonic: "EOR", mode: amAbsolute),
    OpcodeInfo(mnemonic: "LSR", mode: amAbsolute),
    OpcodeInfo(mnemonic: "EOR", mode: amAbsoluteLong),
    # 0x50-0x5F.
    OpcodeInfo(mnemonic: "BVC", mode: amRelative8),
    OpcodeInfo(mnemonic: "EOR", mode: amDpIndirectY),
    OpcodeInfo(mnemonic: "EOR", mode: amDpIndirect),
    OpcodeInfo(mnemonic: "EOR", mode: amStackRelativeY),
    OpcodeInfo(mnemonic: "MVN", mode: amBlockMove),
    OpcodeInfo(mnemonic: "EOR", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "LSR", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "EOR", mode: amDpIndirectLongY),
    OpcodeInfo(mnemonic: "CLI", mode: amImplied),
    OpcodeInfo(mnemonic: "EOR", mode: amAbsoluteY),
    OpcodeInfo(mnemonic: "PHY", mode: amImplied),
    OpcodeInfo(mnemonic: "TCD", mode: amImplied),
    OpcodeInfo(mnemonic: "JML", mode: amAbsoluteLong),
    OpcodeInfo(mnemonic: "EOR", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "LSR", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "EOR", mode: amAbsoluteLongX),
    # 0x60-0x6F.
    OpcodeInfo(mnemonic: "RTS", mode: amImplied),
    OpcodeInfo(mnemonic: "ADC", mode: amDpIndirectX),
    OpcodeInfo(mnemonic: "PER", mode: amRelative16),
    OpcodeInfo(mnemonic: "ADC", mode: amStackRelative),
    OpcodeInfo(mnemonic: "STZ", mode: amDirectPage),
    OpcodeInfo(mnemonic: "ADC", mode: amDirectPage),
    OpcodeInfo(mnemonic: "ROR", mode: amDirectPage),
    OpcodeInfo(mnemonic: "ADC", mode: amDpIndirectLong),
    OpcodeInfo(mnemonic: "PLA", mode: amImplied),
    OpcodeInfo(mnemonic: "ADC", mode: amImmediateM),
    OpcodeInfo(mnemonic: "ROR", mode: amAccumulator),
    OpcodeInfo(mnemonic: "RTL", mode: amImplied),
    OpcodeInfo(mnemonic: "JMP", mode: amAbsIndirect),
    OpcodeInfo(mnemonic: "ADC", mode: amAbsolute),
    OpcodeInfo(mnemonic: "ROR", mode: amAbsolute),
    OpcodeInfo(mnemonic: "ADC", mode: amAbsoluteLong),
    # 0x70-0x7F.
    OpcodeInfo(mnemonic: "BVS", mode: amRelative8),
    OpcodeInfo(mnemonic: "ADC", mode: amDpIndirectY),
    OpcodeInfo(mnemonic: "ADC", mode: amDpIndirect),
    OpcodeInfo(mnemonic: "ADC", mode: amStackRelativeY),
    OpcodeInfo(mnemonic: "STZ", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "ADC", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "ROR", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "ADC", mode: amDpIndirectLongY),
    OpcodeInfo(mnemonic: "SEI", mode: amImplied),
    OpcodeInfo(mnemonic: "ADC", mode: amAbsoluteY),
    OpcodeInfo(mnemonic: "PLY", mode: amImplied),
    OpcodeInfo(mnemonic: "TDC", mode: amImplied),
    OpcodeInfo(mnemonic: "JMP", mode: amAbsIndirectX),
    OpcodeInfo(mnemonic: "ADC", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "ROR", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "ADC", mode: amAbsoluteLongX),
    # 0x80-0x8F.
    OpcodeInfo(mnemonic: "BRA", mode: amRelative8),
    OpcodeInfo(mnemonic: "STA", mode: amDpIndirectX),
    OpcodeInfo(mnemonic: "BRL", mode: amRelative16),
    OpcodeInfo(mnemonic: "STA", mode: amStackRelative),
    OpcodeInfo(mnemonic: "STY", mode: amDirectPage),
    OpcodeInfo(mnemonic: "STA", mode: amDirectPage),
    OpcodeInfo(mnemonic: "STX", mode: amDirectPage),
    OpcodeInfo(mnemonic: "STA", mode: amDpIndirectLong),
    OpcodeInfo(mnemonic: "DEY", mode: amImplied),
    OpcodeInfo(mnemonic: "BIT", mode: amImmediateM),
    OpcodeInfo(mnemonic: "TXA", mode: amImplied),
    OpcodeInfo(mnemonic: "PHB", mode: amImplied),
    OpcodeInfo(mnemonic: "STY", mode: amAbsolute),
    OpcodeInfo(mnemonic: "STA", mode: amAbsolute),
    OpcodeInfo(mnemonic: "STX", mode: amAbsolute),
    OpcodeInfo(mnemonic: "STA", mode: amAbsoluteLong),
    # 0x90-0x9F.
    OpcodeInfo(mnemonic: "BCC", mode: amRelative8),
    OpcodeInfo(mnemonic: "STA", mode: amDpIndirectY),
    OpcodeInfo(mnemonic: "STA", mode: amDpIndirect),
    OpcodeInfo(mnemonic: "STA", mode: amStackRelativeY),
    OpcodeInfo(mnemonic: "STY", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "STA", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "STX", mode: amDirectPageY),
    OpcodeInfo(mnemonic: "STA", mode: amDpIndirectLongY),
    OpcodeInfo(mnemonic: "TYA", mode: amImplied),
    OpcodeInfo(mnemonic: "STA", mode: amAbsoluteY),
    OpcodeInfo(mnemonic: "TXS", mode: amImplied),
    OpcodeInfo(mnemonic: "TXY", mode: amImplied),
    OpcodeInfo(mnemonic: "STZ", mode: amAbsolute),
    OpcodeInfo(mnemonic: "STA", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "STZ", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "STA", mode: amAbsoluteLongX),
    # 0xA0-0xAF.
    OpcodeInfo(mnemonic: "LDY", mode: amImmediateX),
    OpcodeInfo(mnemonic: "LDA", mode: amDpIndirectX),
    OpcodeInfo(mnemonic: "LDX", mode: amImmediateX),
    OpcodeInfo(mnemonic: "LDA", mode: amStackRelative),
    OpcodeInfo(mnemonic: "LDY", mode: amDirectPage),
    OpcodeInfo(mnemonic: "LDA", mode: amDirectPage),
    OpcodeInfo(mnemonic: "LDX", mode: amDirectPage),
    OpcodeInfo(mnemonic: "LDA", mode: amDpIndirectLong),
    OpcodeInfo(mnemonic: "TAY", mode: amImplied),
    OpcodeInfo(mnemonic: "LDA", mode: amImmediateM),
    OpcodeInfo(mnemonic: "TAX", mode: amImplied),
    OpcodeInfo(mnemonic: "PLB", mode: amImplied),
    OpcodeInfo(mnemonic: "LDY", mode: amAbsolute),
    OpcodeInfo(mnemonic: "LDA", mode: amAbsolute),
    OpcodeInfo(mnemonic: "LDX", mode: amAbsolute),
    OpcodeInfo(mnemonic: "LDA", mode: amAbsoluteLong),
    # 0xB0-0xBF.
    OpcodeInfo(mnemonic: "BCS", mode: amRelative8),
    OpcodeInfo(mnemonic: "LDA", mode: amDpIndirectY),
    OpcodeInfo(mnemonic: "LDA", mode: amDpIndirect),
    OpcodeInfo(mnemonic: "LDA", mode: amStackRelativeY),
    OpcodeInfo(mnemonic: "LDY", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "LDA", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "LDX", mode: amDirectPageY),
    OpcodeInfo(mnemonic: "LDA", mode: amDpIndirectLongY),
    OpcodeInfo(mnemonic: "CLV", mode: amImplied),
    OpcodeInfo(mnemonic: "LDA", mode: amAbsoluteY),
    OpcodeInfo(mnemonic: "TSX", mode: amImplied),
    OpcodeInfo(mnemonic: "TYX", mode: amImplied),
    OpcodeInfo(mnemonic: "LDY", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "LDA", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "LDX", mode: amAbsoluteY),
    OpcodeInfo(mnemonic: "LDA", mode: amAbsoluteLongX),
    # 0xC0-0xCF.
    OpcodeInfo(mnemonic: "CPY", mode: amImmediateX),
    OpcodeInfo(mnemonic: "CMP", mode: amDpIndirectX),
    OpcodeInfo(mnemonic: "REP", mode: amImmediate8),
    OpcodeInfo(mnemonic: "CMP", mode: amStackRelative),
    OpcodeInfo(mnemonic: "CPY", mode: amDirectPage),
    OpcodeInfo(mnemonic: "CMP", mode: amDirectPage),
    OpcodeInfo(mnemonic: "DEC", mode: amDirectPage),
    OpcodeInfo(mnemonic: "CMP", mode: amDpIndirectLong),
    OpcodeInfo(mnemonic: "INY", mode: amImplied),
    OpcodeInfo(mnemonic: "CMP", mode: amImmediateM),
    OpcodeInfo(mnemonic: "DEX", mode: amImplied),
    OpcodeInfo(mnemonic: "WAI", mode: amImplied),
    OpcodeInfo(mnemonic: "CPY", mode: amAbsolute),
    OpcodeInfo(mnemonic: "CMP", mode: amAbsolute),
    OpcodeInfo(mnemonic: "DEC", mode: amAbsolute),
    OpcodeInfo(mnemonic: "CMP", mode: amAbsoluteLong),
    # 0xD0-0xDF.
    OpcodeInfo(mnemonic: "BNE", mode: amRelative8),
    OpcodeInfo(mnemonic: "CMP", mode: amDpIndirectY),
    OpcodeInfo(mnemonic: "CMP", mode: amDpIndirect),
    OpcodeInfo(mnemonic: "CMP", mode: amStackRelativeY),
    OpcodeInfo(mnemonic: "PEI", mode: amDpIndirect),
    OpcodeInfo(mnemonic: "CMP", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "DEC", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "CMP", mode: amDpIndirectLongY),
    OpcodeInfo(mnemonic: "CLD", mode: amImplied),
    OpcodeInfo(mnemonic: "CMP", mode: amAbsoluteY),
    OpcodeInfo(mnemonic: "PHX", mode: amImplied),
    OpcodeInfo(mnemonic: "STP", mode: amImplied),
    OpcodeInfo(mnemonic: "JML", mode: amAbsIndirectLong),
    OpcodeInfo(mnemonic: "CMP", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "DEC", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "CMP", mode: amAbsoluteLongX),
    # 0xE0-0xEF.
    OpcodeInfo(mnemonic: "CPX", mode: amImmediateX),
    OpcodeInfo(mnemonic: "SBC", mode: amDpIndirectX),
    OpcodeInfo(mnemonic: "SEP", mode: amImmediate8),
    OpcodeInfo(mnemonic: "SBC", mode: amStackRelative),
    OpcodeInfo(mnemonic: "CPX", mode: amDirectPage),
    OpcodeInfo(mnemonic: "SBC", mode: amDirectPage),
    OpcodeInfo(mnemonic: "INC", mode: amDirectPage),
    OpcodeInfo(mnemonic: "SBC", mode: amDpIndirectLong),
    OpcodeInfo(mnemonic: "INX", mode: amImplied),
    OpcodeInfo(mnemonic: "SBC", mode: amImmediateM),
    OpcodeInfo(mnemonic: "NOP", mode: amImplied),
    OpcodeInfo(mnemonic: "XBA", mode: amImplied),
    OpcodeInfo(mnemonic: "CPX", mode: amAbsolute),
    OpcodeInfo(mnemonic: "SBC", mode: amAbsolute),
    OpcodeInfo(mnemonic: "INC", mode: amAbsolute),
    OpcodeInfo(mnemonic: "SBC", mode: amAbsoluteLong),
    # 0xF0-0xFF.
    OpcodeInfo(mnemonic: "BEQ", mode: amRelative8),
    OpcodeInfo(mnemonic: "SBC", mode: amDpIndirectY),
    OpcodeInfo(mnemonic: "SBC", mode: amDpIndirect),
    OpcodeInfo(mnemonic: "SBC", mode: amStackRelativeY),
    OpcodeInfo(mnemonic: "PEA", mode: amAbsolute),
    OpcodeInfo(mnemonic: "SBC", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "INC", mode: amDirectPageX),
    OpcodeInfo(mnemonic: "SBC", mode: amDpIndirectLongY),
    OpcodeInfo(mnemonic: "SED", mode: amImplied),
    OpcodeInfo(mnemonic: "SBC", mode: amAbsoluteY),
    OpcodeInfo(mnemonic: "PLX", mode: amImplied),
    OpcodeInfo(mnemonic: "XCE", mode: amImplied),
    OpcodeInfo(mnemonic: "JSR", mode: amAbsIndirectX),
    OpcodeInfo(mnemonic: "SBC", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "INC", mode: amAbsoluteX),
    OpcodeInfo(mnemonic: "SBC", mode: amAbsoluteLongX)
  ]

proc operandSize*(mode: AddressingMode, flags: FlagState): int =
  ## Operand size in bytes for an addressing mode under the given flag state.
  case mode:
  of amImplied, amAccumulator:
    0
  of amImmediateM:
    if flags.emulation or flags.m8: 1 else: 2
  of amImmediateX:
    if flags.emulation or flags.x8: 1 else: 2
  of amImmediate8, amDirectPage, amDirectPageX, amDirectPageY,
     amDpIndirect, amDpIndirectX, amDpIndirectY,
     amDpIndirectLong, amDpIndirectLongY,
     amStackRelative, amStackRelativeY, amRelative8:
    1
  of amAbsolute, amAbsoluteX, amAbsoluteY,
     amAbsIndirect, amAbsIndirectX, amAbsIndirectLong,
     amRelative16, amBlockMove:
    2
  of amAbsoluteLong, amAbsoluteLongX:
    3

proc initFlagState*(): FlagState =
  ## Flag state at CPU reset: emulation mode, 8-bit everything.
  FlagState(m8: true, x8: true, emulation: true)

proc applyInstruction*(flags: var FlagState, opcode: uint8, operand: uint32) =
  ## Track flag state changes from REP/SEP/XCE as code executes linearly.
  ## PLP and RTI can also change M/X but their effect is unknowable
  ## statically; callers needing precision must annotate those sites.
  case opcode:
  of 0xC2:  # REP: clear the given status bits.
    if (operand and 0x20) != 0: flags.m8 = false
    if (operand and 0x10) != 0: flags.x8 = false
  of 0xE2:  # SEP: set the given status bits.
    if (operand and 0x20) != 0: flags.m8 = true
    if (operand and 0x10) != 0: flags.x8 = true
  of 0xFB:  # XCE: assume the common CLC..XCE native-mode entry idiom.
    if flags.emulation:
      flags.emulation = false
      flags.m8 = true
      flags.x8 = true
  else:
    discard

proc findOpcode*(mnemonic: string, mode: AddressingMode): int =
  ## Find the opcode byte for a mnemonic + addressing mode pair.
  ## Returns -1 if no such combination exists.
  for opcode in 0..255:
    if OpcodeTable[opcode].mnemonic == mnemonic and
       OpcodeTable[opcode].mode == mode:
      return opcode
  result = -1
