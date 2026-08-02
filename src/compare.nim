# nim r src/compare.nim
## Gold-ROM referee + honest decomp progress tiers.
##
## "Implemented map matches gold" is NOT "we understand the game." Compare
## leads with Goal 1.5 adoption (named, readable source) and ranks scaffold /
## baserom extracts below it so the 99% map figure cannot be mistaken for
## comprehension.

import
  std/[algorithm, os, osproc, strutils, strformat, times],
  decompbound/[rom_chunks, baserom_extract]

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

  ProgressTiers* = object
    ## Named snesAsm / hand-written code modules (Goal 1.5).
    understoodCodeBytes*: int
    understoodCodeRoutines*: int
    ## Named data tables RE'd in adopted.nim (dispatch / jump tables).
    understoodDataBytes*: int
    understoodDataRoutines*: int
    ## Baserom extract claims: layout/format asserted, bytes read from gold.
    extractBytes*: int
    extractByKind*: array[ExtractKind, int]
    extractCount*: int
    ## Anonymous generated code_spans (traced scaffold; may include false code).
    scaffoldBytes*: int
    scaffoldSpans*: int
    ## Header / interrupt vectors.
    infraBytes*: int
    ## Sum of all implemented map spans (should equal code+data+extract+scaffold+infra).
    mapBytes*: int
    ## ROM size − mapBytes.
    unclaimedBytes*: int
    romSize*: int

  ComparisonStats = object
    totalBytes: int
    matchingBytes: int
    nonMatchingBytes: int
    intentionalMatches: int
    intentionalBytes: int
    percentage: float
    coincidentalMatches: int
    coincidentalZeroMatches: int
    ## intentionalMatches / totalBytes — map coverage, NOT understanding.
    mapCoverage: float
    tiers: ProgressTiers

  GitInfo = object
    commitHash: string
    isDirty: bool

  ByteRange = object
    start: int
    `end`: int

let
  implementedRegions = block:
    ## Intentional map from lightweight spans (code_spans + adopted + header).
    ## Must not call allRegions() — that assembles every bank and OOMs.
    var ranges: seq[ByteRange]
    for s in collectImplementedSpanMeta():
      ranges.add ByteRange(start: s.offset, `end`: s.offset + s.length - 1)
    ranges.sort(proc(a, b: ByteRange): int = cmp(a.start, b.start))
    ranges

proc isInImplementedRegion(offset: int): bool =
  ## Check if a byte offset is in an implemented region (binary search).
  var lo = 0
  var hi = implementedRegions.len
  while lo < hi:
    let mid = (lo + hi) div 2
    let r = implementedRegions[mid]
    if offset < r.start:
      hi = mid
    elif offset > r.`end`:
      lo = mid + 1
    else:
      return true
  result = false

proc isExtractSpanName(name: string): bool =
  ## True for baserom_extract inventory names (prefix conventions).
  name.startsWith("gfxLz_") or
  name.startsWith("apuPack") or
  name.startsWith("table_") or
  name.startsWith("zeroPad_") or
  name.startsWith("zero_") or
  name.startsWith("scriptStream_") or
  name.startsWith("script_") or
  name.startsWith("actionScript_") or
  name.startsWith("as_")

proc computeProgressTiers(romSize: int): ProgressTiers =
  ## Partition the implemented map into honest understanding tiers.
  result.romSize = romSize
  for s in collectImplementedSpanMeta():
    result.mapBytes += s.length
    case s.name
    of "code":
      result.scaffoldBytes += s.length
      result.scaffoldSpans += 1
    of "header", "resetVectors":
      result.infraBytes += s.length
    else:
      if isExtractSpanName(s.name):
        result.extractBytes += s.length
      else:
        ## Adopted named region (code or RE'd table data).
        case s.kind
        of ckImplementedCode:
          result.understoodCodeBytes += s.length
          result.understoodCodeRoutines += 1
        of ckImplementedMeta:
          result.understoodDataBytes += s.length
          result.understoodDataRoutines += 1
        of ckUnclaimed:
          discard
  for s in allBaseromExtractSpans():
    result.extractByKind[s.kind] += s.length
    result.extractCount += 1
  ## Prefer per-kind totals from the extract registry when they sum cleanly;
  ## span-meta extractBytes is the carved map view (authoritative for map %).
  result.unclaimedBytes = romSize - result.mapBytes

