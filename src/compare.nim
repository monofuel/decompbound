# nim r src/compare.nim

import
  std/[os, osproc, strutils, strformat, times],
  decompbound/regions

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  GoldMasterSha256 = "a8fe2226728002786d68c27ddddf0b90a894db52e4dfe268fdf72a68cae5f02e"
  DecompRom = "bin/Decompbound.smc"
  ReportFile = "report.md"
  HiRomHeaderOffset = 0xFFB0
  HeaderSize = 64
  CopierHeaderSize = 512

type
  RomHeaderData = object
    data: seq[uint8]
    isHeadered: bool
    fileOffset: int
  
  ComparisonStats = object
    totalBytes: int
    matchingBytes: int
    nonMatchingBytes: int
    intentionalMatches: int
    intentionalBytes: int
    percentage: float
    ## Honest-signal breakdown (compare.nim is the referee; the headline
    ## "raw matches" number is inflated by coincidental zero-fill agreement
    ## between the gold ROM and the not-yet-built decomp ROM, so it must not
    ## be read as decompilation progress). See docs/rom-emulator-tests.md.
    coincidentalMatches: int    ## matches OUTSIDE any implemented region
    coincidentalZeroMatches: int ## of those, the ones where gold byte == 0x00
    trueCoverage: float         ## intentionalMatches / totalBytes — real progress
  
  GitInfo = object
    commitHash: string
    isDirty: bool
  
  ByteRange = object
    start: int
    `end`: int

let
  implementedRegions = block:
    ## Regions come from the central registry, so the compare harness can
    ## never claim coverage the ROM builder does not actually produce.
    var ranges: seq[ByteRange]
    for region in allRegions():
      ranges.add ByteRange(start: region.offset,
                           `end`: region.offset + region.data.len - 1)
    ranges

proc isInImplementedRegion(offset: int): bool =
  ## Check if a byte offset is in an implemented region.
  for region in implementedRegions:
    if offset >= region.start and offset <= region.`end`:
      return true
  result = false

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

proc getGitInfo(): GitInfo =
  ## Get git commit hash and dirty status.
  result.commitHash = "unknown"
  result.isDirty = false
  
  let (hashOutput, hashExitCode) = execCmdEx("git rev-parse HEAD")
  if hashExitCode == 0:
    result.commitHash = hashOutput.strip()
  
  let (statusOutput, statusExitCode) = execCmdEx("git status --porcelain")
  if statusExitCode == 0 and statusOutput.strip().len > 0:
    result.isDirty = true

