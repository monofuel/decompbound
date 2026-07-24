## Find free residual incomplete known records completed by 1-4 adjacent false-code bytes.
## Also scan multi-rec islands of known patterns sitting in code_spans.
import
  std/[strformat, strutils, tables, algorithm],
  ../decompbound/[rom_chunks, baserom_extract, generated/code_spans, text_decode,
                  action_script]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len:
      c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len: return false
  for j in 0 ..< n:
    if claimed[o + j]: return false
  true

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
    family: string
    note: string

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
  proc addCand(start, length: int; family, note: string) =
    if start < 0 or length <= 0 or start + length > g.len: return
    var f, c, m = 0
    for i in start ..< start + length:
      if not claimed[i]: f += 1
      elif isCode[i]: c += 1
      else: m += 1
    # only accept if we take free + code (no meta steal; meta already correct)
    if m > 0: return
    if f == 0: return  # pure code reclass is label-only; still useful but separate
    if c == 0: return  # pure free already claimable residual-only
    if c > 4 and f + c > 20:
      # allow larger island reclass only if free is substantial
      discard
    elif c > 4:
      return
    # ensure free+code cover entire span and sides are only free/code
    for i in start ..< start + length:
      if isMeta[i]: return
    cands.add Cand(start: start, length: length, freeB: f, codeB: c,
                   family: family, note: note)

  # ---- family: cfRec5 = 0A 01 00 80 xx ----
  for r in freeRuns(claimed):
    for left in 0..4:
      for right in 0..4:
        if left + right == 0: continue
        if left + right > 4: continue
        let start = r.o - left
        let endp = r.o + r.n + right
        if start < 0 or endp > g.len: continue
        var okSide = true
        for i in start ..< r.o:
          if not isCode[i]: okSide = false
        for i in r.o + r.n ..< endp:
          if not isCode[i]: okSide = false
        if not okSide: continue
        let n = endp - start
        if n < 5 or n mod 5 != 0: continue
        var ok = true
        var p = start
        while p + 5 <= endp:
          if not (g[p] == 0x0A and g[p+1] == 0x01 and g[p+2] == 0x00 and
                  g[p+3] == 0x80):
            ok = false
            break
          p += 5
        if ok and p == endp:
          addCand(start, n, "cfRec5",
            &"complete 0A01 0080+u8 rec; free incomplete + {left+right}B false code")

  # ---- family: far3 = lo≠0 bank C0-EF, ≥1 rec completed by code ----
  for r in freeRuns(claimed):
    if r.n > 16: continue
    for left in 0..2:
      for right in 0..2:
        if left + right == 0: continue
        if left + right > 3: continue
        let start = r.o - left
        let endp = r.o + r.n + right
        if start < 0 or endp > g.len: continue
        var okSide = true
        for i in start ..< r.o:
          if not isCode[i]: okSide = false
        for i in r.o + r.n ..< endp:
          if not isCode[i]: okSide = false
        if not okSide: continue
        let n = endp - start
        if n < 3 or n mod 3 != 0: continue
        var ok = true
        var p = start
        while p + 3 <= endp:
          let lo = g[p].int or (g[p+1].int shl 8)
          let b = g[p+2]
          if b < 0xC0 or b > 0xEF or lo == 0:
            ok = false
            break
          p += 3
        if ok and p == endp:
          addCand(start, n, "far3",
            &"complete far3; free incomplete + {left+right}B false code")

  # ---- family: far4 = far3 + 00 pad ----
  for r in freeRuns(claimed):
    if r.n > 16: continue
    for left in 0..3:
      for right in 0..3:
        if left + right == 0: continue
        if left + right > 4: continue
        let start = r.o - left
        let endp = r.o + r.n + right
        if start < 0 or endp > g.len: continue
        var okSide = true
        for i in start ..< r.o:
          if not isCode[i]: okSide = false
        for i in r.o + r.n ..< endp:
          if not isCode[i]: okSide = false
        if not okSide: continue
        let n = endp - start
        if n < 4 or n mod 4 != 0: continue
        var ok = true
        var p = start
        while p + 4 <= endp:
          let lo = g[p].int or (g[p+1].int shl 8)
          let b = g[p+2]
          if b < 0xC0 or b > 0xEF or lo == 0 or g[p+3] != 0:
            ok = false
            break
          p += 4
        if ok and p == endp:
          addCand(start, n, "far4",
            &"complete far+00; free incomplete + {left+right}B false code")

  # ---- family: bitFlag {00,01,80} min3 completed ----
  for r in freeRuns(claimed):
    if r.n > 12: continue
    for left in 0..2:
      for right in 0..2:
        if left + right == 0: continue
        if left + right > 2: continue
        let start = r.o - left
        let endp = r.o + r.n + right
        if start < 0 or endp > g.len: continue
        var okSide = true
        for i in start ..< r.o:
          if not isCode[i]: okSide = false
        for i in r.o + r.n ..< endp:
          if not isCode[i]: okSide = false
        if not okSide: continue
        let n = endp - start
        if n < 3: continue
        var ok = true
        for i in start ..< endp:
          let v = g[i]
          if v != 0 and v != 1 and v != 0x80:
            ok = false
            break
        if ok:
          addCand(start, n, "bitFlag",
            &"bitFlag alphabet complete; free + {left+right}B false code")

  # ---- family: term FF short rec (2..16) completed by code ----
  for r in freeRuns(claimed):
    if r.n < 1 or r.n > 16: continue
    # free ends mid-rec; right overhang hits FF terminator in code
    for right in 1..4:
      let start = r.o
      let endp = r.o + r.n + right
      if endp > g.len: continue
      var okSide = true
      for i in r.o + r.n ..< endp:
        if not isCode[i]: okSide = false
      if not okSide: continue
      # must end with FF and pack as single term rec 2..16
      if g[endp - 1] != 0xFF: continue
      let n = endp - start
      if n < 2 or n > 16: continue
      # quality: exactly one FF at end, not all FF, sparse zeros
      var tc, zc, hi = 0
      for i in start ..< endp:
        if g[i] == 0xFF: tc += 1
        if g[i] == 0: zc += 1
        if g[i] >= 0xE0: hi += 1
      if tc != 1: continue
      if zc * 3 > n: continue
      if hi * 2 > n: continue
      addCand(start, n, "termFF",
        &"FF-term rec complete via {right}B false code tail")

  # ---- family: const ≥2 completed ----
  for r in freeRuns(claimed):
    if r.n > 8: continue
    for left in 0..2:
      for right in 0..2:
        if left + right == 0: continue
        if left + right > 2: continue
        let start = r.o - left
        let endp = r.o + r.n + right
        if start < 0 or endp > g.len: continue
        var okSide = true
        for i in start ..< r.o:
          if not isCode[i]: okSide = false
        for i in r.o + r.n ..< endp:
          if not isCode[i]: okSide = false
        if not okSide: continue
        let n = endp - start
        if n < 2: continue
        let v = g[start]
        if v == 0: continue  # zeroPad separate
        var ok = true
        for i in start ..< endp:
          if g[i] != v: ok = false
        if ok:
          addCand(start, n, "const",
            &"const-byte complete via {left+right}B false code")

  # ---- family: zero pad completed ----
  for r in freeRuns(claimed):
    if r.n > 8: continue
    for left in 0..2:
      for right in 0..2:
        if left + right == 0: continue
        if left + right > 2: continue
        let start = r.o - left
        let endp = r.o + r.n + right
        if start < 0 or endp > g.len: continue
        var okSide = true
        for i in start ..< r.o:
          if not isCode[i]: okSide = false
        for i in r.o + r.n ..< endp:
          if not isCode[i]: okSide = false
        if not okSide: continue
        let n = endp - start
        if n < 2: continue
        var ok = true
        for i in start ..< endp:
          if g[i] != 0: ok = false
        if ok:
          addCand(start, n, "zero",
            &"zero-pad complete via {left+right}B false code")

  # ---- family: CE62EE-style 5B [far][00][type] ----
  for r in freeRuns(claimed):
    if r.n > 16: continue
    for left in 0..4:
      for right in 0..4:
        if left + right == 0: continue
        if left + right > 4: continue
        let start = r.o - left
        let endp = r.o + r.n + right
        if start < 0 or endp > g.len: continue
        var okSide = true
        for i in start ..< r.o:
          if not isCode[i]: okSide = false
        for i in r.o + r.n ..< endp:
          if not isCode[i]: okSide = false
        if not okSide: continue
        let n = endp - start
        if n < 5 or n mod 5 != 0: continue
        var ok = true
        var p = start
        while p + 5 <= endp:
          let lo = g[p].int or (g[p+1].int shl 8)
          let b = g[p+2]
          if b < 0xC0 or b > 0xEF or lo == 0 or g[p+3] != 0:
            ok = false
            break
          # type byte any
          p += 5
        if ok and p == endp:
          addCand(start, n, "ce5far",
            &"CE-style 5B far+00+type complete + {left+right}B false code")

  # ---- also: pure-code island reclass of known multi-rec patterns with free holes nearby ----
  # walk full cfRec5 islands and claim free+code pieces (skip meta interiors)
  block:
    var o = 0
    while o + 5 <= g.len:
      if g[o] == 0x0A and g[o+1] == 0x01 and g[o+2] == 0x00 and g[o+3] == 0x80:
        let start = o
        var recs = 0
        while o + 5 <= g.len and g[o] == 0x0A and g[o+1] == 0x01 and
              g[o+2] == 0x00 and g[o+3] == 0x80:
          recs += 1
          o += 5
        let n = recs * 5
        # find contiguous free+code subranges inside island (split on meta)
        var i = start
        while i < start + n:
          while i < start + n and isMeta[i]:
            i += 1
          if i >= start + n: break
          let s2 = i
          var f, c = 0
          while i < start + n and not isMeta[i]:
            if not claimed[i]: f += 1
            elif isCode[i]: c += 1
            i += 1
          let len2 = i - s2
          if f > 0 and c > 0 and len2 mod 5 == 0 and len2 >= 5:
            # allow larger code overhang for contiguous table island
            cands.add Cand(start: s2, length: len2, freeB: f, codeB: c,
              family: "cfRec5island",
              note: &"cfRec5 island free+false-code; recs={len2 div 5}")
        continue
      o += 1

  # dedupe by span
  cands.sort(proc(a, b: Cand): int =
    result = cmp(a.start, b.start)
    if result == 0: result = cmp(b.length, a.length))
  var kept: seq[Cand]
  var covered = newSeq[bool](g.len)
  for c in cands:
    var overlap = false
    for i in c.start ..< c.start + c.length:
      if covered[i]:
        overlap = true
        break
    if overlap: continue
    # prefer larger
    for i in c.start ..< c.start + c.length:
      covered[i] = true
    kept.add c

  var byFam: CountTable[string]
  var freeTot, codeTot, n = 0
  echo "=== candidates (deduped, free+code only) ==="
  for c in kept:
    byFam.inc c.family
    freeTot += c.freeB
    codeTot += c.codeB
    n += 1
    if n <= 60:
      echo &"  {c.family} 0x{c.start:06X}+{c.length} free={c.freeB} code={c.codeB}  {c.note}"
  echo &"total cands={kept.len} freeBytes={freeTot} codeBytes={codeTot} claimBytes={freeTot+codeTot}"
  echo "by family:"
  for k, v in byFam.pairs:
    echo &"  {k}: {v}"

  # emit nim spans for patch
  echo "\n=== EMIT ==="
  for c in kept:
    let kind = if c.family == "zero": "ekZeroPad" else: "ekTable"
    let name = &"table_{c.family}_carve_0x{c.start:06X}"
    echo &"""  BaseromExtractSpan(
    name: "{name}",
    offset: 0x{c.start:06X},
    length: {c.length},
    kind: {kind},
    note: "{c.note}; free+false-code carve"),"""

main()
