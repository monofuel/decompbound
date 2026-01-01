## Public interface for the decompbound decompilation project.
# nim r src/decompbound.nim

import
  std/[os, strformat]

const
  outputRom = "bin/Decompbound.smc"
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  HiRomHeaderOffset = 0xFFB0
  HeaderSize = 64
  MinRomSize = HiRomHeaderOffset + HeaderSize

proc readGoldMasterHeader(): seq[uint8] =
  ## Read the header from the gold master ROM.
  if not fileExists(GoldMasterRom):
    stderr.writeLine &"Gold master ROM not found: {GoldMasterRom}"
    quit(1)
  
  let romData = readFile(GoldMasterRom)
  if romData.len < HiRomHeaderOffset + HeaderSize:
    stderr.writeLine &"Gold master ROM too small: {romData.len} bytes"
    quit(1)
  
  result = newSeq[uint8](HeaderSize)
  for i in 0..<HeaderSize:
    result[i] = romData[HiRomHeaderOffset + i].uint8

proc generateRom(): string =
  ## Generate the decomp ROM with the correct header.
  let headerData = readGoldMasterHeader()
  
  var rom = newString(MinRomSize)
  for i in 0..<rom.len:
    rom[i] = '\x00'
  
  for i in 0..<headerData.len:
    rom[HiRomHeaderOffset + i] = headerData[i].char
  
  result = rom

when isMainModule:
  echo "Generating decomp ROM..."
  
  let rom = generateRom()
  writeFile(outputRom, rom)
  
  echo &"Generated ROM: {outputRom} ({rom.len} bytes)"
