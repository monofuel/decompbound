## Probe unclaimed ROM gaps for known data formats (gfx_lz, APU packages).
##
## Reports success/fail + decoded/consumed sizes. Does not write dumps or claim
## regions — claims live in baserom_extract.nim after human/agent review.
##
## Usage (repo root, gold at bin/Earthbound (U) [!].smc):
##   nim r src/tools/probe_gap_formats.nim
##   nim r src/tools/probe_gap_formats.nim --scan
##
## Exit 0 always after printing the report (probe tool, not a gate).

import
  std/[algorithm, os, strformat, strutils],
  ../decompbound/[baserom_extract, gfx_lz, rom_chunks]

const
  DecodeWindow = 0x10000
  MinGfxConsumed = 16
  MinGfxDecoded = 64

type
  GapCandidate = object
    offset: int
    length: int
    label: string

proc readRom(): seq[uint8] =
  ## Load gold baserom bytes.
  readGoldBaseromBytes()

proc u16le(rom: seq[uint8], o: int): int =
  ## Little-endian u16 at file offset.
  int(rom[o]) or (int(rom[o + 1]) shl 8)

proc probeGfxLz(rom: seq[uint8], off, gapLen: int): string =
  ## Try gfx_lz at gap start; return a one-line status string.
  if off < 0 or off >= rom.len:
    return "gfx_lz: OOB"
  let hi = min(off + DecodeWindow, rom.len)
  let (decoded, consumed, clean) = decodeWithConsumed(rom[off ..< hi])
  if not clean:
    return &"gfx_lz: FAIL no_term consumed={consumed} decoded={decoded.len}"
  if consumed < MinGfxConsumed:
    return &"gfx_lz: FAIL tiny_stream consumed={consumed}"
  if decoded.len < MinGfxDecoded:
    return &"gfx_lz: FAIL tiny_out decoded={decoded.len} consumed={consumed}"
  if consumed > gapLen:
    return &"gfx_lz: FAIL past_gap consumed={consumed} gap={gapLen} decoded={decoded.len}"
  let ratio = decoded.len.float / consumed.float
  let lib = decode(rom[off ..< hi])
  if lib != decoded:
    return &"gfx_lz: FAIL lib_mismatch consumed={consumed}"
  &"gfx_lz: OK consumed={consumed} decoded={decoded.len} ratio={ratio:.2f}"

proc probeApuPackage(rom: seq[uint8], off, gapLen: int): string =
  ## Walk [u16 len][u16 tgt][payload] from off; report blocks that fit in gap.
  if off + 4 > rom.len:
    return "apu_pkg: OOB"
  var pos = off
  var blocks = 0
  var payload = 0
  let limit = min(off + gapLen, rom.len)
  while pos + 4 <= limit:
    let ln = u16le(rom, pos)
    let tgt = u16le(rom, pos + 2)
    if ln == 0:
      let consumed = pos + 4 - off
      return &"apu_pkg: OK blocks={blocks} payload={payload} consumed={consumed} " &
        &"term_entry=0x{tgt:04X}"
    if ln > 0xC000:
      return &"apu_pkg: FAIL bad_len={ln} at +{pos - off} blocks={blocks}"
    if pos + 4 + ln > rom.len:
      return &"apu_pkg: FAIL overrun at +{pos - off}"
    # Block may extend past this unclaimed gap (rest may be code_spans).
    blocks += 1
    payload += ln
    pos += 4 + ln
    if pos > limit and ln != 0:
      return &"apu_pkg: PARTIAL blocks={blocks} payload={payload} " &
        &"next_hdr_past_gap (+{pos - off} > {gapLen})"
  &"apu_pkg: FAIL no_term in gap blocks={blocks} scanned={pos - off}"

proc defaultCandidates(chunks: seq[RomChunk]): seq[GapCandidate] =
  ## Task-named gaps plus the largest unclaimed spans.
  const named = [
    (0x14B660, 2450, "task"),
    (0x14A67E, 2100, "task"),
    (0x16E3E5, 1837, "task"),
    (0x2B51D5, 269, "task-apu"),
  ]
  for (o, l, lab) in named:
    result.add GapCandidate(offset: o, length: l, label: lab)
  # Largest unclaimed (skip ones already listed).
  var unclaimed: seq[RomChunk] = @[]
  for c in chunks:
    if c.kind == ckUnclaimed and c.length >= 1000:
      unclaimed.add c
  unclaimed.sort(proc(a, b: RomChunk): int = cmp(b.length, a.length))
  var added = 0
  for c in unclaimed:
    var dup = false
    for g in result:
      if g.offset == c.offset:
        dup = true
        break
    if dup:
      continue
    result.add GapCandidate(offset: c.offset, length: c.length, label: "large")
    added += 1
    if added >= 15:
      break

proc printClaimed() =
  ## Show currently registered baserom extract claims.
  echo "Registered baserom extracts (baserom_extract.nim):"
  var total = 0
  for s in allBaseromExtractSpans():
    total += s.length
    echo &"  {s.name} 0x{s.offset:06X}+{s.length} kind={extractKindName(s.kind)} — {s.note}"
  echo &"  total claimed: {total} bytes"

proc main() =
  ## Probe candidate gaps; optional --scan walks large gaps for gfx_lz starts.
  var doScan = false
  for i in 1..paramCount():
    if paramStr(i) == "--scan":
      doScan = true
    elif paramStr(i) in ["-h", "--help"]:
      echo "probe_gap_formats [--scan]"
      quit(0)

  if not goldBaseromAvailable():
    stderr.writeLine &"gold baserom missing at {resolveGoldBaseromPath()}"
    quit(1)

  let rom = readRom()
  let chunks = allRomChunksMeta()
  echo &"rom={rom.len} unclaimed inventory via rom_chunks"
  echo ""
  printClaimed()
  echo ""
  echo "Probing candidates:"
  echo "offset\tgap\tlabel\tformats"

  let cands = defaultCandidates(chunks)
  for g in cands:
    let gfx = probeGfxLz(rom, g.offset, g.length)
    let apu = probeApuPackage(rom, g.offset, g.length)
    echo &"0x{g.offset:06X}\t{g.length}\t{g.label}\t{gfx} | {apu}"

  if doScan:
    echo ""
    echo "Scan large unclaimed for gfx_lz starts (stride 32, max 5 hits/gap):"
    for g in cands:
      if g.length < 500:
        continue
      var hits = 0
      var i = 0
      while i < g.length and hits < 5:
        let start = g.offset + i
        let hi = min(start + DecodeWindow, rom.len)
        let (decoded, consumed, clean) = decodeWithConsumed(rom[start ..< hi])
        if clean and consumed >= MinGfxConsumed and decoded.len >= MinGfxDecoded and
            consumed <= g.length - i:
          let ratio = decoded.len.float / consumed.float
          if ratio >= 1.1 and ratio <= 40.0:
            echo &"  0x{start:06X} (+{i}) consumed={consumed} decoded={decoded.len} ratio={ratio:.2f}"
            hits += 1
            i += max(consumed, 32)
            continue
        i += 32
      if hits == 0:
        echo &"  gap 0x{g.offset:06X} L{g.length}: no gfx_lz hits"

  echo ""
  echo "Done. No dumps written. Register clean streams in baserom_extract.nim."

when isMainModule:
  main()