proc compareFullRom(): ComparisonStats =
  ## Compare the entire ROM files byte-by-byte and return statistics.
  if not fileExists(GoldMasterRom):
    stderr.writeLine &"Gold master ROM not found: {GoldMasterRom}"
    quit(1)
  
  let goldRomData = readFile(GoldMasterRom)
  let goldRomSize = goldRomData.len
  
  if not fileExists(DecompRom):
    echo &"ROM comparison: {goldRomSize} bytes total, 0 match, {goldRomSize} differ (0.0% complete)"
    echo "Decomp ROM not found."
    return ComparisonStats(totalBytes: goldRomSize, matchingBytes: 0, nonMatchingBytes: goldRomSize, intentionalMatches: 0, intentionalBytes: 0, percentage: 0.0)
  
  let decompRomData = readFile(DecompRom)
  let decompRomSize = decompRomData.len
  
  if goldRomSize != decompRomSize:
    let sizeDiff = goldRomSize - decompRomSize
    echo &"ROM size mismatch: gold={goldRomSize} bytes, decomp={decompRomSize} bytes (difference: {sizeDiff} bytes)"
  
  let compareSize = min(goldRomSize, decompRomSize)
  var matchingBytes = 0
  var nonMatchingBytes = 0
  var intentionalMatches = 0
  var intentionalBytes = 0
  var coincidentalMatches = 0
  var coincidentalZeroMatches = 0

  for i in 0..<compareSize:
    let isImplemented = isInImplementedRegion(i)
    if isImplemented:
      intentionalBytes += 1

    if goldRomData[i] == decompRomData[i]:
      matchingBytes += 1
      if isImplemented:
        intentionalMatches += 1
      else:
        # Matched a byte we never actually decompiled: coincidence, not
        # progress. Overwhelmingly zero-fill where both ROMs are blank.
        coincidentalMatches += 1
        if goldRomData[i] == '\0':
          coincidentalZeroMatches += 1
    else:
      nonMatchingBytes += 1

  let totalPercentage = (matchingBytes.float / goldRomSize.float) * 100.0
  let intentionalPercentage = if intentionalBytes > 0: (intentionalMatches.float / intentionalBytes.float) * 100.0 else: 0.0
  let trueCoverage = (intentionalMatches.float / goldRomSize.float) * 100.0
  let coincidentalNonZero = coincidentalMatches - coincidentalZeroMatches

  # Lead with the honest number: how much of the ROM is actually decompiled
  # and byte-exact. The raw-match line is demoted and explicitly flagged as
  # inflated, so it can never be mistaken for progress again.
  echo &"Decompiled (byte-exact): {intentionalMatches} / {goldRomSize} bytes = {trueCoverage:.2f}% of ROM  [implemented regions {intentionalPercentage:.2f}% exact]"
  echo &"  Coincidental matches (never decompiled): {coincidentalMatches}  ({coincidentalZeroMatches} zero-fill + {coincidentalNonZero} non-zero) — NOT progress"
  echo &"  Raw byte matches incl. coincidental: {matchingBytes} ({totalPercentage:.2f}%) — inflated, do not track"

  if compareSize < goldRomSize:
    let remainingBytes = goldRomSize - compareSize
    echo &"  ({remainingBytes} bytes not yet implemented in decomp ROM)"

  result = ComparisonStats(
    totalBytes: goldRomSize,
    matchingBytes: matchingBytes,
    nonMatchingBytes: nonMatchingBytes,
    intentionalMatches: intentionalMatches,
    intentionalBytes: intentionalBytes,
    percentage: intentionalPercentage,
    coincidentalMatches: coincidentalMatches,
    coincidentalZeroMatches: coincidentalZeroMatches,
    trueCoverage: trueCoverage
  )

proc compareHeaders(goldHeader: RomHeaderData, decompHeader: RomHeaderData): ComparisonStats =
  ## Compare two ROM headers and return statistics.
  if decompHeader.data.len == 0:
    echo "Decomp ROM not found or too small."
    return ComparisonStats(totalBytes: 0, matchingBytes: 0, nonMatchingBytes: 0, intentionalMatches: 0, intentionalBytes: 0, percentage: 0.0)
  
  if goldHeader.data.len != decompHeader.data.len:
    echo &"Header size mismatch: gold={goldHeader.data.len}, decomp={decompHeader.data.len}"
    return ComparisonStats(totalBytes: goldHeader.data.len, matchingBytes: 0, nonMatchingBytes: goldHeader.data.len, intentionalMatches: 0, intentionalBytes: goldHeader.data.len, percentage: 0.0)
  
  var differences: seq[int] = @[]
  for i in 0..<goldHeader.data.len:
    if goldHeader.data[i] != decompHeader.data[i]:
      differences.add(i)
  
  let totalBytes = goldHeader.data.len
  let matchingBytes = totalBytes - differences.len
  let nonMatchingBytes = differences.len
  let percentage = (matchingBytes.float / totalBytes.float) * 100.0
  
  echo &"Header comparison: {totalBytes} bytes total, {matchingBytes} match, {nonMatchingBytes} differ ({percentage:.1f}% complete)"
  
  if differences.len > 0:
    echo &"Header differences at {differences.len} byte(s):"
    for offset in differences:
      let goldByte = goldHeader.data[offset]
      let decompByte = decompHeader.data[offset]
      let romOffset = HiRomHeaderOffset + offset
      echo &"  ROM offset 0x{romOffset:04X} (file offset 0x{goldHeader.fileOffset + offset:04X}): gold=0x{goldByte:02X}, decomp=0x{decompByte:02X}"
  
  result = ComparisonStats(
    totalBytes: totalBytes,
    matchingBytes: matchingBytes,
    nonMatchingBytes: nonMatchingBytes,
    intentionalMatches: matchingBytes,
    intentionalBytes: totalBytes,
    percentage: percentage
  )

