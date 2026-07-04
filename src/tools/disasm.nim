## Disassembly tool for examining ROM code.
## Usage: nim r src/tools/disasm.nim <rom_file> <offset> [count] [--emu|--m8|--x8]
##   rom_file: path to ROM file
##   offset:   hex file offset (e.g. 0x8141)
##   count:    number of instructions to disassemble (default 100)
##   --emu:    start in emulation-mode flag state (reset entry)
##   --m8:     start with 8-bit accumulator
##   --x8:     start with 8-bit index registers

import
  std/[os, sets, strformat, strutils],
  ../decompbound/[assembler, disasm, memmap, opcodes]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc main() =
  var positional: seq[string]
  var flags = FlagState(m8: false, x8: false, emulation: false)
  for i in 1..paramCount():
    let arg = paramStr(i)
    case arg:
    of "--emu":
      flags = initFlagState()
    of "--m8":
      flags.m8 = true
    of "--x8":
      flags.x8 = true
    else:
      positional.add arg

  if positional.len < 2:
    echo "Usage: nim r src/tools/disasm.nim <rom_file> <offset> [count] [--emu|--m8|--x8]"
    quit(1)

  let romFile = positional[0]
  if not fileExists(romFile):
    stderr.writeLine &"Error: ROM file not found: {romFile}"
    quit(1)

  var offsetStr = positional[1]
  if offsetStr.startsWith("0x") or offsetStr.startsWith("0X"):
    offsetStr = offsetStr[2..^1]
  let offset = parseHexInt(offsetStr)

  var maxInstructions = 100
  if positional.len >= 3:
    maxInstructions = parseInt(positional[2])

  let romData = readRomFile(romFile)
  if offset >= romData.len:
    stderr.writeLine &"Error: Offset 0x{offset:06X} is beyond ROM size ({romData.len})"
    quit(1)

  let listing = disassemble(romData, offset, maxInstructions, flags)

  var labels = initHashSet[int]()
  for entry in listing:
    let target = branchTargetSnes(entry.instr, fileToSnes(entry.fileOffset))
    if target >= 0:
      let fileTarget = snesToFile(target.uint32)
      if fileTarget >= 0:
        labels.incl fileTarget

  echo &"Disassembling {romFile} from file offset 0x{offset:06X}"
  echo ""
  echo "SNES Addr  File Off  Bytes         Instruction"
  echo "---------  --------  ------------  --------------------"
  for entry in listing:
    if entry.fileOffset in labels:
      echo &"label_{entry.fileOffset:06X}:"
    var hexBytes = ""
    for i in 0..<entry.instr.size:
      hexBytes &= &"{romData[entry.fileOffset + i]:02X} "
    let snesAddr = fileToSnes(entry.fileOffset)
    let text = formatWithLabels(entry.instr, snesAddr, labels)
    echo &"${snesAddr:06X}    0x{entry.fileOffset:06X}  {hexBytes:12}  {text}"

when isMainModule:
  main()
