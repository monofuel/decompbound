## Emit residual-only claims for 97% push wave:
##  - ffRec 2..32 B/rec (multi + quality single ≥3)
##  - script residual prefixes (good full stream ends past free into claimed)
##  - far-ptr 3B residual chains ≥4
##  - 00-terminated printable short-rec multi ≥3
##  - residual 4B words with high byte 0 (≥4 words)
## Hard gate: free residual only (no code_spans overlap).

import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, text_decode, memmap]

const
  MaxFfRec = 32
  MinSingleFf = 3
  MinFarChain = 4
  MaxZeroRec = 12
  MinZeroRecs = 3

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

proc main() =
  ## Build residual-only claim list for this wave.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var invClaimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)
      mark(invClaimed, c.offset, c.length)

  var total = 0
  var nSpans = 0
  var ffTot, ssTot, farTot, zTot, w4Tot = 0

  echo "  # --- residual wave97: ffRec≤32 + ssPrefix + far3 + zRec + w4hi0 ---"

  # 1) FF-terminated short records, rec len 2..32, ≥2 recs.
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
        while k < g.len and not claimed[k] and g[k] != 0xFF and (k - pos) < MaxFfRec:
          k += 1
        if k >= g.len or claimed[k] or g[k] != 0xFF:
          break
        let recLen = k - pos + 1
        if recLen < 2 or recLen > MaxFfRec:
          break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4 and isFree(claimed, start, n):
        var ff = 0
        for j in 0 ..< n:
          if g[start + j] == 0xFF:
            ff += 1
        if ff * 3 <= n * 2 and ff == recs and ff < n:
          emit("ekTable", &"table_ffRec_0x{start:06X}", start, n,
            "FF-terminated short-record residual (2..32B/rec, multi); free only")
          mark(claimed, start, n)
          total += n
          nSpans += 1
          ffTot += n
          o = pos
          continue
      o += 1

  # 2) Single FF-terminated records (quality gated, min 3).
  block:
    var o = 0
    while o < g.len:
      if claimed[o]:
        o += 1
        continue
      var k = o
      while k < g.len and not claimed[k] and g[k] != 0xFF and (k - o) < MaxFfRec:
        k += 1
      if k < g.len and not claimed[k] and g[k] == 0xFF:
        let n = k - o + 1
        if n >= MinSingleFf and n <= MaxFfRec and isFree(claimed, o, n):
          var ff = 0
          var hi = 0
          var z = 0
          for j in 0 ..< n:
            if g[o + j] == 0xFF: ff += 1
            if g[o + j] >= 0xE0: hi += 1
            if g[o + j] == 0: z += 1
          if ff == 1 and hi * 2 <= n and z * 3 <= n:
            emit("ekTable", &"table_ffRec_0x{o:06X}", o, n,
              "FF-terminated short-record residual (single 3..32B); free only")
            mark(claimed, o, n)
            total += n
            nSpans += 1
            ffTot += n
            o = k + 1
            continue
      o += 1

  # 3) Script residual prefixes.
  block:
    for r in freeRuns(claimed):
      if r.n < ScriptStreamMinLen:
        continue
      let wFree = walkScriptStream(g, r.o, r.o + r.n)
      if wFree.badGlyphs != 0:
        continue
      if wFree.ended:
        continue
      if wFree.length != r.n:
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
      if not isGoodScriptStream(wFull):
        continue
      if wFull.length <= r.n:
        continue
      if not isFree(claimed, r.o, r.n):
        continue
      emit("ekScriptStream", &"script_ssPrefix_0x{r.o:06X}", r.o, r.n,
        &"CC script residual prefix of good stream (full ends @+{wFull.length}); free only cross-boundary")
      mark(claimed, r.o, r.n)
      total += r.n
      nSpans += 1
      ssTot += r.n

  # 4) Far-ptr 3B residual chains (bank $C0–$EF), ≥4 consecutive.
  block:
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
              "Far-ptr 3B residual chain (bank $C0–$EF); free only")
            mark(claimed, p, n)
            total += n
            nSpans += 1
            farTot += n
          p = q
        else:
          p += 1

  # 5) 00-terminated printable short records (≥3 recs, 2..12 B/rec).
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
        while k < g.len and not claimed[k] and g[k] != 0 and
            (k - pos) < MaxZeroRec:
          k += 1
        if k >= g.len or claimed[k] or g[k] != 0:
          break
        let recLen = k - pos + 1
        if recLen < 2 or recLen > MaxZeroRec:
          break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= MinZeroRecs and n >= 6 and isFree(claimed, start, n):
        var zeros = 0
        var hi = 0
        var printable = 0
        for j in 0 ..< n:
          if g[start + j] == 0: zeros += 1
          if g[start + j] >= 0x80: hi += 1
          if g[start + j] >= 0x20 and g[start + j] < 0x7F: printable += 1
        if zeros == recs and hi * 3 <= n and printable * 2 >= n:
          emit("ekTable", &"table_zRec_0x{start:06X}", start, n,
            "00-terminated printable short-record residual (≥3 recs, 2..12B); free only")
          mark(claimed, start, n)
          total += n
          nSpans += 1
          zTot += n
          o = pos
          continue
      o += 1

  # 6) 4-byte words with high byte 0, ≥4 words, full free run.
  block:
    for r in freeRuns(claimed):
      if r.n < 16 or r.n mod 4 != 0:
        continue
      let words = r.n div 4
      if words < 4:
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
      if not any:
        continue
      if not isFree(claimed, r.o, r.n):
        continue
      emit("ekTable", &"table_w4hi0_0x{r.o:06X}", r.o, r.n,
        "4B-word residual with high byte 0 (≥4 words); free only")
      mark(claimed, r.o, r.n)
      total += r.n
      nSpans += 1
      w4Tot += r.n

  echo &"  # WAVE97 TOTAL residual: {total} B in {nSpans} spans " &
    &"(ffRec={ffTot} ssPrefix={ssTot} far3={farTot} zRec={zTot} w4hi0={w4Tot})"
  echo &"  # expected coverage ~{96.62 + total.float * 100.0 / 3145728.0:.2f}%"

main()