proc formatNumber(n: int): string =
  ## Format number with comma separators for readability.
  let numStr = $n
  result = ""
  for i, c in numStr:
    if i > 0 and (numStr.len - i) mod 3 == 0:
      result.add ","
    result.add c

proc generateReport(romStats: ComparisonStats, headerStats: ComparisonStats, gitInfo: GitInfo) =
  ## Generate report.md with progress information.
  let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
  
  var report = ""
  report.add "# Decompilation Progress Report\n\n"
  report.add &"Generated: {timestamp}\n\n"
  report.add "## Git Information\n\n"
  report.add &"- Commit: `{gitInfo.commitHash}`\n"
  report.add &"- Dirty: {gitInfo.isDirty}\n\n"
  report.add "## ROM Comparison\n\n"
  let totalBytesStr = formatNumber(romStats.totalBytes)
  let matchingBytesStr = formatNumber(romStats.matchingBytes)
  let nonMatchingBytesStr = formatNumber(romStats.nonMatchingBytes)
  let intentionalBytesStr = formatNumber(romStats.intentionalBytes)
  let intentionalMatchesStr = formatNumber(romStats.intentionalMatches)
  let coincidentalStr = formatNumber(romStats.coincidentalMatches)
  let coincidentalZeroStr = formatNumber(romStats.coincidentalZeroMatches)
  let coincidentalNonZeroStr = formatNumber(
    romStats.coincidentalMatches - romStats.coincidentalZeroMatches)
  report.add "**Decomp coverage** = byte-exact decompiled bytes as a fraction of the whole ROM. This is the number to drive up.\n\n"
  report.add &"- **Decompiled (byte-exact): {intentionalMatchesStr} / {totalBytesStr} = {romStats.trueCoverage:.2f}% of ROM**\n"
  report.add &"- Implemented regions: {intentionalBytesStr} bytes, {intentionalMatchesStr} exact ({romStats.percentage:.2f}% of implemented — the byte-exact gate)\n"
  report.add "\n"
  report.add "### Coincidental matches (not progress)\n\n"
  report.add "Bytes that agree with gold but were never decompiled — mostly zero-fill where both ROMs are blank. Tracked only to keep the raw-match number honest.\n\n"
  report.add &"- Coincidental matches: {coincidentalStr} ({coincidentalZeroStr} zero-fill + {coincidentalNonZeroStr} non-zero)\n"
  report.add &"- Raw byte matches (inflated, incl. coincidental): {matchingBytesStr} / {totalBytesStr}\n"
  report.add &"- Non-matching bytes: {nonMatchingBytesStr}\n\n"
  report.add "## Header Comparison\n\n"
  report.add &"- Total bytes: {headerStats.totalBytes}\n"
  report.add &"- Matching bytes: {headerStats.matchingBytes}\n"
  report.add &"- Non-matching bytes: {headerStats.nonMatchingBytes}\n"
  report.add &"- Progress: {headerStats.percentage:.1f}%\n"
  
  writeFile(ReportFile, report)
  echo &"Report written to {ReportFile}"

when isMainModule:
  validateGoldMasterRom()
  
  let romStats = compareFullRom()
  echo ""
  
  let goldHeader = readRomHeader(GoldMasterRom)
  let decompHeader = readRomHeader(DecompRom)
  
  let headerStats = compareHeaders(goldHeader, decompHeader)
  
  let gitInfo = getGitInfo()
  generateReport(romStats, headerStats, gitInfo) 
