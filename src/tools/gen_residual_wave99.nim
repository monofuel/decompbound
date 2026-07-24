## Emit residual-only claims for 99% push.
## Hard gate: free residual only (no code_spans overlap).

import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, text_decode, action_script]

const
  MinU8PairRecs = 8
  U8PairOkRatio = 65
  MinCountN = 6
  MaxCount = 100
  MinSmoothRecs = 8
  MinFix3Recs = 6
  MinFix4Recs = 6
  MinFar3 = 2
  MaxTermRec = 48
  MinCmdPairs = 6
  MinPlane = 16
  PlanePairMinRatio = 0.35
  MinSeqLen = 8
  MinU16Words = 8
  MinU8Lo = 12
  MinLowEnt = 20

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len:
      c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len:
    return false
  for j in 0 ..< n:
    if claimed[o + j]:
      return false
  true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  result = @[]
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

proc emit(kind, name: string; o, n: int; note: string) =
  echo &"""  BaseromExtractSpan(
    name: "{name}",
    offset: 0x{o:06X},
    length: {n},
    kind: {kind},
    note: "{note}"),"""

proc bump(totals: var Table[string, int]; nSpans: var Table[string, int];
          key: string; n: int; total: var int; spanCount: var int) =
  if key notin totals:
    totals[key] = 0
    nSpans[key] = 0
  totals[key] = totals[key] + n
  nSpans[key] = nSpans[key] + 1
  total += n
  spanCount += 1