proc pctOfRom(bytes, romSize: int): float =
  ## Bytes as a percentage of the gold ROM.
  if romSize <= 0: 0.0 else: (bytes.float / romSize.float) * 100.0

proc formatNumber(n: int): string =
  ## Format number with comma separators for readability.
  let numStr = $n
  result = ""
  for i, c in numStr:
    if i > 0 and (numStr.len - i) mod 3 == 0:
      result.add ","
    result.add c

proc echoProgressTiers(t: ProgressTiers) =
  ## Print the honest tier ladder (stdout).
  let understoodTotal = t.understoodCodeBytes + t.understoodDataBytes
  let understoodPct = pctOfRom(understoodTotal, t.romSize)
  let codePct = pctOfRom(t.understoodCodeBytes, t.romSize)
  let dataPct = pctOfRom(t.understoodDataBytes, t.romSize)
  let extractPct = pctOfRom(t.extractBytes, t.romSize)
  let scaffoldPct = pctOfRom(t.scaffoldBytes, t.romSize)
  let infraPct = pctOfRom(t.infraBytes, t.romSize)
  let mapPct = pctOfRom(t.mapBytes, t.romSize)
  let unclaimedPct = pctOfRom(t.unclaimedBytes, t.romSize)

  echo "=== Decomp progress (honest tiers) ==="
  echo ""
  echo "PRIMARY — truly understood (Goal 1.5 adoption)"
  echo "  Named, readable, documented source that still byte-matches gold."
  echo &"  Named code  (snesAsm modules):  {formatNumber(t.understoodCodeBytes)} bytes  ({t.understoodCodeRoutines} routines)  = {codePct:.4f}% of ROM"
  echo &"  Named data  (RE'd tables):      {formatNumber(t.understoodDataBytes)} bytes  ({t.understoodDataRoutines} tables)    = {dataPct:.4f}% of ROM"
  echo &"  >>> TOTAL UNDERSTOOD:            {formatNumber(understoodTotal)} bytes  = {understoodPct:.4f}% of ROM  ← drive this up"
  echo ""
  echo "SECONDARY — data extract claims (baserom_extract)"
  echo "  Format/layout asserted; bytes pulled from gold at build time (not rewritten as Nim)."
  for k in ExtractKind:
    let n = t.extractByKind[k]
    if n > 0:
      echo &"  {extractKindName(k)}: {formatNumber(n)} bytes  ({pctOfRom(n, t.romSize):.2f}% of ROM)"
  echo &"  TOTAL EXTRACT CLAIMS:           {formatNumber(t.extractBytes)} bytes  ({t.extractCount} spans)  = {extractPct:.2f}% of ROM"
  echo ""
  echo "MAP ONLY — anonymous scaffold (generated code_spans)"
  echo "  Byte-exact traced regions. Not understood. Includes known false-positive"
  echo "  data mislabeled as code (see docs/residual-table-claims.md)."
  echo &"  Scaffold \"code\":               {formatNumber(t.scaffoldBytes)} bytes  ({t.scaffoldSpans} spans)  = {scaffoldPct:.2f}% of ROM"
  echo ""
  echo "INFRA — cartridge header / vectors"
  echo &"  Header + reset vectors:         {formatNumber(t.infraBytes)} bytes  = {infraPct:.4f}% of ROM"
  echo ""
  echo "UNCLAIMED — outside the implemented map"
  echo &"  Not yet claimed:                {formatNumber(t.unclaimedBytes)} bytes  = {unclaimedPct:.2f}% of ROM"
  echo ""
  echo &"ROM map coverage (all tiers above): {formatNumber(t.mapBytes)} / {formatNumber(t.romSize)} = {mapPct:.2f}%"
  echo "  ↑ Map coverage is NOT \"understood.\" Only the PRIMARY line is."

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
  result = (fileSize mod 1024) == CopierHeaderSize

