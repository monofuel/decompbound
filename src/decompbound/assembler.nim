## 65816 encoder/decoder pair derived from the shared opcode table.
## decode and encode are exact inverses: assemble(disassemble(bytes)) == bytes
## is the round-trip property that verifies both (see docs/goal-1.md).

import
  std/[strformat, strutils, tables],
  ./opcodes

type
  Instruction* = object
    opcode*: uint8
    operand*: uint32   ## Raw operand value, little-endian decoded.
    size*: int         ## Total size in bytes including the opcode.
    flags*: FlagState  ## Flag state under which this instruction was decoded.

  AsmNodeKind* = enum
    ankInstr
    ankLabel
    ankFlagHint

  AsmNode* = object
    case kind*: AsmNodeKind
    of ankInstr:
      mnemonic*: string
      mode*: AddressingMode
      value*: uint32
      target*: string  ## Label name; overrides value when non-empty.
    of ankLabel:
      name*: string
    of ankFlagHint:
      m8*: bool
      x8*: bool

proc decode*(data: openArray[uint8], offset: int, flags: FlagState): Instruction =
  ## Decode a single instruction at offset under the given flag state.
  let opcode = data[offset]
  let info = OpcodeTable[opcode]
  let opSize = operandSize(info.mode, flags)
  result.opcode = opcode
  result.size = 1 + opSize
  result.flags = flags
  result.operand = 0
  for i in 0..<opSize:
    result.operand = result.operand or (data[offset + 1 + i].uint32 shl (8 * i))

proc encode*(instr: Instruction): seq[uint8] =
  ## Encode a single instruction back to bytes. Exact inverse of decode.
  let info = OpcodeTable[instr.opcode]
  let opSize = operandSize(info.mode, instr.flags)
  result = newSeq[uint8](1 + opSize)
  result[0] = instr.opcode
  for i in 0..<opSize:
    result[1 + i] = ((instr.operand shr (8 * i)) and 0xFF).uint8

proc decodeStream*(data: openArray[uint8], start: int, len: int,
                   entryFlags: FlagState): seq[Instruction] =
  ## Decode a linear run of instructions, tracking M/X flag state through
  ## REP/SEP/XCE. Stops at the end of the range; a final instruction whose
  ## operand would cross the range boundary raises IndexDefect naturally.
  var offset = start
  var flags = entryFlags
  while offset < start + len:
    let instr = decode(data, offset, flags)
    result.add instr
    flags.applyInstruction(instr.opcode, instr.operand)
    offset += instr.size

proc encodeStream*(instrs: seq[Instruction]): seq[uint8] =
  ## Re-encode a decoded instruction stream back to bytes.
  for instr in instrs:
    result.add encode(instr)

proc decodeRange*(data: openArray[uint8], start: int, maxLen: int,
                  entryFlags: FlagState): tuple[instrs: seq[Instruction], covered: int] =
  ## Decode linearly like decodeStream, but stop cleanly before an
  ## instruction whose operand would cross the range end. Returns the
  ## instructions and how many bytes they cover.
  var offset = start
  var flags = entryFlags
  while offset < start + maxLen:
    let opSize = operandSize(OpcodeTable[data[offset]].mode, flags)
    if offset + 1 + opSize > start + maxLen:
      break
    let instr = decode(data, offset, flags)
    result.instrs.add instr
    flags.applyInstruction(instr.opcode, instr.operand)
    offset += instr.size
  result.covered = offset - start

proc formatInstruction*(instr: Instruction): string =
  ## Format an instruction as human-readable assembly text.
  let info = OpcodeTable[instr.opcode]
  let op = instr.operand
  case info.mode:
  of amImplied:
    info.mnemonic
  of amAccumulator:
    &"{info.mnemonic} A"
  of amImmediateM, amImmediateX:
    if instr.size == 2:
      &"{info.mnemonic} #${op:02X}"
    else:
      &"{info.mnemonic} #${op:04X}"
  of amImmediate8:
    &"{info.mnemonic} #${op:02X}"
  of amDirectPage:
    &"{info.mnemonic} ${op:02X}"
  of amDirectPageX:
    &"{info.mnemonic} ${op:02X},X"
  of amDirectPageY:
    &"{info.mnemonic} ${op:02X},Y"
  of amDpIndirect:
    &"{info.mnemonic} (${op:02X})"
  of amDpIndirectX:
    &"{info.mnemonic} (${op:02X},X)"
  of amDpIndirectY:
    &"{info.mnemonic} (${op:02X}),Y"
  of amDpIndirectLong:
    &"{info.mnemonic} [${op:02X}]"
  of amDpIndirectLongY:
    &"{info.mnemonic} [${op:02X}],Y"
  of amAbsolute:
    &"{info.mnemonic} ${op:04X}"
  of amAbsoluteX:
    &"{info.mnemonic} ${op:04X},X"
  of amAbsoluteY:
    &"{info.mnemonic} ${op:04X},Y"
  of amAbsoluteLong:
    &"{info.mnemonic} ${op:06X}"
  of amAbsoluteLongX:
    &"{info.mnemonic} ${op:06X},X"
  of amAbsIndirect:
    &"{info.mnemonic} (${op:04X})"
  of amAbsIndirectX:
    &"{info.mnemonic} (${op:04X},X)"
  of amAbsIndirectLong:
    &"{info.mnemonic} [${op:04X}]"
  of amStackRelative:
    &"{info.mnemonic} ${op:02X},S"
  of amStackRelativeY:
    &"{info.mnemonic} (${op:02X},S),Y"
  of amRelative8:
    &"{info.mnemonic} {cast[int8](op.uint8):+d}"
  of amRelative16:
    &"{info.mnemonic} {cast[int16]((op and 0xFFFF).uint16):+d}"
  of amBlockMove:
    &"{info.mnemonic} ${op and 0xFF:02X},${(op shr 8) and 0xFF:02X}"

