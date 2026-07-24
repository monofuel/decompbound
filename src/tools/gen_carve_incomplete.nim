## Wave106b: complete free residual records split by 1-4B false-positive code.
## High-confidence fixed patterns only (cfRec5 + free-majority right-extend termFF
## with anti-opcode heads). No left-extend. No CE far+00 (matches CMP/BEQ code).
## convert_all carves extracts out of code_spans on regen; inventory already carves
## via collectImplementedSpanMeta.carveSpanAroundHoles.
import
  std/[strformat, strutils, algorithm, tables],
  ../decompbound/[rom_chunks, baserom_extract]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len:
      c[o + j] = true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  var rs = -1
  var rl = 0
  for o in 0 ..< claimed.len:
    if not claimed[o]:
      if rs < 0:
        rs = o
        rl = 1
      else:
        rl += 1
    else:
      if rs >= 0:
        result.add (rs, rl)
        rs = -1
  if rs >= 0:
    result.add (rs, rl)

type
  Cand = object
    start, length, freeB, codeB: int
    family, note, kind: string

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  var isMeta = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset + c.length, isCode.len):
        isCode[i] = true
    if c.kind == ckImplementedMeta:
      for i in c.offset ..< min(c.offset + c.length, isMeta.len):
        isMeta[i] = true

  var cands: seq[Cand]

  proc counts(start, n: int): tuple[f, c: int] =
    var f, c = 0
    for i in start ..< start + n:
      if isMeta[i]: return (-1, -1)
      if not claimed[i]: f += 1
      elif isCode[i]: c += 1
      else: return (-1, -1)
    (f, c)

  proc push(start, n: int; family, note, kind: string) =
    if start < 0 or n <= 0 or start + n > g.len: return
    let (f, c) = counts(start, n)
    if f < 0: return
    if c == 0: return  # pure free residual-only
    cands.add Cand(start: start, length: n, freeB: f, codeB: c,
                   family: family, note: note, kind: kind)

  # ---- cfRec5 islands: free+code and pure-code subranges (≥1 rec free+code, ≥2 pure) ----
  block:
    var o = 0
    while o + 5 <= g.len:
      if g[o] == 0x0A and g[o+1] == 0x01 and g[o+2] == 0x00 and g[o+3] == 0x80:
        let start = o
        while o + 5 <= g.len and g[o] == 0x0A and g[o+1] == 0x01 and
              g[o+2] == 0x00 and g[o+3] == 0x80:
          o += 5
        let n = o - start
        var i = start
        while i < start + n:
          while i < start + n and isMeta[i]:
            i += 1
          if i >= start + n: break
          let s2 = i
          while i < start + n and not isMeta[i]:
            i += 1
          let len2 = i - s2
          if len2 mod 5 != 0 or len2 < 5: continue
          let (f, c) = counts(s2, len2)
          if f < 0 or c == 0: continue
          if f == 0 and len2 < 10: continue
          push(s2, len2, "cfRec5",
            &"cfRec5 0A01 0080+u8 free+false-code recs={len2 div 5}",
            "ekTable")
        continue
      o += 1

  # ---- free incomplete cfRec5 + RIGHT 1-4 code only ----
  for r in freeRuns(claimed):
    if r.n > 20: continue
    for right in 1..4:
      let endp = r.o + r.n + right
      if endp > g.len: continue
      var okSide = true
      for i in r.o + r.n ..< endp:
        if not isCode[i]: okSide = false
      if not okSide: continue
      for align in 0 .. min(4, max(0, r.n - 1)):
        let s = r.o + align
        let avail = endp - s
        if avail < 5 or avail mod 5 != 0: continue
        var ok = true
        var p = s
        while p + 5 <= endp:
          if not (g[p] == 0x0A and g[p+1] == 0x01 and g[p+2] == 0x00 and
                  g[p+3] == 0x80):
            ok = false
            break
          p += 5
        if ok and p == endp:
          push(s, endp - s, "cfRec5",
            &"cfRec5 complete via {right}B false-code tail",
            "ekTable")
          break

  # ---- termFF: free ≥3 majority + RIGHT 1-4 ending FF; anti-opcode ----
  # Common 65816 single-byte ops and prefixes we refuse as free heads.
  let badHeads: set[uint8] = {0x00, 0x18, 0x20, 0x22, 0x38, 0x40, 0x48, 0x4C,
    0x5C, 0x60, 0x68, 0x6B, 0x78, 0x80, 0xA0, 0xA2, 0xA9, 0xAD, 0xAE, 0xAF,
    0xC2, 0xE2, 0xEA, 0xF0, 0xF4, 0xFA, 0xFB}
  for r in freeRuns(claimed):
    if r.n < 3 or r.n > 15: continue
    for right in 1..4:
      let start = r.o
      let endp = r.o + r.n + right
      if endp > g.len: continue
      var okSide = true
      for i in r.o + r.n ..< endp:
        if not isCode[i]: okSide = false
      if not okSide: continue
      if g[endp - 1] != 0xFF: continue
      let n = endp - start
      if n < 4 or n > 16: continue
      if r.n * 2 < n: continue
      if g[start] in badHeads: continue
      var tc, zc, hi = 0
      for i in start ..< endp:
        if g[i] == 0xFF: tc += 1
        if g[i] == 0: zc += 1
        if g[i] >= 0xE0 and g[i] != 0xFF: hi += 1
      if tc != 1: continue
      if zc * 3 > n: continue
      if hi * 2 > n: continue
      # no 0x20/22/5C (JSR/JSL/JML) anywhere in free portion
      var hasJmp = false
      for i in start ..< r.o + r.n:
        if g[i] in {0x20'u8, 0x22, 0x5C, 0x4C}:
          hasJmp = true
      if hasJmp: continue
      push(start, n, "termFF",
        &"FF-term rec complete via {right}B false-code tail",
        "ekTable")

  # dedupe
  cands.sort(proc(a, b: Cand): int =
    result = cmp(a.start, b.start)
    if result == 0: result = cmp(b.length, a.length))
  var kept: seq[Cand]
  var covered = newSeq[bool](g.len)
  for c in cands:
    var hit = false
    for i in c.start ..< c.start + c.length:
      if covered[i]:
        hit = true
        break
    if hit: continue
    for i in c.start ..< c.start + c.length:
      covered[i] = true
    kept.add c

  var freeTot, codeTot = 0
  var byFam: CountTable[string]
  var freeBy: CountTable[string]
  for c in kept:
    freeTot += c.freeB
    codeTot += c.codeB
    byFam.inc c.family
    freeBy.inc c.family, max(c.freeB, 0)

  echo &"# wave106b carve: {kept.len} spans free={freeTot} code={codeTot} total={freeTot+codeTot}"
  for k, v in byFam.pairs:
    echo &"#   {k}: spans={v} free={freeBy[k]}"

  echo "  # --- residual wave106b: incomplete free + false-code complete records ---"
  for c in kept:
    let name = &"table_{c.family}_carve_w106b_0x{c.start:06X}"
    echo &"""  BaseromExtractSpan(
    name: "{name}",
    offset: 0x{c.start:06X},
    length: {c.length},
    kind: {c.kind},
    note: "{c.note}; wave106b"),"""

main()