proc readRomHeader(romPath: string): RomHeaderData =
  ## Read the ROM header from the specified ROM file.
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
  ## Compare ROM files and report honest decomp tiers + byte-exact gate.
  if not fileExists(GoldMasterRom):
    stderr.writeLine &"Gold master ROM not found: {GoldMasterRom}"
    quit(1)

  let goldRomData = readFile(GoldMasterRom)
  let goldRomSize = goldRomData.len
  let tiers = computeProgressTiers(goldRomSize)

  if not fileExists(DecompRom):
    echoProgressTiers(tiers)
    echo ""
    echo &"ROM comparison: {goldRomSize} bytes total, 0 match, {goldRomSize} differ (0.0% complete)"
    echo "Decomp ROM not found."
    return ComparisonStats(
      totalBytes: goldRomSize,
      matchingBytes: 0,
      nonMatchingBytes: goldRomSize,
      intentionalMatches: 0,
      intentionalBytes: tiers.mapBytes,
      percentage: 0.0,
      mapCoverage: 0.0,
      tiers: tiers)

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
        coincidentalMatches += 1
        if goldRomData[i] == '\0':
          coincidentalZeroMatches += 1
    else:
      nonMatchingBytes += 1

  let totalPercentage = (matchingBytes.float / goldRomSize.float) * 100.0
  let intentionalPercentage =
    if intentionalBytes > 0: (intentionalMatches.float / intentionalBytes.float) * 100.0
    else: 0.0
  let mapCoverage = (intentionalMatches.float / goldRomSize.float) * 100.0
  let coincidentalNonZero = coincidentalMatches - coincidentalZeroMatches
  let understoodTotal = tiers.understoodCodeBytes + tiers.understoodDataBytes
  let understoodPct = pctOfRom(understoodTotal, goldRomSize)

  echoProgressTiers(tiers)
  echo ""
  echo "=== Byte-exact gate (referee) ==="
  echo &"Implemented map exact: {formatNumber(intentionalMatches)} / {formatNumber(intentionalBytes)} = {intentionalPercentage:.2f}% of map"
  echo &"Map coverage of ROM:   {formatNumber(intentionalMatches)} / {formatNumber(goldRomSize)} = {mapCoverage:.2f}%  (scaffold+extracts+adopted+infra)"
  echo &"Understood of ROM:     {formatNumber(understoodTotal)} / {formatNumber(goldRomSize)} = {understoodPct:.4f}%  ← the real decomp needle"
  echo &"Coincidental matches (never claimed): {formatNumber(coincidentalMatches)}  ({formatNumber(coincidentalZeroMatches)} zero-fill + {formatNumber(coincidentalNonZero)} non-zero) — NOT progress"
  echo &"Raw byte matches incl. coincidental:  {formatNumber(matchingBytes)} ({totalPercentage:.2f}%) — inflated, do not track"

  if compareSize < goldRomSize:
    let remainingBytes = goldRomSize - compareSize
    echo &"  ({remainingBytes} bytes not yet present in decomp ROM file)"

  result = ComparisonStats(
    totalBytes: goldRomSize,
    matchingBytes: matchingBytes,
    nonMatchingBytes: nonMatchingBytes,
    intentionalMatches: intentionalMatches,
    intentionalBytes: intentionalBytes,
    percentage: intentionalPercentage,
    coincidentalMatches: coincidentalMatches,
    coincidentalZeroMatches: coincidentalZeroMatches,
    mapCoverage: mapCoverage,
    tiers: tiers
  )

proc compareHeaders(goldHeader: RomHeaderData, decompHeader: RomHeaderData): ComparisonStats =
  ## Compare two ROM headers and return statistics.
  if decompHeader.data.len == 0:
    echo "Decomp ROM not found or too small."
    return ComparisonStats(totalBytes: 0, matchingBytes: 0, nonMatchingBytes: 0,
      intentionalMatches: 0, intentionalBytes: 0, percentage: 0.0)

  if goldHeader.data.len != decompHeader.data.len:
    echo &"Header size mismatch: gold={goldHeader.data.len}, decomp={decompHeader.data.len}"
    return ComparisonStats(totalBytes: goldHeader.data.len, matchingBytes: 0,
      nonMatchingBytes: goldHeader.data.len, intentionalMatches: 0,
      intentionalBytes: goldHeader.data.len, percentage: 0.0)

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

