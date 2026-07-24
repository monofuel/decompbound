## Emit residual-only claims for 98% push.
## Hard gate: free residual only (no code_spans overlap).

import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, text_decode, action_script, memmap]

const
  MaxTermRec = 32
  MinSingleTerm = 3
  MinFarChain = 3
  MaxZeroRec = 16
  MinZeroRecs = 2
  MinPlane = 20
  PlanePairMinRatio = 0.50
  MinU16Mono = 5
  MinCmdPairs = 8
  MinSeqLen = 12

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
  ## Build residual-only claim list for wave98.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var invClaimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)
      mark(invClaimed, c.offset, c.length)

  var total = 0
  var spanCount = 0
  var totals: Table[string, int]
  var nSpans: Table[string, int]

  echo "  # --- residual wave98: fe/fd/seq/plane/cmd/far/u16/as/z/w4 ---"

  # --- FE multi ---
  block:
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
        while k < g.len and not claimed[k] and g[k] != 0xFE and (k - pos) < MaxTermRec:
          k += 1
        if k >= g.len or claimed[k] or g[k] != 0xFE:
          break
        let recLen = k - pos + 1
        if recLen < 2 or recLen > MaxTermRec:
          break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4 and isFree(claimed, start, n):
        var fe = 0
        for j in 0 ..< n:
          if g[start + j] == 0xFE: fe += 1
        if fe == recs and fe * 3 <= n * 2 and fe < n:
          emit("ekTable", &"table_feRec_0x{start:06X}", start, n,
            "FE-terminated short-record residual (2..32B/rec, multi); free only")
          mark(claimed, start, n)
          bump(totals, nSpans, "feRec", n, total, spanCount)
          o = pos
          continue
      o += 1

  # --- FE single ---
  block:
    var o = 0
    while o < g.len:
      if claimed[o]:
        o += 1
        continue
      var k = o
      while k < g.len and not claimed[k] and g[k] != 0xFE and (k - o) < MaxTermRec:
        k += 1
      if k < g.len and not claimed[k] and g[k] == 0xFE:
        let n = k - o + 1
        if n >= MinSingleTerm and n <= MaxTermRec and isFree(claimed, o, n):
          var fe, hi, z = 0
          for j in 0 ..< n:
            if g[o + j] == 0xFE: fe += 1
            if g[o + j] >= 0xE0: hi += 1
            if g[o + j] == 0: z += 1
          if fe == 1 and hi * 2 <= n and z * 3 <= n:
            emit("ekTable", &"table_feRec_0x{o:06X}", o, n,
              "FE-terminated short-record residual (single 3..32B); free only")
            mark(claimed, o, n)
            bump(totals, nSpans, "feRec", n, total, spanCount)
            o = k + 1
            continue
      o += 1

  # --- FD multi ---
  block:
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
        while k < g.len and not claimed[k] and g[k] != 0xFD and (k - pos) < MaxTermRec:
          k += 1
        if k >= g.len or claimed[k] or g[k] != 0xFD:
          break
        let recLen = k - pos + 1
        if recLen < 2 or recLen > MaxTermRec:
          break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4 and isFree(claimed, start, n):
        var fd = 0
        for j in 0 ..< n:
          if g[start + j] == 0xFD: fd += 1
        if fd == recs and fd * 3 <= n * 2 and fd < n:
          emit("ekTable", &"table_fdRec_0x{start:06X}", start, n,
            "FD-terminated short-record residual (2..32B/rec, multi); free only")
          mark(claimed, start, n)
          bump(totals, nSpans, "fdRec", n, total, spanCount)
          o = pos
          continue
      o += 1


  # --- FD single quality ---
  block:
    var o = 0
    while o < g.len:
      if claimed[o]:
        o += 1
        continue
      var k = o
      while k < g.len and not claimed[k] and g[k] != 0xFD and (k - o) < MaxTermRec:
        k += 1
      if k < g.len and not claimed[k] and g[k] == 0xFD:
        let n = k - o + 1
        if n >= MinSingleTerm and n <= MaxTermRec and isFree(claimed, o, n):
          var fd, hi, z = 0
          for j in 0 ..< n:
            if g[o + j] == 0xFD: fd += 1
            if g[o + j] >= 0xE0: hi += 1
            if g[o + j] == 0: z += 1
          if fd == 1 and hi * 2 <= n and z * 3 <= n:
            emit("ekTable", &"table_fdRec_0x{o:06X}", o, n,
              "FD-terminated short-record residual (single 3..32B); free only")
            mark(claimed, o, n)
            bump(totals, nSpans, "fdRec", n, total, spanCount)
            o = k + 1
            continue
      o += 1

  # --- seq E0 residual (N-SPC-like; audio.md instrument select 0xE0) ---
  for r in freeRuns(claimed):
    if r.n < MinSeqLen:
      continue
    var e0, notes, z, e0xx = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j].int
      if b == 0: z += 1
      elif b >= 0x80 and b <= 0xC7: notes += 1
      elif b >= 0xE0:
        e0 += 1
        if b == 0xE0 and j + 1 < r.n and g[r.o + j + 1] < 0x40:
          e0xx += 1
    if e0xx >= 1 and notes >= 3 and e0 >= 2 and z * 8 <= r.n and
        (notes + e0) * 4 >= r.n and isFree(claimed, r.o, r.n):
      emit("ekTable", &"table_seqE0_0x{r.o:06X}", r.o, r.n,
        "N-SPC-like sequence residual (≥1 E0 instrument, notes+controls); free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "seqE0", r.n, total, spanCount)

  # --- planePair ≥50% ---
  for r in freeRuns(claimed):
    if r.n < MinPlane:
      continue
    let nPairs = r.n div 2
    if nPairs < 12:
      continue
    var pairs = 0
    for i in 0 ..< nPairs:
      if g[r.o + i * 2] == g[r.o + i * 2 + 1]:
        pairs += 1
    if pairs.float / nPairs.float < PlanePairMinRatio:
      continue
    var any, ff = 0
    for j in 0 ..< r.n:
      if g[r.o + j] != 0: any += 1
      if g[r.o + j] == 0xFF: ff += 1
    if any == 0 or ff * 4 >= r.n:
      continue
    let n = nPairs * 2
    if not isFree(claimed, r.o, n):
      continue
    emit("ekTable", &"table_planePair_0x{r.o:06X}", r.o, n,
      "SNES bitplane-like residual (≥50% equal adjacent pairs); free only")
    mark(claimed, r.o, n)
    bump(totals, nSpans, "planePair", n, total, spanCount)

  # --- cmdPair: even stream, top-3 even-bytes cover ≥40%, min 16 ---
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
    if top.len > 1: cover += top[1].c
    if top.len > 2: cover += top[2].c
    if cover * 100 < np * 35:
      continue
    if top[0].c < 3:
      continue
    if u.len * 2 > np + np div 2:
      continue
    var pr = 0
    for j in 0 ..< r.n:
      if g[r.o + j] >= 0x20 and g[r.o + j] < 0x7F: pr += 1
    if pr * 2 > r.n:
      continue
    if not isFree(claimed, r.o, r.n):
      continue
    emit("ekTable", &"table_cmdPair_0x{r.o:06X}", r.o, r.n,
      "Command-pair residual (even stream, top-3 cover≥40%); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "cmdPair", r.n, total, spanCount)

  # --- AS residual with relaxed gates (MinLen4 / MinSig0 / ops≥2 ended) ---
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
      # long spans still need a signature byte somewhere
      if taken >= 12 and countSignatureBytes(g, r.o, taken) < 1:
        continue
      emit("ekActionScript", &"as_wave98_0x{r.o:06X}", r.o, taken,
        "Action-script residual (ended walks ops≥2, MinLen4); free only")
      mark(claimed, r.o, taken)
      bump(totals, nSpans, "as", taken, total, spanCount)

  # --- ss full + ssPrefix ---
  for r in freeRuns(claimed):
    if r.n < ScriptStreamMinLen:
      continue
    let consumed = consumeScriptStreamRun(g, r.o, r.n)
    if consumed >= ScriptStreamMinLen and isFree(claimed, r.o, consumed):
      emit("ekScriptStream", &"script_wave98_0x{r.o:06X}", r.o, consumed,
        "CC script residual free stream; free only")
      mark(claimed, r.o, consumed)
      bump(totals, nSpans, "ss", consumed, total, spanCount)

  for r in freeRuns(claimed):
    if r.n < ScriptStreamMinLen:
      continue
    let wFree = walkScriptStream(g, r.o, r.o + r.n)
    if wFree.badGlyphs != 0 or wFree.ended or wFree.length != r.n:
      continue
    if wFree.glyphs < ScriptStreamMinGlyphs:
      continue
    let totalTok = wFree.glyphs + wFree.controls
    if totalTok == 0:
      continue
    if wFree.glyphs.float / totalTok.float < ScriptStreamMinGlyphRatio:
      continue
    if r.o + r.n >= g.len or not invClaimed[r.o + r.n]:
      continue
    let wFull = walkScriptStream(g, r.o, min(r.o + ScriptStreamMaxLen, g.len))
    if not isGoodScriptStream(wFull) or wFull.length <= r.n:
      continue
    if not isFree(claimed, r.o, r.n):
      continue
    emit("ekScriptStream", &"script_ssPrefix_0x{r.o:06X}", r.o, r.n,
      &"CC script residual prefix of good stream (full ends @+{wFull.length}); free only cross-boundary")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "ssPrefix", r.n, total, spanCount)

  # --- far3 ≥3 ---
  for r in freeRuns(claimed):
    if r.n < MinFarChain * 3:
      continue
    var p = r.o
    while p + MinFarChain * 3 <= r.o + r.n:
      var q = p
      var good = 0
      while q + 3 <= r.o + r.n:
        let bk = g[q + 2].int
        if bk < 0xC0 or bk > 0xEF:
          break
        good += 1
        q += 3
      if good >= MinFarChain:
        let n = good * 3
        if isFree(claimed, p, n):
          emit("ekTable", &"table_far3_0x{p:06X}", p, n,
            "Far-ptr 3B residual chain (bank $C0–$EF, ≥3); free only")
          mark(claimed, p, n)
          bump(totals, nSpans, "far3", n, total, spanCount)
        p = q
      else:
        p += 1

  # --- far4 ≥3 ---
  for r in freeRuns(claimed):
    if r.n < MinFarChain * 4:
      continue
    var p = r.o
    while p + MinFarChain * 4 <= r.o + r.n:
      var q = p
      var good = 0
      while q + 4 <= r.o + r.n:
        let bk = g[q + 2].int
        if bk < 0xC0 or bk > 0xEF or g[q + 3] != 0:
          break
        good += 1
        q += 4
      if good >= MinFarChain:
        let n = good * 4
        if isFree(claimed, p, n):
          emit("ekTable", &"table_far4_0x{p:06X}", p, n,
            "Far-ptr 4B residual chain (bank $C0–$EF + 00, ≥3); free only")
          mark(claimed, p, n)
          bump(totals, nSpans, "far4", n, total, spanCount)
        p = q
      else:
        p += 1

  # --- zRec ≥2 ---
  block:
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
        while k < g.len and not claimed[k] and g[k] != 0 and (k - pos) < MaxZeroRec:
          k += 1
        if k >= g.len or claimed[k] or g[k] != 0:
          break
        let recLen = k - pos + 1
        if recLen < 2 or recLen > MaxZeroRec:
          break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= MinZeroRecs and n >= 4 and isFree(claimed, start, n):
        var zeros, hi, printable = 0
        for j in 0 ..< n:
          if g[start + j] == 0: zeros += 1
          if g[start + j] >= 0x80: hi += 1
          if g[start + j] >= 0x20 and g[start + j] < 0x7F: printable += 1
        if zeros == recs and hi * 3 <= n and printable * 2 >= n:
          emit("ekTable", &"table_zRec_0x{start:06X}", start, n,
            "00-terminated printable short-record residual (≥2 recs, 2..16B); free only")
          mark(claimed, start, n)
          bump(totals, nSpans, "zRec", n, total, spanCount)
          o = pos
          continue
      o += 1

  # --- u16mono ≥5 ---
  for r in freeRuns(claimed):
    if r.n < MinU16Mono * 2:
      continue
    var i = 0
    while i + MinU16Mono * 2 <= r.n:
      let base = r.o + i
      var cnt = 1
      var prev = g[base].int or (g[base + 1].int shl 8)
      var j = 2
      while i + j + 2 <= r.n:
        let v = g[base + j].int or (g[base + j + 1].int shl 8)
        if v < prev:
          break
        if v == 0 and prev == 0:
          break
        prev = v
        cnt += 1
        j += 2
      if cnt >= MinU16Mono and prev >= 0x100:
        let n = cnt * 2
        if isFree(claimed, base, n):
          emit("ekTable", &"table_u16mono_0x{base:06X}", base, n,
            "u16 LE non-decreasing residual ptr-like table (≥5); free only")
          mark(claimed, base, n)
          bump(totals, nSpans, "u16mono", n, total, spanCount)
          i += n
          continue
      i += 2

  # --- w4hi0 ≥2 ---
  for r in freeRuns(claimed):
    if r.n < 8 or r.n mod 4 != 0:
      continue
    let words = r.n div 4
    if words < 2:
      continue
    var zhi = 0
    for i in 0 ..< words:
      if g[r.o + i * 4 + 3] == 0:
        zhi += 1
    if zhi != words:
      continue
    var any = false
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        any = true
        break
    if not any or not isFree(claimed, r.o, r.n):
      continue
    emit("ekTable", &"table_w4hi0_0x{r.o:06X}", r.o, r.n,
      "4B-word residual with high byte 0 (≥2 words); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "w4hi0", r.n, total, spanCount)

  # --- const fill ≥4 ---
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
      emit("ekTable", &"table_constFill_0x{r.o:06X}", r.o, r.n,
        &"Constant-byte residual fill 0x{v:02X}; free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "constFill", r.n, total, spanCount)

  # --- zero ≥2 ---
  for r in freeRuns(claimed):
    if r.n < 2:
      continue
    var allZ = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        allZ = false
        break
    if allZ and isFree(claimed, r.o, r.n):
      emit("ekZeroPad", &"zero_wave98_0x{r.o:06X}", r.o, r.n,
        "Zero-pad residual free; free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "zeroPad", r.n, total, spanCount)

  echo &"  # WAVE98 TOTAL residual: {total} B in {spanCount} spans"
  var keys = newSeq[string]()
  for k in totals.keys: keys.add k
  keys.sort()
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}={totals[k]}/{nSpans[k]}"
  echo &"  # breakdown: {parts.join(\" \")}"
  echo &"  # expected coverage ~{97.00 + total.float * 100.0 / 3145728.0:.2f}%"

main()
