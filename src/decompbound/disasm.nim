## Disassembler for 65816 assembly.
## Converts ROM bytes into readable assembly instructions.

import
  std/[strformat, strutils]

type
  AddressingMode* = enum
    Implied
    Accumulator
    Immediate8
    Immediate16
    Absolute
    AbsoluteLong
    DirectPage
    DirectPageIndexedX
    DirectPageIndexedY
    AbsoluteIndexedX
    AbsoluteIndexedY
    AbsoluteLongIndexedX
    Indirect
    IndirectLong
    IndirectIndexedY
    IndirectLongIndexedY
    DirectPageIndirect
    DirectPageIndirectLong
    DirectPageIndirectIndexedY
    DirectPageIndirectLongIndexedY
    Relative8
    Relative16
    BlockMove
  
  Instruction* = object
    opcode*: string
    mode*: AddressingMode
    operand*: uint32
    operand2*: uint32
    size*: int
    address*: uint32
  
  DisasmState = object
    accumulator8Bit: bool
    index8Bit: bool
    labels: seq[uint32]

proc formatAddress(`addr`: uint32): string =
  ## Format address as hex with $ prefix.
  result = &"${`addr`:04X}"

proc formatAddressLong(`addr`: uint32): string =
  ## Format address as long hex with $ prefix.
  result = &"${`addr`:06X}"

proc formatOperand(mode: AddressingMode, operand: uint32, operand2: uint32 = 0, `address`: uint32 = 0): string =
  ## Format operand based on addressing mode.
  case mode:
  of Implied, Accumulator:
    result = ""
  of Immediate8:
    result = &"#${operand:02X}"
  of Immediate16:
    result = &"#${operand:04X}"
  of Absolute:
    result = formatAddress(operand.uint16)
  of AbsoluteLong:
    result = formatAddressLong(operand)
  of DirectPage:
    result = &"${operand:02X}"
  of DirectPageIndexedX:
    result = &"${operand:02X},X"
  of DirectPageIndexedY:
    result = &"${operand:02X},Y"
  of AbsoluteIndexedX:
    result = &"{formatAddress(operand.uint16)},X"
  of AbsoluteIndexedY:
    result = &"{formatAddress(operand.uint16)},Y"
  of AbsoluteLongIndexedX:
    result = &"{formatAddressLong(operand)},X"
  of Indirect:
    result = &"({formatAddress(operand.uint16)})"
  of IndirectLong:
    result = &"[{formatAddress(operand.uint16)}]"
  of IndirectIndexedY:
    result = &"({formatAddress(operand.uint16)}),Y"
  of IndirectLongIndexedY:
    result = &"[{formatAddress(operand.uint16)}],Y"
  of DirectPageIndirect:
    result = &"(${operand:02X})"
  of DirectPageIndirectLong:
    result = &"[${operand:02X}]"
  of DirectPageIndirectIndexedY:
    result = &"(${operand:02X}),Y"
  of DirectPageIndirectLongIndexedY:
    result = &"[${operand:02X}],Y"
  of Relative8:
    let target = (`address`.int + 2 + operand.int8.int) and 0xFFFF
    result = formatAddress(target.uint16)
  of Relative16:
    let target = (`address`.int + 3 + operand.int16.int) and 0xFFFF
    result = formatAddress(target.uint16)
  of BlockMove:
    result = &"${operand:02X},${operand2:02X}"

