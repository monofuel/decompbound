## Class B RE dig: bank $D8 sparse/$80 false-code bands.
## Dumps candidate bands, free holes, AbsoluteLong loaders into $D8,
## and local inventory (code/meta/free) around each candidate.

import
  std/[algorithm, os, strformat, strutils, tables, sets],
  ../decompbound/[memmap, rom_chunks, baserom_extract, common]

const
  Gold = "bin/Earthbound (U) [!].smc"
  BankFile = 0x18
  BankSnes = 0xD8
  BankLo = BankFile * 0x10000
  BankHi = BankLo + 0x10000
  # Report-named false-code bands (offset, length)
  Cands = [
    (0x184819, 82),
    (0x185BF9, 4),
    (0x186641, 62),
    (0x187563, 40),
    (0x189893, 22),
  ]
  # Sandwich free holes (offset, length)
  Frees = [
    (0x18277F, 3),
    (0x18486B, 7),
    (0x185BFD, 7),
    (0x18667F, 7),
    (0x18758B, 7),
    (0x1898A9, 7),
    (0x189AD7, 7),
    (0x18BEF6, 7),
    (0x18BF90, 7),
  ]
  AbsLongOps = {0xAF'u8, 0xCF'u8, 0xEF'u8, 0xBF'u8, 0xDF'u8, 0xFF'u8,
                0x8F'u8, 0x9F'u8}
  LoadOps = {0xAF'u8, 0xBF'u8, 0xCF'u8, 0xDF'u8, 0xEF'u8, 0xFF'u8}

proc opName(op: uint8): string =
  ## Mnemonic for absolute-long opcode.
  case op
  of 0xAF: "LDA.L"
  of 0xBF: "LDA.L,X"
  of 0xCF: "CMP.L"
  of 0xDF: "CMP.L,X"
  of 0xEF: "SBC.L"
  of 0xFF: "SBC.L,X"
  of 0x8F: "STA.L"
  of 0x9F: "STA.L,X"
  else: &"op{op:02X}"

proc hexDump(data: string; o, n: int; cols = 16): string =
  ## Hex dump of n bytes starting at o.
  var lines: seq[string] = @[]
  var i = 0
  while i < n:
    var hs = ""
    let take = min(cols, n - i)
    for j in 0 ..< take:
      if j > 0: hs.add ' '
      hs.add &"{ord(data[o + i + j]):02X}"
    lines.add &"  {o+i:06X}: {hs}"
    i += take
  result = lines.join("\n")

proc dens(data: string; o, n: int; b: uint8): float =
  ## Density of byte b in window.
  if n <= 0: return 0.0
  var c = 0
  for i in 0 ..< n:
    if ord(data[o + i]) == int(b): c += 1
  c.float / n.float

proc pairRate(data: string; o, n: int): float =
  ## Fraction of adjacent pairs with equal first-of-pair pattern (u8 pair stream).
  if n < 4: return 0.0
  var same = 0
  var tot = 0
  var i = o
  while i + 3 < o + n:
    # pattern A B A C or A B A B
    if data[i] == data[i + 2]:
      same += 1
    tot += 1
    i += 2
  if tot == 0: return 0.0
  same.float / tot.float

proc alphabet(data: string; o, n: int): string =
  ## Sorted unique bytes as hex list.
  var s: set[uint8] = {}
  for i in 0 ..< n:
    s.incl data[o + i].uint8
  var parts: seq[string] = @[]
  for b in 0u8 .. 255u8:
    if b in s:
      parts.add &"{b:02X}"
  parts.join(",")

proc kindAt(chunks: seq[RomChunk]; o: int): string =
  ## Chunk kind name covering offset o.
  for c in chunks:
    if o >= c.offset and o < c.offset + c.length:
      return $c.kind & &" @{c.offset:06X}+{c.length}"
  "none"

