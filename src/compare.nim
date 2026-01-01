# nim r src/compare.nim

import
  std/[os, osproc, strutils, strformat]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  GoldMasterSha256 = "a8fe2226728002786d68c27ddddf0b90a894db52e4dfe268fdf72a68cae5f02e"
  DecompRom = "bin/Decompbound.smc"
  HiRomHeaderOffset = 0xFFB0
  HeaderSize = 64
  CopierHeaderSize = 512

type
  RomHeaderData = object
    data: seq[uint8]
    isHeadered: bool
    fileOffset: int

proc validateGoldMasterRom() =
  ## Validate that the gold master ROM exists and matches the expected SHA256.
  if not fileExists(GoldMasterRom):
    stderr.writeLine &"Gold master ROM not found: {GoldMasterRom}"
    quit(1)
  
  let (output, exitCode) = execCmdEx(&"sha256sum {GoldMasterRom.quoteShell}")
  if exitCode != 0:
    stderr.writeLine &"Failed to compute SHA256 for {GoldMasterRom}"
    quit(1)
  
  let computedHash = output.splitWhitespace()[0]
  
  if computedHash != GoldMasterSha256:
    stderr.writeLine &"Gold master ROM SHA256 mismatch. Expected: {GoldMasterSha256}, Got: {computedHash}"
    quit(1)

proc isHeaderedRom(fileSize: int): bool =
  ## Detect if a ROM has a 512-byte copier header.
  ## ROM files with complete 32 or 64 kb banks will have file size % 1024 == 0.
  ## If file size % 1024 == 512, it has a copier header.
  result = (fileSize mod 1024) == CopierHeaderSize

proc readRomHeader(romPath: string): RomHeaderData =
  ## Read the ROM header from the specified ROM file.
  ## Returns header data and information about whether the ROM is headered.
  if not fileExists(romPath):
    return RomHeaderData(data: @[], isHeadered: false, fileOffset: 0)
  
  let romData = readFile(romPath)
  let isHeadered = isHeaderedRom(romData.len)
  let headerOffset = if isHeadered: HiRomHeaderOffset + CopierHeaderSize else: HiRomHeaderOffset
  
  if romData.len < headerOffset + HeaderSize:
    return RomHeaderData(data: @[], isHeadered: isHeadered, fileOffset: headerOffset)
  
  result.data = newSeq[uint8](HeaderSize)
  for i in 0..<HeaderSize:
    result.data[i] = romData[headerOffset + i].uint8
  result.isHeadered = isHeadered
  result.fileOffset = headerOffset

proc compareHeaders(goldHeader: RomHeaderData, decompHeader: RomHeaderData) =
  ## Compare two ROM headers and report differences.
  if goldHeader.isHeadered:
    echo "Gold master ROM is headered (512-byte copier header detected)"
  else:
    echo "Gold master ROM is unheadered"
  
  if decompHeader.data.len == 0:
    echo "Decomp ROM not found or too small. Expected header:"
    if decompHeader.isHeadered:
      echo "  (Decomp ROM appears to be headered)"
    echo &"  ROM offset: 0x{HiRomHeaderOffset:04X}, File offset: 0x{goldHeader.fileOffset:04X}"
    echo "  Offset   00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F"
    for i in 0..<goldHeader.data.len:
      if i mod 16 == 0:
        stdout.write &"  0x{HiRomHeaderOffset + i:04X}  "
      stdout.write &"{goldHeader.data[i]:02X} "
      if i mod 16 == 15 or i == goldHeader.data.len - 1:
        echo ""
    return
  
  if decompHeader.isHeadered:
    echo "Decomp ROM is headered (512-byte copier header detected)"
  else:
    echo "Decomp ROM is unheadered"
  
  if goldHeader.isHeadered != decompHeader.isHeadered:
    let goldStatus = if goldHeader.isHeadered: "headered" else: "unheadered"
    let decompStatus = if decompHeader.isHeadered: "headered" else: "unheadered"
    echo &"Warning: Header status mismatch - gold is {goldStatus}, decomp is {decompStatus}"
  
  if goldHeader.data.len != decompHeader.data.len:
    echo &"Header size mismatch: gold={goldHeader.data.len}, decomp={decompHeader.data.len}"
    return
  
  var differences: seq[int] = @[]
  for i in 0..<goldHeader.data.len:
    if goldHeader.data[i] != decompHeader.data[i]:
      differences.add(i)
  
  let totalBytes = goldHeader.data.len
  let matchingBytes = totalBytes - differences.len
  let nonMatchingBytes = differences.len
  let percentage = (matchingBytes.float / totalBytes.float) * 100.0
  
  echo &"Header comparison: {totalBytes} bytes total, {matchingBytes} match, {nonMatchingBytes} differ ({percentage:.1f}% complete)"
  
  if differences.len == 0:
    echo "ROM headers match."
  else:
    echo &"ROM headers differ at {differences.len} byte(s):"
    for offset in differences:
      let goldByte = goldHeader.data[offset]
      let decompByte = decompHeader.data[offset]
      echo &"  ROM offset 0x{HiRomHeaderOffset + offset:04X} (file offset 0x{goldHeader.fileOffset + offset:04X}): gold=0x{goldByte:02X}, decomp=0x{decompByte:02X}"

when isMainModule:
  validateGoldMasterRom()
  
  let goldHeader = readRomHeader(GoldMasterRom)
  let decompHeader = readRomHeader(DecompRom)
  
  compareHeaders(goldHeader, decompHeader) 
