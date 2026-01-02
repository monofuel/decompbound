## Full ROM disassembly tool.
## Analyzes entire ROM, distinguishes code from data, and outputs organized disassembly.
## Usage: nim r src/tools/full_disasm.nim <rom_file> [output_file]

import
  std/[os, strformat, strutils, tables, parseopt],
  ../decompbound/[common, disasm]

proc isHeaderedRom(data: seq[uint8]): bool =
  ## Check if ROM has a 512-byte copier header.
  result = data.len > 512 and data[0x7FD5] == 0x00

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, handling headered/unheadered ROMs.
  let data = readFile(filepath)
  result = newSeq[uint8](data.len)
  for i in 0..<data.len:
    result[i] = data[i].uint8

proc getKnownCodeRegions(): seq[tuple[start: int, `end`: int]] =
  ## Get known code regions from implemented regions.
  result = @[
    (start: HiRomHeaderOffset.int, `end`: (HiRomHeaderOffset + HeaderSize - 1).int),
    (start: ResetVectorOffset.int, `end`: (ResetVectorOffset + ResetVectorSize - 1).int),
    (start: InitCodeOffset.int, `end`: (InitCodeOffset + InitCodeSize - 1).int),
    (start: ResetHandlerOffset.int, `end`: (ResetHandlerOffset + ResetHandlerSize - 1).int),
    (start: BrkHandlerOffset.int, `end`: (BrkHandlerOffset + BrkHandlerSize - 1).int),
    (start: EarlySubroutineOffset.int, `end`: (EarlySubroutineOffset + EarlySubroutineSize - 1).int)
  ]

proc getEntryPoints(): seq[uint32] =
  ## Get known entry points (reset vectors, interrupt vectors).
  result = @[
    ResetVectorOffset.uint32,
    InitCodeOffset.uint32,
    ResetHandlerOffset.uint32,
    BrkHandlerOffset.uint32,
    EarlySubroutineOffset.uint32
  ]
  
  # Add interrupt vectors from header
  result.add(0xFFE4.uint32)  # COP vector
  result.add(0xFFE6.uint32)  # BRK vector
  result.add(0xFFE8.uint32)  # ABORT vector
  result.add(0xFFEA.uint32)  # NMI vector
  result.add(0xFFEC.uint32)  # RESET vector
  result.add(0xFFEE.uint32)  # IRQ vector

proc formatHexDump(data: seq[uint8], start: int, length: int): string =
  ## Format a hex dump of data bytes.
  result = ""
  for i in 0..<length:
    if start + i < data.len:
      result &= &"{data[start + i]:02X} "
    else:
      result &= "?? "
  result = result.strip()

proc groupRegions(analysis: RomAnalysis, data: seq[uint8]): seq[tuple[`type`: ByteType, start: int, `end`: int]] =
  ## Group contiguous regions of the same type.
  if analysis.byteTypes.len == 0:
    return
  
  var currentType = analysis.byteTypes[0]
  var regionStart = 0
  
  for i in 1..<analysis.byteTypes.len:
    if analysis.byteTypes[i] != currentType:
      if regionStart < i:
        result.add((`type`: currentType, start: regionStart, `end`: i - 1))
      currentType = analysis.byteTypes[i]
      regionStart = i
  
  if regionStart < analysis.byteTypes.len:
    result.add((`type`: currentType, start: regionStart, `end`: analysis.byteTypes.len - 1))

proc parseHexAddress(s: string): int =
  ## Parse a hex address string (with or without 0x prefix).
  var addrStr = s
  if addrStr.startsWith("0x") or addrStr.startsWith("0X"):
    addrStr = addrStr[2..^1]
  result = parseHexInt(addrStr)