proc disassembleInstruction(data: seq[uint8], offset: int, state: var DisasmState): Instruction =
  ## Disassemble a single instruction at the given offset.
  if offset >= data.len:
    return Instruction(opcode: "???", mode: Implied, size: 1, address: offset.uint32)
  
  let opcode = data[offset]
  var size = 1
  var mode = Implied
  var operand: uint32 = 0
  var operand2: uint32 = 0
  
  case opcode:
  # Single byte instructions
  of 0x00: result.opcode = "BRK"; mode = Implied
  of 0x08: result.opcode = "PHP"; mode = Implied
  of 0x0B: result.opcode = "PHD"; mode = Implied
  of 0x18: result.opcode = "CLC"; mode = Implied
  of 0x1A: result.opcode = "INC"; mode = Accumulator
  of 0x28: result.opcode = "PLP"; mode = Implied
  of 0x2A: result.opcode = "ROL"; mode = Accumulator
  of 0x2B: result.opcode = "PLD"; mode = Implied
  of 0x38: result.opcode = "SEC"; mode = Implied
  of 0x3A: result.opcode = "DEC"; mode = Accumulator
  of 0x40: result.opcode = "RTI"; mode = Implied
  of 0x48: result.opcode = "PHA"; mode = Implied
  of 0x4A: result.opcode = "LSR"; mode = Accumulator
  of 0x58: result.opcode = "CLI"; mode = Implied
  of 0x5A: result.opcode = "PHY"; mode = Implied
  of 0x5B: result.opcode = "TCD"; mode = Implied
  of 0x60: result.opcode = "RTS"; mode = Implied
  of 0x68: result.opcode = "PLA"; mode = Implied
  of 0x6A: result.opcode = "ROR"; mode = Accumulator
  of 0x6B: result.opcode = "RTL"; mode = Implied
  of 0x78: result.opcode = "SEI"; mode = Implied
  of 0x7A: result.opcode = "PLY"; mode = Implied
  of 0x7B: result.opcode = "TDC"; mode = Implied
  of 0x88: result.opcode = "DEY"; mode = Implied
  of 0x8A: result.opcode = "TXA"; mode = Implied
  of 0x8B: result.opcode = "PHB"; mode = Implied
  of 0x98: result.opcode = "TYA"; mode = Implied
  of 0x9A: result.opcode = "TXS"; mode = Implied
  of 0x9B: result.opcode = "TXY"; mode = Implied
  of 0xA8: result.opcode = "TAY"; mode = Implied
  of 0xAA: result.opcode = "TAX"; mode = Implied
  of 0xAB: result.opcode = "PLB"; mode = Implied
  of 0xB8: result.opcode = "CLV"; mode = Implied
  of 0xBA: result.opcode = "TSX"; mode = Implied
  of 0xBB: result.opcode = "TYX"; mode = Implied
  of 0xC8: result.opcode = "INY"; mode = Implied
  of 0xCA: result.opcode = "DEX"; mode = Implied
  of 0xCB: result.opcode = "WAI"; mode = Implied
  of 0xD8: result.opcode = "CLD"; mode = Implied
  of 0xDA: result.opcode = "PHX"; mode = Implied
  of 0xDB: result.opcode = "STP"; mode = Implied
  of 0xE8: result.opcode = "INX"; mode = Implied
  of 0xEA: result.opcode = "NOP"; mode = Implied
  of 0xEB: result.opcode = "XBA"; mode = Implied
  of 0xF4:
    result.opcode = "PEA"
    mode = Immediate16
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xF8: result.opcode = "SED"; mode = Implied
  of 0xFA: result.opcode = "PLX"; mode = Implied
  of 0xFB: result.opcode = "XCE"; mode = Implied
  of 0xFC:
    result.opcode = "JSR"
    mode = AbsoluteIndexedX
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # LDA instructions
  of 0xA9:
    result.opcode = "LDA"
    if state.accumulator8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xA5:
    result.opcode = "LDA"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0xAD:
      result.opcode = "LDA"
      mode = Absolute
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xAF:
    result.opcode = "LDA"
    mode = AbsoluteLong
    size = 4
    if offset + 3 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8) or (data[offset + 3].uint32 shl 16)
  of 0xA7:
    result.opcode = "LDA"
    mode = DirectPageIndirectLong
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0xB7:
    result.opcode = "LDA"
    mode = DirectPageIndirectLongIndexedY
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0xBD:
    result.opcode = "LDA"
    mode = AbsoluteIndexedX
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xBF:
    result.opcode = "LDA"
    mode = AbsoluteLongIndexedX
    size = 4
    if offset + 3 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8) or (data[offset + 3].uint32 shl 16)
  
  # STA instructions
  of 0x85:
    result.opcode = "STA"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0x8D:
    result.opcode = "STA"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0x8F:
    result.opcode = "STA"
    mode = AbsoluteLong
    size = 4
    if offset + 3 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8) or (data[offset + 3].uint32 shl 16)
  of 0x9D:
    result.opcode = "STA"
    mode = AbsoluteIndexedX
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0x91:
    result.opcode = "STA"
    mode = DirectPageIndirectIndexedY
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  
  # STZ instructions
  of 0x64:
    result.opcode = "STZ"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0x9C:
    result.opcode = "STZ"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # LDX instructions
  of 0xA2:
    result.opcode = "LDX"
    if state.index8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xA6:
    result.opcode = "LDX"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0xAE:
    result.opcode = "LDX"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # LDY instructions
  of 0xA0:
    result.opcode = "LDY"
    if state.index8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xA4:
    result.opcode = "LDY"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0xAC:
    result.opcode = "LDY"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xBC:
    result.opcode = "LDY"
    mode = AbsoluteIndexedX
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # STX instructions
  of 0x86:
    result.opcode = "STX"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0x8E:
    result.opcode = "STX"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # STY instructions
  of 0x84:
    result.opcode = "STY"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0x8C:
    result.opcode = "STY"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # JSR instructions
  of 0x20:
    result.opcode = "JSR"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
      state.labels.add(operand.uint32)
  
  # JSL instructions
  of 0x22:
    result.opcode = "JSL"
    mode = AbsoluteLong
    size = 4
    if offset + 3 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8) or (data[offset + 3].uint32 shl 16)
      state.labels.add(operand.uint32)
  
  # JMP instructions
  of 0x4C:
    result.opcode = "JMP"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
      state.labels.add(operand.uint32)
  
  # JML instructions
  of 0x5C:
    result.opcode = "JML"
    mode = AbsoluteLong
    size = 4
    if offset + 3 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8) or (data[offset + 3].uint32 shl 16)
      state.labels.add(operand.uint32)
  
  # Branch instructions
  of 0x10:
    result.opcode = "BPL"
    mode = Relative8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0x30:
    result.opcode = "BMI"
    mode = Relative8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0x50:
    result.opcode = "BVC"
    mode = Relative8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0x70:
    result.opcode = "BVS"
    mode = Relative8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0x80:
    result.opcode = "BRA"
    mode = Relative8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0x90:
    result.opcode = "BCC"
    mode = Relative8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0xB0:
    result.opcode = "BCS"
    mode = Relative8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0xD0:
    result.opcode = "BNE"
    mode = Relative8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0xF0:
    result.opcode = "BEQ"
    mode = Relative8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  
  # Arithmetic operations
  of 0x65:
    result.opcode = "ADC"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0x69:
    result.opcode = "ADC"
    if state.accumulator8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0x6D:
    result.opcode = "ADC"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # CMP instructions
  of 0xC5:
    result.opcode = "CMP"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0xC9:
    result.opcode = "CMP"
    if state.accumulator8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xCD:
    result.opcode = "CMP"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xCF:
    result.opcode = "CMP"
    mode = AbsoluteLong
    size = 4
    if offset + 3 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8) or (data[offset + 3].uint32 shl 16)
  of 0xC0:
    result.opcode = "CPY"
    if state.index8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xE4:
    result.opcode = "CPX"
    if state.index8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0xE0:
    result.opcode = "CPX"
    if state.index8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # AND instructions
  of 0x29:
    result.opcode = "AND"
    if state.accumulator8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  of 0x25:
    result.opcode = "AND"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  
  # ORA instructions
  of 0x09:
    result.opcode = "ORA"
    if state.accumulator8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # EOR instructions
  of 0x49:
    result.opcode = "EOR"
    if state.accumulator8Bit:
      mode = Immediate8
      size = 2
      if offset + 1 < data.len:
        operand = data[offset + 1].uint32
    else:
      mode = Immediate16
      size = 3
      if offset + 2 < data.len:
        operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # INC instructions
  of 0xE6:
    result.opcode = "INC"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  of 0xEE:
    result.opcode = "INC"
    mode = Absolute
    size = 3
    if offset + 2 < data.len:
      operand = (data[offset + 1].uint32) or (data[offset + 2].uint32 shl 8)
  
  # DEC instructions
  of 0xC6:
    result.opcode = "DEC"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  
  # REP/SEP instructions
  of 0xC2:
    result.opcode = "REP"
    mode = Immediate8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
      if (operand and 0x20) == 0:
        state.accumulator8Bit = false
      if (operand and 0x10) == 0:
        state.index8Bit = false
  of 0xE2:
    result.opcode = "SEP"
    mode = Immediate8
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
      if (operand and 0x20) != 0:
        state.accumulator8Bit = true
      if (operand and 0x10) != 0:
        state.index8Bit = true
  
  # ASL instructions
  of 0x0A:
    result.opcode = "ASL"
    mode = Accumulator
  of 0x06:
    result.opcode = "ASL"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  
  # LSR instructions (0x4A already handled as Accumulator mode above)
  of 0x46:
    result.opcode = "LSR"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  
  # ROL instructions (0x2A already handled as Accumulator mode above)
  of 0x26:
    result.opcode = "ROL"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  
  # ROR instructions (0x6A already handled as Accumulator mode above)
  of 0x66:
    result.opcode = "ROR"
    mode = DirectPage
    size = 2
    if offset + 1 < data.len:
      operand = data[offset + 1].uint32
  
  else:
    result.opcode = &"???(${opcode:02X})"
    mode = Implied
    size = 1
  
  result.mode = mode
  result.operand = operand
  result.operand2 = operand2
  result.size = size
  result.address = offset.uint32

