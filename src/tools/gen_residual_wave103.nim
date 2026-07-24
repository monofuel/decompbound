## Emit residual-only claims for wave103 (post-wave102 scraps).
## Hard gate: free residual only (no code_spans overlap).
## Honesty: ssPrefix (full good into claimed), mid-run far3 ≥1 (bank C0–EF,
## lo≠0), bitFlag alphabet ≥3, term F0–FF singles 3..32, fix4 min2 ≥40%
## bank/hi0, gfx_lz clean partial.

import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, text_decode, action_script, gfx_lz]

const
  MinFixRecs = 2
  MaxTermRec = 32
  MinTermRec = 3

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

proc isFar3(g: seq[uint8]; o: int): bool =
  let lo = g[o].int or (g[o + 1].int shl 8)
  let b = g[o + 2]
  result = b >= 0xC0 and b <= 0xEF and lo != 0

proc main() =
  ## Build residual-only claim list for wave103.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var total = 0
  var spanCount = 0
  var totals: Table[string, int]
  var nSpans: Table[string, int]

  echo "  # --- residual wave103: ssPrefix/far3mid/bit≥3/term1/fix4min2/gfx ---"

  # ssPrefix: free full run is incomplete CC stream of a good full walk
  for r in freeRuns(claimed):
    if r.n < ScriptStreamMinLen:
      continue
    let wFree = walkScriptStream(g, r.o, r.o + r.n)
    if wFree.badGlyphs != 0 or wFree.ended:
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
    if r.o + r.n >= g.len or claimed[r.o + r.n] == false:
      # must abut claimed inventory so full walk can cross
      if r.o + r.n >= g.len:
        continue
      if not claimed[r.o + r.n]:
        continue
    let wFull = walkScriptStream(g, r.o, min(r.o + ScriptStreamMaxLen, g.len))
    if not isGoodScriptStream(wFull):
      continue
    if wFull.length <= r.n:
      continue
    emit("ekScriptStream", &"script_ssPrefix_w103_0x{r.o:06X}", r.o, r.n,
      &"CC script residual prefix of good stream (full ends @+{wFull.length}); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "ssP", r.n, total, spanCount)

  # mid-run far3 chains ≥1 (bank $C0–$EF, lo≠0)
  for r in freeRuns(claimed):
    if r.n < 3:
      continue
    var i = 0
    while i + 3 <= r.n:
      if isFar3(g, r.o + i):
        var k = i
        while k + 3 <= r.n and isFar3(g, r.o + k):
          k += 3
        let n = k - i
        if n >= 3 and isFree(claimed, r.o + i, n):
          emit("ekTable", &"table_far3_w103_0x{r.o + i:06X}", r.o + i, n,
            "Far-ptr 3B residual mid-run (bank $C0–$EF, lo≠0); free only")
          mark(claimed, r.o + i, n)
          bump(totals, nSpans, "far3", n, total, spanCount)
        i = max(k, i + 1)
      else:
        i += 1

  # bitFlag alphabet {00,01,80} ≥3
  for r in freeRuns(claimed):
    if r.n < 3:
      continue
    var ok = true
    var nz = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if b notin [0x00u8, 0x01u8, 0x80u8]:
        ok = false
        break
      if b != 0:
        nz += 1
    if not ok or nz < 1:
      continue
    emit("ekTable", &"table_bitFlag_w103_0x{r.o:06X}", r.o, r.n,
      "Ternary flag residual alphabet {0x00,0x01,0x80} ≥3; free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "bit", r.n, total, spanCount)

  # term F0-FF singles 3..32
  for termByte in 0xF0 .. 0xFF:
    var o = 0
    while o < g.len:
      if claimed[o]:
        o += 1
        continue
      var k = o
      while k < g.len and not claimed[k] and g[k] != termByte.uint8 and
          (k - o) < MaxTermRec:
        k += 1
      if k < g.len and not claimed[k] and g[k] == termByte.uint8:
        let n = k - o + 1
        if n >= MinTermRec and n <= MaxTermRec and isFree(claimed, o, n):
          var tc = 0
          var hi = 0
          var z = 0
          for j in 0 ..< n:
            if g[o + j] == termByte.uint8:
              tc += 1
            if g[o + j] >= 0xE0:
              hi += 1
            if g[o + j] == 0:
              z += 1
          if tc == 1 and hi * 2 <= n and z * 3 <= n:
            emit("ekTable", &"table_term1_w103_0x{o:06X}", o, n,
              &"Terminator 0x{termByte:02X} single-rec residual 3..32; free only")
            mark(claimed, o, n)
            bump(totals, nSpans, "term1", n, total, spanCount)
            o = k + 1
            continue
      o += 1

  # fix4 min2 ≥40% bank@+2 or hi0@+3
  for r in freeRuns(claimed):
    if r.n < MinFixRecs * 4:
      continue
    for align in 0 .. 3:
      let nRec = (r.n - align) div 4
      if nRec < MinFixRecs:
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
      if zhi * 5 < nRec * 2 and banks * 5 < nRec * 2:
        continue
      emit("ekTable", &"table_fix4_w103_0x{base:06X}", base, n,
        "Fixed 4B residual (≥40% hi0/bank, ≥2 recs); free only")
      mark(claimed, base, n)
      bump(totals, nSpans, "fix4", n, total, spanCount)
      break

  # gfx_lz clean consume ≥4
  for r in freeRuns(claimed):
    if r.n < 4:
      continue
    let slice = g[r.o ..< r.o + r.n]
    let (data, consumed, clean) = decodeWithConsumed(slice)
    if not clean or consumed < 4 or consumed > r.n or data.len < 16:
      continue
    if not isFree(claimed, r.o, consumed):
      continue
    emit("ekGfxLz", &"gfxLz_wave103_0x{r.o:06X}", r.o, consumed,
      "gfx_lz residual free head; clean terminate; free only")
    mark(claimed, r.o, consumed)
    bump(totals, nSpans, "gfx", consumed, total, spanCount)

  var rem = 0
  var rn = 0
  for r in freeRuns(claimed):
    rem += r.n
    rn += 1

  echo &"  # WAVE103 TOTAL residual: {total} B in {spanCount} spans"
  var keys: seq[string] = @[]
  for k in totals.keys:
    keys.add k
  keys.sort()
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}={totals[k]}/{nSpans[k]}"
  echo &"  # breakdown: {parts.join(\" \")}"
  echo &"  # residual left after wave103: {rem} B in {rn} runs"
  let exact = (3145728 - rem).float * 100.0 / 3145728.0
  echo &"  # expected coverage ~{exact:.2f}%"

main()
