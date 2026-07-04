## Table-driven 65816 disassembler and control-flow tracer.
## Instruction decoding derives from the shared opcode table (opcodes.nim)
## via assembler.nim, so the disassembler structurally cannot disagree with
## the assembler. Branch targets are resolved through the canonical HiROM
## mapping (memmap.nim).

import
  std/[sets, strformat, tables],
  ./[assembler, memmap, opcodes]

type
  ByteType* = enum
    Unknown
    Code
    Data
    Padding

  RomAnalysis* = object
    byteTypes*: seq[ByteType]
    entryPoints*: seq[int]  ## File offsets tracing started from.
    crossReferences*: Table[int, seq[int]]  ## File offset target -> sources.

  Disassembly* = object
    fileOffset*: int
    instr*: Instruction

const
  ReturnMnemonics = ["RTS", "RTL", "RTI"]
  CallMnemonics = ["JSR", "JSL"]
  JumpMnemonics = ["JMP", "JML", "BRA", "BRL"]
  BranchMnemonics = ["BPL", "BMI", "BVC", "BVS", "BCC", "BCS", "BNE", "BEQ"]

proc mnemonic*(instr: Instruction): string =
  ## The mnemonic for a decoded instruction, from the shared table.
  OpcodeTable[instr.opcode].mnemonic

proc mode*(instr: Instruction): AddressingMode =
  ## The addressing mode for a decoded instruction, from the shared table.
  OpcodeTable[instr.opcode].mode

proc isControlFlow*(instr: Instruction): bool =
  ## Whether the instruction changes control flow.
  let m = instr.mnemonic
  m in ReturnMnemonics or m in CallMnemonics or m in JumpMnemonics or
    m in BranchMnemonics

proc endsRun*(instr: Instruction): bool =
  ## Whether linear execution cannot continue past this instruction.
  let m = instr.mnemonic
  m in ReturnMnemonics or m in JumpMnemonics or m == "STP"

proc branchTargetSnes*(instr: Instruction, snesAddr: uint32): int64 =
  ## The SNES address a control-flow instruction transfers to, or -1 when
  ## there is no statically knowable target (returns, indirect jumps).
  ## snesAddr is the address of the instruction itself.
  let nextAddr = snesAddr + instr.size.uint32
  case instr.mode:
  of amRelative8:
    let delta = cast[int8](instr.operand.uint8).int64
    # Branches wrap within the current bank.
    (nextAddr.int64 and 0xFF0000) or ((nextAddr.int64 + delta) and 0xFFFF)
  of amRelative16:
    let delta = cast[int16]((instr.operand and 0xFFFF).uint16).int64
    (nextAddr.int64 and 0xFF0000) or ((nextAddr.int64 + delta) and 0xFFFF)
  of amAbsolute:
    if instr.mnemonic in ["JMP", "JSR"]:
      # Absolute jumps stay in the current program bank.
      (snesAddr.int64 and 0xFF0000) or instr.operand.int64
    else:
      -1
  of amAbsoluteLong:
    if instr.mnemonic in ["JML", "JSL"]:
      instr.operand.int64
    else:
      -1
  else:
    -1

proc formatWithLabels*(instr: Instruction, snesAddr: uint32,
                       labels: HashSet[int]): string =
  ## Format an instruction, substituting label names for branch targets
  ## that map to labeled file offsets.
  let target = branchTargetSnes(instr, snesAddr)
  if target >= 0:
    let fileTarget = snesToFile(target.uint32)
    if fileTarget >= 0 and fileTarget in labels:
      return &"{instr.mnemonic} label_{fileTarget:06X}"
  result = formatInstruction(instr)

proc disassemble*(data: openArray[uint8], fileOffset: int,
                  maxInstructions: int,
                  entryFlags: FlagState): seq[Disassembly] =
  ## Disassemble linearly from a file offset, tracking flag state.
  var offset = fileOffset
  var flags = entryFlags
  while offset < data.len and result.len < maxInstructions:
    let opSize = operandSize(OpcodeTable[data[offset]].mode, flags)
    if offset + 1 + opSize > data.len:
      break
    let instr = decode(data, offset, flags)
    result.add Disassembly(fileOffset: offset, instr: instr)
    flags.applyInstruction(instr.opcode, instr.operand)
    offset += instr.size

proc analyzeControlFlow*(data: openArray[uint8], entryPoints: seq[int],
                         dataRegions: seq[tuple[start: int, last: int]] = @[],
                         progressCallback: proc(processed: int, queueSize: int) = nil): RomAnalysis =
  ## Discover code regions by recursive descent from entry points.
  ## Entry points are file offsets, assumed to start in emulation-mode
  ## flag state unless discovered mid-trace (which inherit tracked state).
  ## dataRegions are known non-code ranges (the ROM header, declared data);
  ## traced runs stop at them and never mark them as code.
  ## Frontier honesty: indirect and computed jumps are not followed.
  result.byteTypes = newSeq[ByteType](data.len)
  result.entryPoints = entryPoints
  result.crossReferences = initTable[int, seq[int]]()

  for region in dataRegions:
    for i in region.start..min(region.last, data.len - 1):
      result.byteTypes[i] = Data

  var workQueue: seq[(int, FlagState)]
  var started = initHashSet[int]()
  var decodedStarts = initHashSet[int]()
  var processedCount = 0

  for ep in entryPoints:
    if ep >= 0 and ep < data.len and ep notin started:
      workQueue.add (ep, initFlagState())
      started.incl ep

  while workQueue.len > 0:
    let (startOffset, entryFlags) = workQueue.pop()
    var offset = startOffset
    var flags = entryFlags

    while offset < data.len:
      if offset in decodedStarts or result.byteTypes[offset] == Data:
        break
      let opSize = operandSize(OpcodeTable[data[offset]].mode, flags)
      if offset + 1 + opSize > data.len:
        break
      decodedStarts.incl offset
      let instr = decode(data, offset, flags)
      for i in 0..<instr.size:
        result.byteTypes[offset + i] = Code

      let target = branchTargetSnes(instr, fileToSnes(offset))
      if target >= 0:
        let fileTarget = snesToFile(target.uint32)
        if fileTarget >= 0 and fileTarget < data.len:
          if fileTarget notin result.crossReferences:
            result.crossReferences[fileTarget] = @[]
          result.crossReferences[fileTarget].add offset
          if fileTarget notin started:
            var targetFlags = flags
            targetFlags.applyInstruction(instr.opcode, instr.operand)
            workQueue.add (fileTarget, targetFlags)
            started.incl fileTarget

      if instr.endsRun:
        break
      flags.applyInstruction(instr.opcode, instr.operand)
      offset += instr.size

    processedCount += 1
    if progressCallback != nil and processedCount mod 100 == 0:
      progressCallback(processedCount, workQueue.len)

proc detectPadding*(data: openArray[uint8], analysis: var RomAnalysis,
                    minRunLength: int = 64) =
  ## Mark long runs of 0x00 or 0xFF in unknown regions as padding.
  ## Everything else stays Unknown: unknown is unknown, not "probably data".
  var i = 0
  while i < data.len:
    if analysis.byteTypes[i] == Unknown and (data[i] == 0x00 or data[i] == 0xFF):
      let fill = data[i]
      var runEnd = i
      while runEnd < data.len and data[runEnd] == fill and
            analysis.byteTypes[runEnd] == Unknown:
        inc runEnd
      if runEnd - i >= minRunLength:
        for j in i..<runEnd:
          analysis.byteTypes[j] = Padding
      i = runEnd
    else:
      inc i
