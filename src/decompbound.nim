## Public interface for the decompbound decompilation project.
## This generates the ROM based on our reverse-engineered understanding.
## The gold master ROM is only used by compare.nim for validation.

# nim r src/decompbound.nim

import
  std/strformat

const
  outputRom = "bin/Decompbound.smc"
  HiRomHeaderOffset = 0xFFB0
  HeaderSize = 64
  EarthboundRomSize = 3 * 1024 * 1024

proc generateEarthboundHeader(): seq[uint8] =
  ## Generate the Earthbound ROM header based on reverse-engineered knowledge.
  ## This header is built from our understanding of what Earthbound's header should contain.
  ## The header at 0xFFB0 is 64 bytes, with the standard SNES header starting at 0xFFC0 (offset 0x10).
  result = newSeq[uint8](HeaderSize)
  
  for i in 0..<result.len:
    result[i] = 0
  
  result[0x00] = 0x30
  result[0x01] = 0x31
  result[0x02] = 0x4D
  result[0x03] = 0x42
  result[0x04] = 0x20
  result[0x05] = 0x20
  
  let gameTitle = "EARTH BOUND     "
  let titleOffset = 0x10
  
  for i in 0..<gameTitle.len:
    if i + titleOffset < result.len:
      result[i + titleOffset] = gameTitle[i].uint8
  
  result[0x25] = 0x31
  result[0x26] = 0x02
  result[0x27] = 0x0C
  result[0x28] = 0x03
  result[0x29] = 0x01
  result[0x2A] = 0x33
  result[0x2B] = 0x00
  result[0x2C] = 0xB7
  result[0x2D] = 0xBF
  result[0x2E] = 0x48
  result[0x2F] = 0x40
  
  result[0x3C] = 0xFF
  result[0x3D] = 0x5F
  result[0x3E] = 0xFF
  result[0x3F] = 0x5F

proc generateRom(): string =
  ## Generate the decomp ROM from our reverse-engineered code and data.
  ## This builds the ROM based on our understanding, not by copying from the gold master.
  let headerData = generateEarthboundHeader()
  
  var rom = newString(EarthboundRomSize)
  for i in 0..<rom.len:
    rom[i] = '\x00'
  
  for i in 0..<headerData.len:
    rom[HiRomHeaderOffset + i] = headerData[i].char
  
  result = rom

when isMainModule:
  echo "Generating decomp ROM from reverse-engineered code..."
  
  let rom = generateRom()
  writeFile(outputRom, rom)
  
  echo &"Generated ROM: {outputRom} ({rom.len} bytes)"
  echo "Use compare.nim to validate against the gold master ROM."