proc main() =
  ## Dump D8 candidate bands and AbsoluteLong loaders into bank $D8.
  let gold = readFile(Gold)
  doAssert gold.len >= BankHi
  let chunks = allRomChunksMeta()
  let extracts = allBaseromExtractSpans()

  echo "=== Bank $D8 composition ==="
  var codeB, metaB, freeB = 0
  for c in chunks:
    if c.offset < BankLo or c.offset >= BankHi: continue
    case c.kind
    of ckImplementedCode: codeB += c.length
    of ckImplementedMeta: metaB += c.length
    of ckUnclaimed: freeB += c.length
  echo &"  code={codeB} meta={metaB} free={freeB} sum={codeB+metaB+freeB}"

  echo "\n=== Existing extract claims overlapping candidates ==="
  for (co, cn) in Cands:
    for e in extracts:
      let eo = e.offset
      let en = e.length
      if eo + en <= co or co + cn <= eo: continue
      echo &"  cand {co:06X}+{cn} overlaps {e.name} @{eo:06X}+{en} kind={e.kind}"

  echo "\n=== Candidate bands (hex + stats + inventory) ==="
  for (o, n) in Cands:
    echo &"\n--- {o:06X}+{n} dens80={dens(gold,o,n,0x80):.2f} dens00={dens(gold,o,n,0x00):.2f} pair={pairRate(gold,o,n):.2f}"
    echo &"  alphabet={alphabet(gold,o,n)}"
    echo &"  kind@head={kindAt(chunks, o)} kind@mid={kindAt(chunks, o+n div 2)} kind@end={kindAt(chunks, o+n-1)}"
    # expand window ±32 for context
    let lo = max(BankLo, o - 16)
    let hi = min(BankHi, o + n + 16)
    echo hexDump(gold, lo, hi - lo)
    # free bytes inside band
    var freeIn = 0
    for i in o ..< o + n:
      if kindAt(chunks, i).startsWith("ckUnclaimed"):
        freeIn += 1
    echo &"  freeBytesInside={freeIn}"

  echo "\n=== Free holes (hex + neighbors) ==="
  for (o, n) in Frees:
    echo &"\n--- free {o:06X}+{n} dens80={dens(gold,o,n,0x80):.2f} dens00={dens(gold,o,n,0x00):.2f}"
    echo &"  head={hexDump(gold, o, n).strip()}"
    echo &"  self={kindAt(chunks, o)}"
    if o > BankLo:
      echo &"  L={kindAt(chunks, o-1)}"
    if o + n < BankHi:
      echo &"  R={kindAt(chunks, o+n)}"
    let lo = max(BankLo, o - 24)
    let hi = min(BankHi, o + n + 24)
    echo hexDump(gold, lo, hi - lo)

  # Scan AbsoluteLong loaders across whole ROM that target bank $D8
  echo "\n=== AbsoluteLong operands landing in bank $D8 ==="
  type Hit = object
    site, target: int
    op: uint8
    name: string
  var hits: seq[Hit] = @[]
  # Scan raw gold for AbsLong patterns (any bank) whose operand bank is $D8
  for i in 0 ..< gold.len - 3:
    let op = gold[i].uint8
    if op notin AbsLongOps: continue
    let lo = gold[i+1].uint8
    let hi = gold[i+2].uint8
    let bk = gold[i+3].uint8
    if bk.int != BankSnes: continue
    let snes = (bk.int shl 16) or (hi.int shl 8) or lo.int
    let fileOff = snes - 0xC00000  # HiROM: $C0xxxx → file 0x00xxxx, $D8 → 0x18
    # HiROM map: bank $C0-$FF map to file banks 0x00-0x3F
    let fOff = ((bk.int - 0xC0) shl 16) or (hi.int shl 8) or lo.int
    if fOff < BankLo or fOff >= BankHi: continue
    hits.add Hit(site: i, target: fOff, op: op, name: opName(op))

  hits.sort(proc(a, b: Hit): int =
    result = cmp(a.target, b.target)
    if result == 0: result = cmp(a.site, b.site))

  echo &"  total AbsLong ops with bank $D8 operand: {hits.len}"
  # Group by target proximity to candidates
  for (co, cn) in Cands:
    echo &"\n  loaders into/near cand {co:06X}+{cn} (±256):"
    var n = 0
    for h in hits:
      if h.target < co - 256 or h.target > co + cn + 256: continue
      let inCand = h.target >= co and h.target < co + cn
      let mark = if inCand: "IN" else: "near"
      echo &"    {mark} {h.name} site={h.site:06X} target={h.target:06X} ({h.name} ${BankSnes:02X}{(h.target and 0xFFFF):04X})"
      n += 1
    if n == 0: echo "    (none)"

  # Also list all unique target base clusters in D8 (top by count)
  var tgtCount: CountTable[int]
  for h in hits:
    # round target to 16-byte bucket
    tgtCount.inc(h.target and not 0xF)
  echo "\n=== Top D8 AbsLong target buckets (16B) ==="
  var ranked: seq[(int, int)] = @[]
  for k, v in tgtCount:
    ranked.add (k, v)
  ranked.sort(proc(a, b: (int, int)): int = cmp(b[1], a[1]))
  for i, (k, v) in ranked:
    if i >= 40: break
    echo &"  {k:06X} x{v}  kind={kindAt(chunks, k)}"

  # Expand each candidate to natural data boundaries (runs of dens80/pair)
  echo "\n=== Expand candidates to dens80/pair natural bounds ==="
  for (o, n) in Cands:
    # walk left while dens80 in 16B window ≥ 0.25 or pair≥0.4
    var L = o
    while L > BankLo + 16:
      let w = L - 16
      if dens(gold, w, 16, 0x80) >= 0.25 or dens(gold, w, 16, 0x00) >= 0.40 or
          pairRate(gold, w, 16) >= 0.45:
        L = w
      else:
        break
    var R = o + n
    while R + 16 <= BankHi:
      if dens(gold, R, 16, 0x80) >= 0.25 or dens(gold, R, 16, 0x00) >= 0.40 or
          pairRate(gold, R, 16) >= 0.45:
        R += 16
      else:
        break
    echo &"  seed {o:06X}+{n} → expand {L:06X}+{R-L} dens80={dens(gold,L,R-L,0x80):.2f} dens00={dens(gold,L,R-L,0x00):.2f} pair={pairRate(gold,L,R-L):.2f}"
    echo &"    alph={alphabet(gold,L,min(R-L, 256))}"
    # free inside expand
    var fi = 0
    for i in L ..< R:
      if kindAt(chunks, i).startsWith("ckUnclaimed"): fi += 1
    echo &"    freeInside={fi}"

when isMainModule:
  main()
