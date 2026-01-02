## Disassembly tool for examining ROM code.
## Usage: nim r src/tools/disasm.nim <rom_file> <offset> [length]

import
  std/[os, strformat, strutils],
  ../decompbound/disasm

proc isHeaderedRom(data: seq[uint8]): bool =
  ## Check if ROM has a 512-byte copier header.
  result = data.len > 512 and data[0x7FD5] == 0x00

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, handling headered/unheadered ROMs.
  let data = readFile(filepath)
  result = newSeq[uint8](data.len)
  for i in 0..<data.len:
    result[i] = data[i].uint8

proc main() =
  if paramCount() < 2:
    echo "Usage: nim r src/tools/disasm.nim <rom_file> <offset> [length]"
    echo "  rom_file: Path to ROM file"
    echo "  offset:   Hex offset (e.g., 0x8141 or 8141)"
    echo "  length:   Optional number of bytes to disassemble (default: 100 instructions)"
    quit(1)
  
  let romFile = paramStr(1)
  if not fileExists(romFile):
    stderr.writeLine &"Error: ROM file not found: {romFile}"
    quit(1)
  
  var offsetStr = paramStr(2)
  if offsetStr.startsWith("0x") or offsetStr.startsWith("0X"):
    offsetStr = offsetStr[2..^1]
  let offset = parseHexInt(offsetStr).uint32
  
  var maxInstructions = 100
  if paramCount() >= 3:
    maxInstructions = parseInt(paramStr(3))
  
  let romData = readRomFile(romFile)
  let isHeadered = isHeaderedRom(romData)
  
  var actualOffset = offset.int
  if isHeadered and offset < 512:
    stderr.writeLine "Warning: Offset is in header region, adjusting for headered ROM"
    actualOffset = offset.int + 512
  elif not isHeadered and offset >= 512:
    stderr.writeLine "Warning: Offset suggests unheadered ROM but may be incorrect"
  
  if actualOffset >= romData.len:
    stderr.writeLine &"Error: Offset {offset:06X} is beyond ROM size ({romData.len})"
    quit(1)
  
  echo &"Disassembling ROM: {romFile}"
  echo &"Offset: ${offset:06X} (file offset: {actualOffset:06X})"
  echo &"Headered: {isHeadered}"
  echo ""
  echo "Address    Bytes              Instruction"
  echo "--------   -----------------  --------------------"
  
  let instructions = disassemble(romData, actualOffset, maxInstructions)
  var currentOffset = actualOffset
  
  # Collect labels from instructions
  var labels: seq[uint32] = @[]
  for instr in instructions:
    if instr.opcode in ["JSR", "JSL", "JMP", "JML"]:
      labels.add(instr.operand.uint32)
    elif instr.mode in [Relative8, Relative16]:
      let target = if instr.mode == Relative8:
        (instr.address.int + 2 + instr.operand.int8.int) and 0xFFFF
      else:
        (instr.address.int + 3 + instr.operand.int16.int) and 0xFFFF
      labels.add(target.uint32)
  
  for instr in instructions:
    var hexBytes = ""
    for i in 0..<instr.size:
      if currentOffset + i < romData.len:
        hexBytes &= &"{romData[currentOffset + i]:02X} "
      else:
        hexBytes &= "?? "
    hexBytes = hexBytes.strip()
    
    let addrStr = &"${instr.address:06X}"
    let formatted = formatInstruction(instr, labels)
    echo &"{addrStr}    {hexBytes:18}  {formatted}"
    
    currentOffset += instr.size
    if currentOffset >= romData.len:
      break

when isMainModule:
  main()

