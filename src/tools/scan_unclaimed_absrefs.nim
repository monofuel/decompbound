## Scan generated bank modules for absolute SNES addresses that land in
## unclaimed file-offset gaps. Rank gaps by code reference density so residual
## table claims can target loader-backed data.
##
## Usage (repo root):
##   nim r src/tools/scan_unclaimed_absrefs.nim
##   nim r src/tools/scan_unclaimed_absrefs.nim --min-refs 3 --min-gap 16
##
## Does not claim or dump bytes. Follow-up: disasm loaders, register ekTable.

import
  std/[algorithm, os, strformat, strutils, tables],
  ../decompbound/[memmap, rom_chunks]

const
  BankDir = "src/decompbound/generated"
  DefaultMinRefs = 3
  DefaultMinGap = 8
  TopN = 40

type
  GapHit = object
    offset: int
    length: int
    refs: int
    uniqueAddrs: int
    samples: seq[uint32]

proc snesToFileSafe(snes: uint32): int =
  ## Map SNES address to file offset or -1.
  snesToFile(snes)

proc parseHexU32(s: string): uint32 =
  ## Parse hex string (no 0x/$ prefix).
  var v = 0'u32
  for c in s:
    let d =
      if c >= '0' and c <= '9': ord(c) - ord('0')
      elif c >= 'a' and c <= 'f': ord(c) - ord('a') + 10
      elif c >= 'A' and c <= 'F': ord(c) - ord('A') + 10
      else: -1
    if d < 0:
      continue
    v = (v shl 4) or d.uint32
  result = v

proc extractAbsSnesFromLine(line: string): seq[uint32] =
  ## Pull absolute long ROM-ish addresses from bank comment/operand text.
  ## Prefers $Cxxxxx / $Dxxxxx… and 0xCxxxxx-style 6+ hex digits in ROM banks.
  result = @[]
  var i = 0
  while i < line.len:
    # $Cxxxxx form (comment disasm)
    if line[i] == '$' and i + 7 <= line.len:
      let digs = line[i+1 ..< min(i+7, line.len)]
      var ok = digs.len == 6
      for c in digs:
        if not c.isAlphaNumeric:
          ok = false
          break
      if ok:
        let snes = parseHexU32(digs)
        let bank = (snes shr 16) and 0xFF
        if bank >= 0xC0 and bank <= 0xFF:
          # Skip obvious code-site labels like "$C10000:" when followed by ':'
          let after = i + 7
          if after >= line.len or line[after] != ':':
            result.add snes
        i += 7
        continue
    # 0xCxxxxx / 0xcxxxxx operands (6+ hex after 0x)
    if i + 4 < line.len and line[i] == '0' and line[i+1] in {'x', 'X'}:
      var j = i + 2
      while j < line.len and line[j].isAlphaNumeric:
        j += 1
      let digs = line[i+2 ..< j]
      if digs.len >= 6 and digs.len <= 8:
        let snes = parseHexU32(digs)
        let bank = (snes shr 16) and 0xFF
        if bank >= 0xC0 and bank <= 0xFF:
          result.add snes
      i = j
      continue
    i += 1

proc gapIndexFor(fileOff: int, starts, ends: seq[int]): int =
  ## Binary search for unclaimed gap containing fileOff. Returns -1 if none.
  var lo = 0
  var hi = starts.len - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    if fileOff < starts[mid]:
      hi = mid - 1
    elif fileOff >= ends[mid]:
      lo = mid + 1
    else:
      return mid
  result = -1