proc instr*(mnemonic: string, mode: AddressingMode, value: uint32 = 0): AsmNode =
  ## Build an instruction node for the program assembler.
  AsmNode(kind: ankInstr, mnemonic: mnemonic, mode: mode, value: value, target: "")

proc instrTo*(mnemonic: string, mode: AddressingMode, target: string): AsmNode =
  ## Build an instruction node that references a label.
  AsmNode(kind: ankInstr, mnemonic: mnemonic, mode: mode, value: 0, target: target)

proc label*(name: string): AsmNode =
  ## Build a label definition node.
  AsmNode(kind: ankLabel, name: name)

proc flagHint*(m8: bool, x8: bool): AsmNode =
  ## Build an explicit flag state annotation, for entry points and sites
  ## where flag state cannot be derived statically (after PLP, RTI).
  AsmNode(kind: ankFlagHint, m8: m8, x8: x8)

proc nodeSize(node: AsmNode, flags: FlagState): int =
  ## Size in bytes a node will occupy under the given flag state.
  if node.kind != ankInstr:
    return 0
  let opcode = findOpcode(node.mnemonic, node.mode)
  if opcode < 0:
    raise newException(ValueError,
      &"No opcode for {node.mnemonic} with mode {node.mode}")
  result = 1 + operandSize(node.mode, flags)

proc trackNode(flags: var FlagState, node: AsmNode) =
  ## Advance tracked flag state across a node.
  case node.kind:
  of ankFlagHint:
    flags.m8 = node.m8
    flags.x8 = node.x8
    flags.emulation = false
  of ankInstr:
    let opcode = findOpcode(node.mnemonic, node.mode)
    flags.applyInstruction(opcode.uint8, node.value)
  of ankLabel:
    discard

proc assemble*(nodes: seq[AsmNode], origin: uint32,
               entryFlags: FlagState): seq[uint8] =
  ## Two-pass assembler: resolve label addresses, then emit bytes.
  ## origin is the address of the first byte (used for label targets and
  ## relative branch resolution; address space is the caller's choice, it
  ## just needs to be consistent).
  var labels = initTable[string, uint32]()
  var flags = entryFlags
  var address = origin

  for node in nodes:
    if node.kind == ankLabel:
      labels[node.name] = address
    address += nodeSize(node, flags).uint32
    flags.trackNode(node)

  flags = entryFlags
  address = origin
  for node in nodes:
    if node.kind == ankInstr:
      let opcode = findOpcode(node.mnemonic, node.mode)
      let size = nodeSize(node, flags)
      var value = node.value
      if node.target.len > 0:
        if node.target notin labels:
          raise newException(ValueError, &"Undefined label: {node.target}")
        let targetAddr = labels[node.target]
        case node.mode:
        of amRelative8:
          let delta = targetAddr.int64 - (address.int64 + size)
          if delta < -128 or delta > 127:
            raise newException(ValueError,
              &"Branch to {node.target} out of range: {delta}")
          value = cast[uint8](delta.int8).uint32
        of amRelative16:
          let delta = targetAddr.int64 - (address.int64 + size)
          value = cast[uint16](delta.int16).uint32
        of amAbsolute, amAbsIndirect, amAbsIndirectX:
          value = targetAddr and 0xFFFF
        of amAbsoluteLong:
          value = targetAddr and 0xFFFFFF
        else:
          raise newException(ValueError,
            &"Label target not supported for mode {node.mode}")
      result.add encode(Instruction(
        opcode: opcode.uint8, operand: value, size: size, flags: flags))
    address += nodeSize(node, flags).uint32
    flags.trackNode(node)