proc formatInstruction*(instr: Instruction, labels: seq[uint32] = @[]): string =
  ## Format an instruction as a string.
  let operandStr = formatOperand(instr.mode, instr.operand, instr.operand2, instr.address)
  
  # Check if this address is a label target
  var labelName = ""
  for i, labelAddr in labels:
    if labelAddr == instr.address:
      labelName = &"label_{labelAddr:04X}:"
      break
  
  if operandStr.len > 0:
    result = &"{instr.opcode} {operandStr}"
  else:
    result = instr.opcode
  
  if labelName.len > 0:
    result = &"{labelName} {result}"

proc disassemble*(data: seq[uint8], startOffset: int = 0, maxInstructions: int = 100): seq[Instruction] =
  ## Disassemble a sequence of bytes into instructions.
  var state = DisasmState(accumulator8Bit: false, index8Bit: false)
  var offset = startOffset
  var count = 0
  
  # First pass: collect all labels
  while offset < data.len and count < maxInstructions:
    let instr = disassembleInstruction(data, offset, state)
    offset += instr.size
    count += 1
  
  # Second pass: actually disassemble with label context
  state = DisasmState(accumulator8Bit: false, index8Bit: false)
  offset = startOffset
  count = 0
  
  while offset < data.len and count < maxInstructions:
    let instr = disassembleInstruction(data, offset, state)
    result.add(instr)
    offset += instr.size
    count += 1

