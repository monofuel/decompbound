# nim r src/analyze.nim
## Tool to analyze ROM structure and identify regions to implement.

import
  std/[os, strformat, strutils]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  HiRomHeaderOffset = 0xFFB0
  HeaderSize = 64

proc hexDump(data: string, startOffset: int, length: int) =
  ## Print a hex dump of the specified region.
  echo &"Hex dump from offset 0x{startOffset:06X} to 0x{startOffset + length - 1:06X}:"
  echo "  Offset   00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F"
  
  for i in 0..<length:
    let offset = startOffset + i
    if offset >= data.len:
      break
    
    if i mod 16 == 0:
      stdout.write &"  0x{offset:06X}  "
    
    stdout.write &"{data[offset].uint8:02X} "
    
    if i mod 16 == 15 or i == length - 1:
      echo ""

proc analyzePostHeader() =
  ## Analyze what comes immediately after the header.
  if not fileExists(GoldMasterRom):
    stderr.writeLine &"Gold master ROM not found: {GoldMasterRom}"
    quit(1)
  
  let romData = readFile(GoldMasterRom)
  let postHeaderStart = HiRomHeaderOffset + HeaderSize
  let analyzeLength = 256
  
  echo "Analyzing region immediately after header:"
  hexDump(romData, postHeaderStart, analyzeLength)
  
  echo ""
  echo "Looking for patterns..."
  
  var zeroRunStart = -1
  var zeroRunLength = 0
  var maxZeroRun = 0
  var maxZeroRunStart = 0
  
  for i in postHeaderStart..<min(postHeaderStart + analyzeLength, romData.len):
    if romData[i] == '\x00':
      if zeroRunStart == -1:
        zeroRunStart = i
        zeroRunLength = 1
      else:
        zeroRunLength += 1
    else:
      if zeroRunLength > maxZeroRun:
        maxZeroRun = zeroRunLength
        maxZeroRunStart = zeroRunStart
      zeroRunStart = -1
      zeroRunLength = 0
  
  if zeroRunLength > maxZeroRun:
    maxZeroRun = zeroRunLength
    maxZeroRunStart = zeroRunStart
  
  if maxZeroRun > 0:
    echo &"Longest zero run: {maxZeroRun} bytes starting at 0x{maxZeroRunStart:06X}"
  
  echo ""
  echo "Checking for interrupt vectors (typically at 0xFFE0-0xFFFF)..."
  let vectorStart = 0xFFE0
  if vectorStart < romData.len:
    hexDump(romData, vectorStart, 32)

when isMainModule:
  analyzePostHeader()