proc main() =
  var romFile = ""
  var outputPath = ""
  var startAddr = -1
  var endAddr = -1
  var maxQueueSize = 5000
  
  var p = initOptParser()
  for kind, key, val in p.getOpt():
    case kind:
    of cmdLongOption, cmdShortOption:
      case key:
      of "start-addr", "s":
        var addrVal = val
        if addrVal.len == 0:
          stderr.writeLine "Error: --start-addr requires a value (use --start-addr=0x10000 or --start-addr 0x10000)"
          quit(1)
        startAddr = parseHexAddress(addrVal)
      of "end-addr", "e":
        var addrVal = val
        if addrVal.len == 0:
          stderr.writeLine "Error: --end-addr requires a value (use --end-addr=0x20000 or --end-addr 0x20000)"
          quit(1)
        endAddr = parseHexAddress(addrVal)
      of "max-queue", "q":
        var queueVal = val
        if queueVal.len == 0:
          stderr.writeLine "Error: --max-queue requires a value"
          quit(1)
        maxQueueSize = parseInt(queueVal)
      else:
        stderr.writeLine &"Error: Unknown option: {key}"
        quit(1)
    of cmdArgument:
      if romFile.len == 0:
        romFile = key
      elif outputPath.len == 0:
        outputPath = key
      else:
        stderr.writeLine "Error: Too many arguments"
        quit(1)
    of cmdEnd:
      discard
  
  if romFile.len == 0:
    echo "Usage: nim r src/tools/full_disasm.nim [options] <rom_file> [output_file]"
    echo ""
    echo "Options:"
    echo "  --start-addr, -s <hex>  Start address for analysis (hex, e.g. 0x10000)"
    echo "  --end-addr, -e <hex>    End address for analysis (hex, e.g. 0x20000)"
    echo "  --max-queue, -q <int>   Maximum work queue size (default: 5000)"
    echo ""
    echo "Arguments:"
    echo "  rom_file:    Path to ROM file"
    echo "  output_file: Optional output file (default: stdout)"
    quit(1)
  
  if not fileExists(romFile):
    stderr.writeLine &"Error: ROM file not found: {romFile}"
    quit(1)
  
  var outputFile: File = nil
  if outputPath.len > 0:
    outputFile = open(outputPath, fmWrite)
  else:
    outputFile = stdout
  
  var romData = readRomFile(romFile)
  let isHeadered = isHeaderedRom(romData)
  
  # Apply address range limits if specified
  if startAddr >= 0 or endAddr >= 0:
    let start = if startAddr >= 0: startAddr else: 0
    let `end` = if endAddr >= 0: endAddr else: romData.len - 1
    if start < 0 or `end` >= romData.len or start > `end`:
      stderr.writeLine &"Error: Invalid address range: ${start:06X}-${`end`:06X}"
      quit(1)
    romData = romData[start..`end`]
    stderr.writeLine &"Limiting analysis to range: ${start:06X}-${`end`:06X}"
  
  outputFile.writeLine &"Full ROM Disassembly: {romFile}"
  outputFile.writeLine &"ROM Size: {romData.len} bytes ({romData.len / 1024 / 1024:.2f} MB)"
  outputFile.writeLine &"Headered: {isHeadered}"
  outputFile.writeLine ""
  
  let knownCodeRegions = getKnownCodeRegions()
  let entryPoints = getEntryPoints()
  
  outputFile.writeLine "Analyzing ROM structure..."
  outputFile.writeLine &"Entry points: {entryPoints.len}"
  outputFile.writeLine &"Known code regions: {knownCodeRegions.len}"
  outputFile.writeLine ""
  
  stderr.writeLine "Starting control flow analysis..."
  proc progressCallback(processed: int, queueSize: int) =
    stderr.writeLine &"Progress: processed {processed} addresses, queue size: {queueSize}"
  var analysis = analyzeControlFlow(romData, entryPoints, knownCodeRegions, maxQueueSize, progressCallback)
  
  stderr.writeLine "Detecting data regions..."
  detectDataRegions(romData, analysis)
  stderr.writeLine "Analysis complete."
  
  # Calculate statistics
  var codeBytes = 0
  var dataBytes = 0
  var paddingBytes = 0
  var unknownBytes = 0
  
  for byteType in analysis.byteTypes:
    case byteType:
    of Code: codeBytes += 1
    of Data: dataBytes += 1
    of Padding: paddingBytes += 1
    of Unknown: unknownBytes += 1
  
  outputFile.writeLine "=== Statistics ==="
  outputFile.writeLine &"Code:     {codeBytes:8} bytes ({codeBytes.float * 100.0 / romData.len.float:5.2f}%)"
  outputFile.writeLine &"Data:     {dataBytes:8} bytes ({dataBytes.float * 100.0 / romData.len.float:5.2f}%)"
  outputFile.writeLine &"Padding:  {paddingBytes:8} bytes ({paddingBytes.float * 100.0 / romData.len.float:5.2f}%)"
  outputFile.writeLine &"Unknown:  {unknownBytes:8} bytes ({unknownBytes.float * 100.0 / romData.len.float:5.2f}%)"
  outputFile.writeLine &"Total:    {romData.len:8} bytes (100.00%)"
  outputFile.writeLine ""
  outputFile.writeLine &"Code regions discovered: {analysis.codeAddresses.len} addresses"
  outputFile.writeLine &"Data regions discovered: {analysis.dataAddresses.len} addresses"
  outputFile.writeLine ""
  
  # Group regions
  let regions = groupRegions(analysis, romData)
  outputFile.writeLine &"=== Regions ({regions.len} total) ==="
  outputFile.writeLine ""
  
  # Output regions
  for region in regions:
    let regionSize = region.`end` - region.start + 1
    let typeStr = case region.`type`:
      of Code: "CODE"
      of Data: "DATA"
      of Padding: "PADDING"
      of Unknown: "UNKNOWN"
    
    outputFile.writeLine &"--- {typeStr} Region: ${region.start:06X}-${region.`end`:06X} ({regionSize} bytes) ---"
    
    if region.`type` == Code:
      # Disassemble code region
      let instructions = disassemble(romData, region.start, regionSize)
      var currentOffset = region.start
      
      for instr in instructions:
        if currentOffset >= region.`end`:
          break
        
        var hexBytes = formatHexDump(romData, currentOffset, instr.size)
        let addrStr = &"${instr.address:06X}"
        let formatted = formatInstruction(instr, analysis.entryPoints)
        
        # Add cross-reference info if available
        var xrefInfo = ""
        if analysis.crossReferences.hasKey(instr.address):
          let xrefs = analysis.crossReferences[instr.address]
          if xrefs.len > 0:
            xrefInfo = &"  ; called from: "
            for idx, xref in xrefs:
              if idx > 0:
                xrefInfo &= ", "
              xrefInfo &= &"${xref:06X}"
        
        outputFile.writeLine &"{addrStr}    {hexBytes:18}  {formatted}{xrefInfo}"
        currentOffset += instr.size
    elif region.`type` == Data:
      # Hex dump for data
      for i in 0..<regionSize:
        if i mod 16 == 0:
          outputFile.write &"  ${region.start + i:06X}:  "
        outputFile.write &"{romData[region.start + i]:02X} "
        if i mod 16 == 15 or i == regionSize - 1:
          outputFile.writeLine ""
    elif region.`type` == Padding:
      outputFile.writeLine &"  (Zero padding: {regionSize} bytes)"
    else:
      outputFile.writeLine &"  (Unknown: {regionSize} bytes)"
    
    outputFile.writeLine ""
  
  if outputFile != stdout:
    outputFile.close()
    echo &"Disassembly written to {paramStr(2)}"

when isMainModule:
  main()