proc main() =
  ## Build residual-only claim list for wave99.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var total = 0
  var spanCount = 0
  var totals: Table[string, int]
  var nSpans: Table[string, int]

  echo "  # --- residual wave99: u8pair/countN/u16/smooth/fix/term/cmd/seq/as ---"

  # --- u8pair: 2B records, ≥65% have a field ≤0x40 ---
  for r in freeRuns(claimed):
    if r.n < 16 or r.n mod 2 != 0:
      continue
    let nRec = r.n div 2
    if nRec < MinU8PairRecs:
      continue
    var ok, nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o + i * 2]
      let b = g[r.o + i * 2 + 1]
      if a <= 0x40 or b <= 0x40:
        ok += 1
      if a != 0 or b != 0:
        nz += 1
    if ok * 100 < nRec * U8PairOkRatio:
      continue
    if nz * 4 < nRec * 3:
      continue
    if not isFree(claimed, r.o, r.n):
      continue
    emit("ekTable", &"table_u8pair_0x{r.o:06X}", r.o, r.n,
      "u8-pair residual table (≥65% range-limited field ≤0x40); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "u8pair", r.n, total, spanCount)

  # --- countN mid-scan: [u8|u16 count] + count*stride ---
  const strides = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 17, 25, 27, 41]
  for r in freeRuns(claimed):
    if r.n < MinCountN:
      continue
    var i = 0
    while i < r.n:
      if not isFree(claimed, r.o + i, 1):
        i += 1
        continue
      var best = 0
      for hdr in 1 .. 2:
        for stride in strides:
          if i + hdr > r.n:
            continue
          let cnt =
            if hdr == 1:
              g[r.o + i].int
            else:
              if i + 1 >= r.n:
                continue
              g[r.o + i].int or (g[r.o + i + 1].int shl 8)
          if cnt < 2 or cnt > MaxCount:
            continue
          let need = hdr + cnt * stride
          if need < MinCountN or i + need > r.n:
            continue
          let rem = r.n - i
          if need < rem * 2 div 5 and need != rem:
            continue
          var z, nz = 0
          for j in hdr ..< need:
            if g[r.o + i + j] == 0:
              z += 1
            else:
              nz += 1
          if z * 2 > (need - hdr):
            continue
          if nz < 2:
            continue
          if need > best:
            best = need
      if best >= MinCountN and isFree(claimed, r.o + i, best):
        emit("ekTable", &"table_countN_0x{r.o + i:06X}", r.o + i, best,
          "count+N*stride residual record (u8/u16 count header); free only")
        mark(claimed, r.o + i, best)
        bump(totals, nSpans, "countN", best, total, spanCount)
        i += best
      else:
        i += 1

  # --- u16tab: even free, ≥40% hi-byte <0x40 ---
  for r in freeRuns(claimed):
    if r.n < MinU16Words * 2 or r.n mod 2 != 0:
      continue
    let words = r.n div 2
    if words < MinU16Words:
      continue
    var lohi, nz = 0
    for i in 0 ..< words:
      if g[r.o + i * 2 + 1] < 0x40:
        lohi += 1
      if g[r.o + i * 2] != 0 or g[r.o + i * 2 + 1] != 0:
        nz += 1
    if lohi * 5 < words * 2:
      continue
    if nz * 4 < words * 3:
      continue
    if not isFree(claimed, r.o, r.n):
      continue
    emit("ekTable", &"table_u16tab_0x{r.o:06X}", r.o, r.n,
      "u16 residual table (≥40% hi-byte <0x40); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "u16tab", r.n, total, spanCount)

  # --- smooth 3/4/5 curve tables ---
  for rec in [3, 4, 5]:
    for r in freeRuns(claimed):
      if r.n < rec * MinSmoothRecs:
        continue
      var bestO, bestN = 0
      for align in 0 ..< rec:
        let avail = r.n - align
        var nRec = avail div rec
        while nRec >= MinSmoothRecs:
          let n = nRec * rec
          let base = r.o + align
          if not isFree(claimed, base, n):
            nRec -= 1
            continue
          var small, totalCmp = 0
          for i in 1 ..< nRec:
            for j in 0 ..< rec:
              let a = g[base + (i - 1) * rec + j].int
              let b = g[base + i * rec + j].int
              totalCmp += 1
              if abs(a - b) <= 10:
                small += 1
          if small * 100 >= totalCmp * 50:
            var same = true
            for j in 0 ..< rec:
              if g[base + j] != g[base + rec + j]:
                same = false
            if not same and n > bestN:
              bestO = base
              bestN = n
            break
          nRec -= 1
      if bestN >= rec * MinSmoothRecs:
        emit("ekTable", &"table_smooth{rec}_0x{bestO:06X}", bestO, bestN,
          &"Smooth {rec}B-record residual curve/path (≥50% adj Δ≤10); free only")
        mark(claimed, bestO, bestN)
        bump(totals, nSpans, &"smooth{rec}", bestN, total, spanCount)

  # --- fix3 bank/type ≥50% ---
  for r in freeRuns(claimed):
    if r.n < MinFix3Recs * 3:
      continue
    for align in 0 .. 2:
      let nRec = (r.n - align) div 3
      if nRec < MinFix3Recs:
        continue
      let n = nRec * 3
      let base = r.o + align
      if not isFree(claimed, base, n):
        continue
      var banks, types, nz = 0
      for i in 0 ..< nRec:
        let b = g[base + i * 3 + 2].int
        if b >= 0xC0 and b <= 0xEF:
          banks += 1
        if b <= 0x0F:
          types += 1
        if g[base + i * 3] != 0 or g[base + i * 3 + 1] != 0 or
            g[base + i * 3 + 2] != 0:
          nz += 1
      if nz * 4 < nRec * 3:
        continue
      if banks * 2 < nRec and types * 2 < nRec:
        continue
      emit("ekTable", &"table_fix3_0x{base:06X}", base, n,
        "3B residual records (bank $C0–$EF or type≤0x0F ≥50%); free only")
      mark(claimed, base, n)
      bump(totals, nSpans, "fix3", n, total, spanCount)
      break

  # --- fix4 hi0/bank ≥50% ---
  for r in freeRuns(claimed):
    if r.n < MinFix4Recs * 4:
      continue
    for align in 0 .. 3:
      let nRec = (r.n - align) div 4
      if nRec < MinFix4Recs:
        continue
      let n = nRec * 4
      let base = r.o + align
      if not isFree(claimed, base, n):
        continue
      var zhi, banks, nz = 0
      for i in 0 ..< nRec:
        if g[base + i * 4 + 3] == 0:
          zhi += 1
        let b = g[base + i * 4 + 2].int
        if b >= 0xC0 and b <= 0xEF:
          banks += 1
        for j in 0 .. 3:
          if g[base + i * 4 + j] != 0:
            nz += 1
      if nz < nRec * 2:
        continue
      if zhi * 2 < nRec and banks * 2 < nRec:
        continue
      emit("ekTable", &"table_fix4_0x{base:06X}", base, n,
        "4B residual records (hi0 or bank@+2 ≥50%); free only")
      mark(claimed, base, n)
      bump(totals, nSpans, "fix4", n, total, spanCount)
      break

  # --- col-constrained fix 5..12 ---
  for rec in [5, 6, 7, 8, 9, 10, 12]:
    for r in freeRuns(claimed):
      if r.n < rec * 5:
        continue
      for align in 0 ..< min(rec, 4):
        let nRec = (r.n - align) div rec
        if nRec < 5:
          continue
        let n = nRec * rec
        let base = r.o + align
        if not isFree(claimed, base, n):
          continue
        var col0: CountTable[int]
        var nz = 0
        for i in 0 ..< nRec:
          col0.inc(g[base + i * rec].int)
          for j in 0 ..< rec:
            if g[base + i * rec + j] != 0:
              nz += 1
        if nz < n div 2:
          continue
        var tops: seq[int] = @[]
        for _, c in col0.pairs:
          tops.add c
        tops.sort(proc(a, b: int): int = cmp(b, a))
        var cover = 0
        for i in 0 ..< min(3, tops.len):
          cover += tops[i]
        if cover * 100 < nRec * 35:
          continue
        emit("ekTable", &"table_fix{rec}col_0x{base:06X}", base, n,
          &"{rec}B residual records (col0 top-3 cover≥35%); free only")
        mark(claimed, base, n)
        bump(totals, nSpans, &"fix{rec}col", n, total, spanCount)
        break

  # --- term multi F8-FC ---
  for termByte in [0xFC, 0xFB, 0xFA, 0xF9, 0xF8]:
    var o = 0
    while o < g.len:
      if claimed[o]:
        o += 1
        continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not claimed[pos]:
        var k = pos
        while k < g.len and not claimed[k] and g[k] != termByte.uint8 and
            (k - pos) < MaxTermRec:
          k += 1
        if k >= g.len or claimed[k] or g[k] != termByte.uint8:
          break
        let recLen = k - pos + 1
        if recLen < 2 or recLen > MaxTermRec:
          break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4 and isFree(claimed, start, n):
        var t = 0
        for j in 0 ..< n:
          if g[start + j] == termByte.uint8:
            t += 1
        if t == recs and t * 3 <= n * 2 and t < n:
          emit("ekTable", &"table_t{termByte:02X}_0x{start:06X}", start, n,
            &"0x{termByte:02X}-terminated short-record residual (2..48B); free only")
          mark(claimed, start, n)
          bump(totals, nSpans, &"t{termByte:02X}", n, total, spanCount)
          o = pos
          continue
      o += 1

  # --- plane ≥35% equal adjacent pairs ---
  for r in freeRuns(claimed):
    if r.n < MinPlane:
      continue
    let nPairs = r.n div 2
    if nPairs < 8:
      continue
    var pairs = 0
    for i in 0 ..< nPairs:
      if g[r.o + i * 2] == g[r.o + i * 2 + 1]:
        pairs += 1
    if pairs.float / nPairs.float < PlanePairMinRatio:
      continue
    var any, ff = 0
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        any += 1
      if g[r.o + j] == 0xFF:
        ff += 1
    if any == 0 or ff * 4 >= r.n:
      continue
    let n = nPairs * 2
    if not isFree(claimed, r.o, n):
      continue
    emit("ekTable", &"table_plane35_0x{r.o:06X}", r.o, n,
      "SNES bitplane-like residual (≥35% equal adjacent pairs); free only")
    mark(claimed, r.o, n)
    bump(totals, nSpans, "plane35", n, total, spanCount)

  # --- cmd top-3 even-bytes cover ≥22% ---
  for r in freeRuns(claimed):
    if r.n < MinCmdPairs * 2 or r.n mod 2 != 0:
      continue
    let np = r.n div 2
    var u: CountTable[int]
    for i in 0 ..< np:
      u.inc(g[r.o + i * 2].int)
    var top: seq[tuple[b, c: int]] = @[]
    for b, c in u.pairs:
      top.add (b, c)
    top.sort(proc(a, b: auto): int = cmp(b.c, a.c))
    if top.len < 2:
      continue
    var cover = top[0].c
    if top.len > 1:
      cover += top[1].c
    if top.len > 2:
      cover += top[2].c
    if cover * 100 < np * 22:
      continue
    if top[0].c < 2:
      continue
    var pr = 0
    for j in 0 ..< r.n:
      if g[r.o + j] >= 0x20 and g[r.o + j] < 0x7F:
        pr += 1
    if pr * 2 > r.n:
      continue
    if not isFree(claimed, r.o, r.n):
      continue
    emit("ekTable", &"table_cmd22_0x{r.o:06X}", r.o, r.n,
      "Command-pair residual (even stream, top-3 cover≥22%); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "cmd22", r.n, total, spanCount)

  # --- seqLoose N-SPC-like ---
  for r in freeRuns(claimed):
    if r.n < MinSeqLen:
      continue
    var e0, notes, z, e0xx = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j].int
      if b == 0:
        z += 1
      elif b >= 0x80 and b <= 0xC7:
        notes += 1
      elif b >= 0xE0:
        e0 += 1
        if b == 0xE0 and j + 1 < r.n and g[r.o + j + 1] < 0x40:
          e0xx += 1
    if e0xx >= 1 and notes >= 2 and e0 >= 1 and z * 5 <= r.n and
        (notes + e0) * 5 >= r.n and isFree(claimed, r.o, r.n):
      emit("ekTable", &"table_seqLoose_0x{r.o:06X}", r.o, r.n,
        "N-SPC-like sequence residual (loose E0/note density); free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "seqLoose", r.n, total, spanCount)

  # --- far3 ≥2 ---
  for r in freeRuns(claimed):
    if r.n < MinFar3 * 3:
      continue
    var p = r.o
    while p + MinFar3 * 3 <= r.o + r.n:
      var q = p
      var good = 0
      while q + 3 <= r.o + r.n:
        let bk = g[q + 2].int
        if bk < 0xC0 or bk > 0xEF:
          break
        good += 1
        q += 3
      if good >= MinFar3:
        let n = good * 3
        if isFree(claimed, p, n):
          emit("ekTable", &"table_far3w99_0x{p:06X}", p, n,
            "Far-ptr 3B residual chain (bank $C0–$EF, ≥2); free only")
          mark(claimed, p, n)
          bump(totals, nSpans, "far3", n, total, spanCount)
        p = q
      else:
        p += 1

  # --- AS residual ---
  for r in freeRuns(claimed):
    if r.n < 4:
      continue
    var pos = r.o
    var taken = 0
    while pos < r.o + r.n:
      let w = walkActionScript(g, pos, r.o + r.n)
      if w.ended and w.length >= 4 and w.ops >= 1 and pos + w.length <= r.o + r.n:
        taken += w.length
        pos += w.length
      else:
        break
    if taken >= 4 and isFree(claimed, r.o, taken):
      if taken >= 12 and countSignatureBytes(g, r.o, taken) < 1:
        continue
      emit("ekActionScript", &"as_wave99_0x{r.o:06X}", r.o, taken,
        "Action-script residual (ended walks ops≥1, MinLen4); free only")
      mark(claimed, r.o, taken)
      bump(totals, nSpans, "as", taken, total, spanCount)

  # --- SS residual ---
  for r in freeRuns(claimed):
    if r.n < ScriptStreamMinLen:
      continue
    let consumed = consumeScriptStreamRun(g, r.o, r.n)
    if consumed >= ScriptStreamMinLen and isFree(claimed, r.o, consumed):
      emit("ekScriptStream", &"script_wave99_0x{r.o:06X}", r.o, consumed,
        "CC script residual free stream; free only")
      mark(claimed, r.o, consumed)
      bump(totals, nSpans, "ss", consumed, total, spanCount)

  # --- u8lo ≥70% bytes ≤0x3F ---
  for r in freeRuns(claimed):
    if r.n < MinU8Lo:
      continue
    var lo, nz = 0
    for j in 0 ..< r.n:
      if g[r.o + j] <= 0x3F:
        lo += 1
      if g[r.o + j] != 0:
        nz += 1
    if lo * 10 < r.n * 7:
      continue
    if nz * 4 < r.n * 3:
      continue
    if not isFree(claimed, r.o, r.n):
      continue
    emit("ekTable", &"table_u8lo_0x{r.o:06X}", r.o, r.n,
      "Low-range u8 residual stream (≥70% bytes ≤0x3F); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "u8lo", r.n, total, spanCount)

  # --- stride2 ≥40% ---
  for r in freeRuns(claimed):
    if r.n < 16:
      continue
    var match = 0
    let lim = r.n - 2
    for j in 0 ..< lim:
      if g[r.o + j] == g[r.o + j + 2]:
        match += 1
    if match * 100 < lim * 40:
      continue
    var nz = 0
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        nz += 1
    if nz * 2 < r.n:
      continue
    if not isFree(claimed, r.o, r.n):
      continue
    emit("ekTable", &"table_stride2_0x{r.o:06X}", r.o, r.n,
      "Stride-2 residual (≥40% g[i]==g[i+2]); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "stride2", r.n, total, spanCount)

  # --- lowEnt top-6 cover ≥45% ---
  for r in freeRuns(claimed):
    if r.n < MinLowEnt:
      continue
    var u: CountTable[int]
    for j in 0 ..< r.n:
      u.inc(g[r.o + j].int)
    var top: seq[int] = @[]
    for _, c in u.pairs:
      top.add c
    top.sort(proc(a, b: int): int = cmp(b, a))
    var cover = 0
    for i in 0 ..< min(6, top.len):
      cover += top[i]
    if cover * 100 < r.n * 45:
      continue
    if u.len < 3 or u.len > r.n div 2:
      continue
    if not isFree(claimed, r.o, r.n):
      continue
    emit("ekTable", &"table_lowEnt_0x{r.o:06X}", r.o, r.n,
      "Low-entropy residual (top-6 cover≥45%); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "lowEnt", r.n, total, spanCount)

  # --- zero / const ---
  for r in freeRuns(claimed):
    if r.n < 2:
      continue
    var allZ = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        allZ = false
        break
    if allZ and isFree(claimed, r.o, r.n):
      emit("ekZeroPad", &"zero_wave99_0x{r.o:06X}", r.o, r.n,
        "Zero-pad residual free; free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "zeroPad", r.n, total, spanCount)

  for r in freeRuns(claimed):
    if r.n < 4:
      continue
    let v = g[r.o]
    if v == 0:
      continue
    var all = true
    for j in 1 ..< r.n:
      if g[r.o + j] != v:
        all = false
        break
    if all and isFree(claimed, r.o, r.n):
      emit("ekTable", &"table_constFill_w99_0x{r.o:06X}", r.o, r.n,
        &"Constant-byte residual fill 0x{v:02X}; free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "constFill", r.n, total, spanCount)

  echo &"  # WAVE99 TOTAL residual: {total} B in {spanCount} spans"
  var keys = newSeq[string]()
  for k in totals.keys:
    keys.add k
  keys.sort()
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}={totals[k]}/{nSpans[k]}"
  echo &"  # breakdown: {parts.join(\" \")}"
  echo &"  # expected coverage ~{98.02 + total.float * 100.0 / 3145728.0:.2f}%"

main()