proc main() =
  ## Scan bank modules; print unclaimed gaps ranked by absolute-address refs.
  var minRefs = DefaultMinRefs
  var minGap = DefaultMinGap
  for i in 1..paramCount():
    let a = paramStr(i)
    if a == "--min-refs" and i < paramCount():
      minRefs = parseInt(paramStr(i + 1))
    elif a == "--min-gap" and i < paramCount():
      minGap = parseInt(paramStr(i + 1))
    elif a in ["-h", "--help"]:
      echo "scan_unclaimed_absrefs [--min-refs N] [--min-gap N]"
      quit(0)

  let chunks = allRomChunksMeta()
  var gaps: seq[tuple[offset, length: int]] = @[]
  var starts: seq[int] = @[]
  var ends: seq[int] = @[]
  var unclaimedBytes = 0
  for c in chunks:
    if c.kind == ckUnclaimed and c.length >= minGap:
      gaps.add (c.offset, c.length)
      starts.add c.offset
      ends.add c.offset + c.length
      unclaimedBytes += c.length

  echo &"unclaimed gaps (≥{minGap} B): {gaps.len}  bytes: {unclaimedBytes}"

  var refCount = newSeq[int](gaps.len)
  var uniq = newSeq[Table[int, int]](gaps.len)
  for i in 0..<gaps.len:
    uniq[i] = initTable[int, int]()

  var bankFiles: seq[string] = @[]
  for kind, path in walkDir(BankDir):
    if kind == pcFile and path.extractFilename.startsWith("code_bank") and
        path.endsWith(".nim"):
      bankFiles.add path
  bankFiles.sort(system.cmp)

  var totalHits = 0
  var totalLines = 0
  for path in bankFiles:
    let text = readFile(path)
    for line in text.splitLines():
      totalLines += 1
      # Fast reject: most lines lack long abs
      if not (('$') in line or ("0xC" in line) or ("0xD" in line) or
          ("0xE" in line) or ("0xF" in line) or ("0xc" in line)):
        continue
      let addrs = extractAbsSnesFromLine(line)
      for snes in addrs:
        let fo = snesToFileSafe(snes)
        if fo < 0:
          continue
        let gi = gapIndexFor(fo, starts, ends)
        if gi < 0:
          continue
        refCount[gi] += 1
        uniq[gi][fo] = uniq[gi].getOrDefault(fo, 0) + 1
        totalHits += 1

  echo &"scanned {bankFiles.len} bank files, {totalLines} lines, " &
    &"{totalHits} abs refs into unclaimed gaps"
  echo ""

  var ranked: seq[GapHit] = @[]
  for i in 0..<gaps.len:
    if refCount[i] < minRefs:
      continue
    var samples: seq[uint32] = @[]
    var pairs: seq[tuple[fo, n: int]] = @[]
    for fo, n in uniq[i]:
      pairs.add (fo, n)
    pairs.sort(proc(a, b: auto): int =
      result = cmp(b.n, a.n)
      if result == 0:
        result = cmp(a.fo, b.fo))
    for p in pairs:
      if samples.len >= 6:
        break
      samples.add fileToSnes(p.fo)
    ranked.add GapHit(
      offset: gaps[i].offset,
      length: gaps[i].length,
      refs: refCount[i],
      uniqueAddrs: uniq[i].len,
      samples: samples)

  ranked.sort(proc(a, b: GapHit): int =
    result = cmp(b.refs, a.refs)
    if result == 0:
      result = cmp(b.length, a.length)
    if result == 0:
      result = cmp(a.offset, b.offset))

  echo &"top unclaimed gaps by code abs-ref count (minRefs={minRefs}):"
  echo "rank\toffset\tlen\trefs\tuniq\toffset_end\tsample_snes"
  let n = min(TopN, ranked.len)
  for i in 0..<n:
    let g = ranked[i]
    var ss = ""
    for j, s in g.samples:
      if j > 0:
        ss.add ","
      ss.add &"${s:06X}"
    echo &"{i+1}\t0x{g.offset:06X}\t{g.length}\t{g.refs}\t{g.uniqueAddrs}\t" &
      &"0x{g.offset + g.length:06X}\t{ss}"

  # Also emit densest unique-addr clusters (table bases often have few uniq addrs
  # but many refs, or many sequential uniq).
  echo ""
  echo "also: largest unclaimed gaps with any abs refs (top 15 by size):"
  var bySize = ranked
  bySize.sort(proc(a, b: GapHit): int =
    result = cmp(b.length, a.length)
    if result == 0:
      result = cmp(b.refs, a.refs))
  for i in 0..<min(15, bySize.len):
    let g = bySize[i]
    echo &"  0x{g.offset:06X} L{g.length} refs={g.refs} uniq={g.uniqueAddrs}"

when isMainModule:
  main()