proc generateReport(romStats: ComparisonStats, headerStats: ComparisonStats, gitInfo: GitInfo) =
  ## Generate report.md with tiered progress information.
  let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
  let t = romStats.tiers
  let understoodTotal = t.understoodCodeBytes + t.understoodDataBytes
  let understoodPct = pctOfRom(understoodTotal, romStats.totalBytes)

  var report = ""
  report.add "# Decompilation Progress Report\n\n"
  report.add &"Generated: {timestamp}\n\n"
  report.add "## Git Information\n\n"
  report.add &"- Commit: `{gitInfo.commitHash}`\n"
  report.add &"- Dirty: {gitInfo.isDirty}\n\n"

  report.add "## How to read these numbers\n\n"
  report.add "Almost the whole ROM can **match gold** in an \"implemented map\" without being "
  report.add "**understood**. Understanding means named, readable Nim (Goal 1.5 adoption) that "
  report.add "still assembles byte-exact. Scaffold and baserom extracts fill the map; they are "
  report.add "not the decomp needle.\n\n"

  report.add "## PRIMARY — truly understood (Goal 1.5)\n\n"
  report.add &"- **TOTAL UNDERSTOOD: {formatNumber(understoodTotal)} / {formatNumber(romStats.totalBytes)} = {understoodPct:.4f}% of ROM** ← drive this up\n"
  report.add &"- Named code (snesAsm): {formatNumber(t.understoodCodeBytes)} bytes ({t.understoodCodeRoutines} routines)\n"
  report.add &"- Named data tables (RE'd): {formatNumber(t.understoodDataBytes)} bytes ({t.understoodDataRoutines} tables)\n\n"

  report.add "## SECONDARY — data extract claims\n\n"
  report.add "Layout/format claimed in `baserom_extract.nim`; content read from gold at build time.\n\n"
  for k in ExtractKind:
    let n = t.extractByKind[k]
    if n > 0:
      report.add &"- {extractKindName(k)}: {formatNumber(n)} bytes ({pctOfRom(n, romStats.totalBytes):.2f}% of ROM)\n"
  report.add &"- **TOTAL EXTRACT: {formatNumber(t.extractBytes)} bytes** ({t.extractCount} spans, {pctOfRom(t.extractBytes, romStats.totalBytes):.2f}% of ROM)\n\n"

  report.add "## MAP ONLY — anonymous scaffold\n\n"
  report.add "Generated `code_spans` — byte-exact, not understood; may include false-positive data.\n\n"
  report.add &"- Scaffold code: {formatNumber(t.scaffoldBytes)} bytes ({t.scaffoldSpans} spans, {pctOfRom(t.scaffoldBytes, romStats.totalBytes):.2f}% of ROM)\n\n"

  report.add "## Infra / unclaimed\n\n"
  report.add &"- Header + vectors: {formatNumber(t.infraBytes)} bytes\n"
  report.add &"- Unclaimed (outside map): {formatNumber(t.unclaimedBytes)} bytes ({pctOfRom(t.unclaimedBytes, romStats.totalBytes):.2f}% of ROM)\n\n"

  report.add "## Byte-exact gate (referee)\n\n"
  report.add &"- Implemented map exact: {formatNumber(romStats.intentionalMatches)} / {formatNumber(romStats.intentionalBytes)} = {romStats.percentage:.2f}% of map\n"
  report.add &"- Map coverage of ROM: {formatNumber(romStats.intentionalMatches)} / {formatNumber(romStats.totalBytes)} = {romStats.mapCoverage:.2f}% — **not** \"understood\"\n"
  report.add &"- Coincidental matches (never claimed): {formatNumber(romStats.coincidentalMatches)} "
  report.add &"({formatNumber(romStats.coincidentalZeroMatches)} zero-fill + "
  report.add &"{formatNumber(romStats.coincidentalMatches - romStats.coincidentalZeroMatches)} non-zero)\n"
  report.add &"- Raw byte matches (inflated): {formatNumber(romStats.matchingBytes)} / {formatNumber(romStats.totalBytes)}\n"
  report.add &"- Non-matching bytes: {formatNumber(romStats.nonMatchingBytes)}\n\n"

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
