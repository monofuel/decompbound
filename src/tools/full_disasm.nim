## Full ROM disassembly tool.
## Traces control flow from the ROM's own interrupt vectors, classifies
## bytes as code/padding/unknown, and outputs an organized disassembly.
## Usage: nim r src/tools/full_disasm.nim <rom_file> [output_file]

import
  std/[os, sets, strformat, tables],
  ../decompbound/[assembler, disasm, memmap, opcodes]

const
  # Interrupt vector locations in bank 0 (file offsets in HiROM).
  NativeVectors = [
    ("COP", 0xFFE4), ("BRK", 0xFFE6), ("ABORT", 0xFFE8),
    ("NMI", 0xFFEA), ("IRQ", 0xFFEE)
  ]
  EmulationVectors = [
    ("COP", 0xFFF4), ("ABORT", 0xFFF8), ("NMI", 0xFFFA),
    ("RESET", 0xFFFC), ("IRQ/BRK", 0xFFFE)
  ]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc readVector(data: seq[uint8], fileOffset: int): int =
  ## Read a 16-bit interrupt vector and map it to a file offset.
  ## Vectors are bank-0 addresses; in HiROM the $8000+ half maps to ROM.
  let vec = data[fileOffset].int or (data[fileOffset + 1].int shl 8)
  result = snesToFile(vec.uint32)

proc groupRegions(analysis: RomAnalysis): seq[tuple[byteType: ByteType, start: int, last: int]] =
  ## Group contiguous byte classifications into regions.
  if analysis.byteTypes.len == 0:
    return
  var currentType = analysis.byteTypes[0]
  var regionStart = 0
  for i in 1..<analysis.byteTypes.len:
    if analysis.byteTypes[i] != currentType:
      result.add (byteType: currentType, start: regionStart, last: i - 1)
      currentType = analysis.byteTypes[i]
      regionStart = i
  result.add (byteType: currentType, start: regionStart,
              last: analysis.byteTypes.len - 1)

proc main() =
  if paramCount() < 1:
    echo "Usage: nim r src/tools/full_disasm.nim <rom_file> [output_file]"
    quit(1)

  let romFile = paramStr(1)
  if not fileExists(romFile):
    stderr.writeLine &"Error: ROM file not found: {romFile}"
    quit(1)

  var outputFile = stdout
  if paramCount() >= 2:
    outputFile = open(paramStr(2), fmWrite)

  let romData = readRomFile(romFile)

  # Seed the trace with the ROM's own interrupt vectors.
  var entryPoints: seq[int]
  outputFile.writeLine &"Full ROM disassembly: {romFile} ({romData.len} bytes)"
  outputFile.writeLine ""
  outputFile.writeLine "=== Entry points (from interrupt vectors) ==="
  for (name, vecOffset) in EmulationVectors:
    let target = readVector(romData, vecOffset)
    outputFile.writeLine &"  {name:8} (emu)    -> file 0x{target:06X}"
    if target >= 0 and target < romData.len:
      entryPoints.add target
  for (name, vecOffset) in NativeVectors:
    let target = readVector(romData, vecOffset)
    outputFile.writeLine &"  {name:8} (native) -> file 0x{target:06X}"
    if target >= 0 and target < romData.len:
      entryPoints.add target
  outputFile.writeLine ""

  stderr.writeLine "Tracing control flow from vectors..."
  proc progress(processed: int, queueSize: int) =
    stderr.writeLine &"  traced {processed} runs, queue {queueSize}"
  # The ROM header + vector table is data; stop traced runs there.
  let knownData = @[(start: 0xFFB0, last: 0xFFFF)]
  var analysis = analyzeControlFlow(romData, entryPoints, knownData, progress)
  detectPadding(romData, analysis)
  stderr.writeLine "Analysis complete."

  var counts: array[ByteType, int]
  for byteType in analysis.byteTypes:
    counts[byteType] += 1

  outputFile.writeLine "=== Statistics ==="
  for byteType in ByteType:
    let n = counts[byteType]
    outputFile.writeLine &"  {byteType:8} {n:8} bytes ({n.float * 100.0 / romData.len.float:5.2f}%)"
  outputFile.writeLine ""

  var labels = initHashSet[int]()
  for target in analysis.crossReferences.keys:
    labels.incl target

  let regions = groupRegions(analysis)
  var codeRegions = 0
  for region in regions:
    if region.byteType == Code:
      codeRegions += 1
  outputFile.writeLine &"=== Regions ({regions.len} total, {codeRegions} code) ==="
  outputFile.writeLine ""

  for region in regions:
    let size = region.last - region.start + 1
    case region.byteType:
    of Code:
      outputFile.writeLine &"--- CODE 0x{region.start:06X}-0x{region.last:06X} ({size} bytes) ---"
      let listing = disassemble(romData, region.start, high(int), initFlagState())
      for entry in listing:
        if entry.fileOffset > region.last:
          break
        if entry.fileOffset in labels:
          var xrefInfo = ""
          if entry.fileOffset in analysis.crossReferences:
            xrefInfo = "  ; from:"
            for xref in analysis.crossReferences[entry.fileOffset]:
              xrefInfo &= &" 0x{xref:06X}"
          outputFile.writeLine &"label_{entry.fileOffset:06X}:{xrefInfo}"
        let snesAddr = fileToSnes(entry.fileOffset)
        var hexBytes = ""
        for i in 0..<entry.instr.size:
          hexBytes &= &"{romData[entry.fileOffset + i]:02X} "
        let text = formatWithLabels(entry.instr, snesAddr, labels)
        outputFile.writeLine &"  ${snesAddr:06X}  {hexBytes:13} {text}"
      outputFile.writeLine ""
    of Padding:
      outputFile.writeLine &"--- PADDING 0x{region.start:06X}-0x{region.last:06X} ({size} bytes) ---"
      outputFile.writeLine ""
    of Data, Unknown:
      outputFile.writeLine &"--- {region.byteType} 0x{region.start:06X}-0x{region.last:06X} ({size} bytes) ---"
      outputFile.writeLine ""

  if outputFile != stdout:
    outputFile.close()
    stderr.writeLine &"Disassembly written to {paramStr(2)}"

when isMainModule:
  main()
