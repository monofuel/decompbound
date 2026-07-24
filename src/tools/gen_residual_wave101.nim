## Emit residual-only claims for wave101 (post-wave100b scraps).
## Hard gate: free residual only (no code_spans overlap).
## Honesty: pure zeros, AS walks, term F0-FF, u8pair, const≥2,
## pure far3 remainder (align 0-2 full rem), ternary 00/01/80 ≥4.

import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, action_script]

const
  MinU8PairRecs = 4
  U8PairOkRatio = 55
  U8PairFieldMax = 0x50
  MinAlphabet = 4
  MaxTermRec = 48

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
  ## Build residual-only claim list for wave101.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var total = 0
  var spanCount = 0
  var totals: Table[string, int]
  var nSpans: Table[string, int]

  echo "  # --- residual wave101: zero/as/term/u8pair/const/far3align/bitFlag ---"

  # pure zero free
  for r in freeRuns(claimed):
    var allZ = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        allZ = false
        break
    if not allZ:
      continue
    emit("ekZeroPad", &"zero_wave101_0x{r.o:06X}", r.o, r.n,
      "Zero-pad residual free; free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "zero", r.n, total, spanCount)

  # action-script full cover + good heads
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen:
      continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      emit("ekActionScript", &"as_wave101_0x{r.o:06X}", r.o, r.n,
        "Action-script residual full cover; free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "as", r.n, total, spanCount)
      continue
    let w = walkActionScript(g, r.o, r.o + r.n)
    if isGoodActionScriptWalk(w) and w.length >= ActionScriptMinLen and
        w.length <= r.n and isFree(claimed, r.o, w.length):
      if isGoodActionScriptSpan(g, r.o, w.length):
        emit("ekActionScript", &"as_wave101_0x{r.o:06X}", r.o, w.length,
          "Action-script residual good head; free only")
        mark(claimed, r.o, w.length)
        bump(totals, nSpans, "asHead", w.length, total, spanCount)

  # term F0-FF multi + quality singles
  for termByte in 0xF0 .. 0xFF:
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
        let rl = k - pos + 1
        if rl < 2 or rl > MaxTermRec:
          break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var tc = 0
        for j in 0 ..< n:
          if g[start + j] == termByte.uint8:
            tc += 1
        if tc == recs and isFree(claimed, start, n):
          emit("ekTable", &"table_term_w101_0x{start:06X}", start, n,
            &"Terminator 0x{termByte:02X} multi-rec residual; free only")
          mark(claimed, start, n)
          bump(totals, nSpans, "term", n, total, spanCount)
          o = pos
          continue
      if recs == 1 and n >= 4 and n <= 32:
        var tc = 0
        for j in 0 ..< n:
          if g[start + j] == termByte.uint8:
            tc += 1
        if tc == 1 and g[start + n - 1] == termByte.uint8 and
            isFree(claimed, start, n):
          emit("ekTable", &"table_term1_w101_0x{start:06X}", start, n,
            &"Terminator 0x{termByte:02X} single-rec residual; free only")
          mark(claimed, start, n)
          bump(totals, nSpans, "term1", n, total, spanCount)
          o = pos
          continue
      o += 1

  # u8pair ≥4
  for r in freeRuns(claimed):
    if r.n < MinU8PairRecs * 2 or r.n mod 2 != 0:
      continue
    let nRec = r.n div 2
    if nRec < MinU8PairRecs:
      continue
    var ok, nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o + i * 2]
      let b = g[r.o + i * 2 + 1]
      if a <= U8PairFieldMax.uint8 or b <= U8PairFieldMax.uint8:
        ok += 1
      if a != 0 or b != 0:
        nz += 1
    if ok * 100 < nRec * U8PairOkRatio:
      continue
    if nz * 2 < nRec:
      continue
    emit("ekTable", &"table_u8pair4_w101_0x{r.o:06X}", r.o, r.n,
      "u8-pair residual (≥55% field ≤0x50, ≥4 recs); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "u8pair", r.n, total, spanCount)

  # const ≥2 non-zero
  for r in freeRuns(claimed):
    if r.n < 2:
      continue
    let v = g[r.o]
    if v == 0:
      continue
    var same = true
    for j in 1 ..< r.n:
      if g[r.o + j] != v:
        same = false
        break
    if not same:
      continue
    emit("ekTable", &"table_constFill_w101_0x{r.o:06X}", r.o, r.n,
      &"Constant-byte residual fill 0x{v:02X}; free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "const", r.n, total, spanCount)

  # far3: free run after align 0..2 is pure far3 chain (bank C0-EF, lo≠0)
  for r in freeRuns(claimed):
    if r.n < 3:
      continue
    var bestAlign = -1
    var bestN = 0
    for align in 0 .. 2:
      if align >= r.n:
        continue
      let rem = r.n - align
      if rem < 3 or rem mod 3 != 0:
        continue
      let nRec = rem div 3
      var ok = true
      for i in 0 ..< nRec:
        if not isFar3(g, r.o + align + i * 3):
          ok = false
          break
      if ok and rem > bestN and isFree(claimed, r.o + align, rem):
        bestAlign = align
        bestN = rem
    if bestAlign >= 0 and bestN >= 3:
      let base = r.o + bestAlign
      emit("ekTable", &"table_far3_w101_0x{base:06X}", base, bestN,
        "Far-ptr 3B residual pure rem (align 0-2, bank $C0–$EF, lo≠0); free only")
      mark(claimed, base, bestN)
      bump(totals, nSpans, "far3", bestN, total, spanCount)

  # ternary bit-flag alphabet 00/01/80 free ≥4
  for r in freeRuns(claimed):
    if r.n < MinAlphabet:
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
    if not ok:
      continue
    if nz < 1:
      continue  # pure zero already claimed
    emit("ekTable", &"table_bitFlag_w101_0x{r.o:06X}", r.o, r.n,
      "Ternary flag residual alphabet {0x00,0x01,0x80}; free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "bitFlag", r.n, total, spanCount)

  var rem = 0
  var rn = 0
  for r in freeRuns(claimed):
    rem += r.n
    rn += 1

  echo &"  # WAVE101 TOTAL residual: {total} B in {spanCount} spans"
  var keys: seq[string] = @[]
  for k in totals.keys:
    keys.add k
  keys.sort()
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}={totals[k]}/{nSpans[k]}"
  echo &"  # breakdown: {parts.join(\" \")}"
  echo &"  # residual left after wave101: {rem} B in {rn} runs"
  let exact = (3145728 - rem).float * 100.0 / 3145728.0
  echo &"  # expected coverage ~{exact:.2f}%"

main()
