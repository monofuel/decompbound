## Emit residual-only claims for wave105 (post-wave104b).
## Non-sandwich structure gates are drained; this wave reclaims sandwich free
## that matches established quality gates (term min2, u8pair min3 @55%).
## Pure RTS/RTL sandwich stubs already seeded; no bulk residualFree_*.
## Hard gate: free residual only (no code_spans overlap).

import
  std/[algorithm, strformat, strutils, tables, sequtils],
  ../decompbound/[rom_chunks, baserom_extract, action_script]

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

proc isFar3(g: seq[uint8]; o: int): bool =
  let lo = g[o].int or (g[o + 1].int shl 8)
  let b = g[o + 2]
  result = b >= 0xC0 and b <= 0xEF and lo != 0

proc main() =
  ## Build residual-only claim list for wave105.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset + c.length, isCode.len):
        isCode[i] = true

  var total = 0
  var spanCount = 0
  var totals: Table[string, int]
  var nSpans: Table[string, int]
  proc bump(key: string; n: int) =
    if key notin totals:
      totals[key] = 0
      nSpans[key] = 0
    totals[key] = totals[key] + n
    nSpans[key] = nSpans[key] + 1
    total += n
    spanCount += 1

  echo "  # --- residual wave105: term/u8/far/bit/zero/as re-scraps (incl sandwich) ---"

  # 1) zero re-scraps
  for r in freeRuns(claimed):
    var ok = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        ok = false
        break
    if ok and r.n >= 1:
      emit("ekZeroPad", &"zero_wave105_0x{r.o:06X}", r.o, r.n,
        "Zero-pad residual free remainder; free only")
      mark(claimed, r.o, r.n)
      bump("zero", r.n)

  # 2) const >=2 re-scraps
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
    if same:
      emit("ekTable", &"table_constFill_w105_0x{r.o:06X}", r.o, r.n,
        &"Constant-byte residual fill 0x{v:02X}; free only")
      mark(claimed, r.o, r.n)
      bump("const", r.n)

  # 3) farPtr C0-EF lo!=0 (including sandwich leftovers)
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
          emit("ekTable", &"table_farPtr_w105_0x{r.o + i:06X}", r.o + i, n,
            "Far-ptr 3B residual (bank $C0–$EF, lo≠0); free only")
          mark(claimed, r.o + i, n)
          bump("farPtr", n)
        i = max(k, i + 1)
      else:
        i += 1

  # 4) term F0-FF singles min2 quality (incl sandwich free; pure code seeds drained)
  for termByte in 0xF0 .. 0xFF:
    var o = 0
    while o < g.len:
      if claimed[o]:
        o += 1
        continue
      var k = o
      while k < g.len and not claimed[k] and g[k] != termByte.uint8 and
          (k - o) < 32:
        k += 1
      if k < g.len and not claimed[k] and g[k] == termByte.uint8:
        let n = k - o + 1
        if n >= 2 and n <= 32 and isFree(claimed, o, n):
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
            emit("ekTable", &"table_term1_w105_0x{o:06X}", o, n,
              &"Terminator 0x{termByte:02X} single-rec residual min2 quality; free only")
            mark(claimed, o, n)
            bump("term1", n)
            o = k + 1
            continue
      o += 1

  # 5) bitFlag alphabet {00,01,80} min2
  for r in freeRuns(claimed):
    if r.n < 2:
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
    if ok and nz >= 1:
      emit("ekTable", &"table_bitFlag_w105_0x{r.o:06X}", r.o, r.n,
        "Ternary flag residual alphabet {0x00,0x01,0x80} min2; free only")
      mark(claimed, r.o, r.n)
      bump("bit", r.n)

  # 6) plane ≥25% equal pairs, min 8
  for r in freeRuns(claimed):
    if r.n < 8 or r.n mod 2 != 0:
      continue
    let pairs = r.n div 2
    var eq = 0
    for i in 0 ..< pairs:
      if g[r.o + i * 2] == g[r.o + i * 2 + 1]:
        eq += 1
    if eq * 100 < pairs * 25:
      continue
    emit("ekTable", &"table_plane25_w105_0x{r.o:06X}", r.o, r.n,
      "SNES bitplane-like residual (≥25% equal pairs); free only")
    mark(claimed, r.o, r.n)
    bump("plane", r.n)

  # 7) u8pair min3 @55% (incl sandwich leftovers)
  for r in freeRuns(claimed):
    if r.n < 6 or r.n mod 2 != 0:
      continue
    let nRec = r.n div 2
    if nRec < 3:
      continue
    var ok = 0
    var nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o + i * 2]
      let b = g[r.o + i * 2 + 1]
      if a <= 0x50 or b <= 0x50:
        ok += 1
      if a != 0 or b != 0:
        nz += 1
    if ok * 100 < nRec * 55:
      continue
    if nz * 2 < nRec:
      continue
    emit("ekTable", &"table_u8pair3_w105_0x{r.o:06X}", r.o, r.n,
      "u8 pair residual (≥3 recs, ≥55% lo-byte≤0x50); free only")
    mark(claimed, r.o, r.n)
    bump("u8pair3", r.n)

  # 8) AS good full free
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen:
      continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      emit("ekActionScript", &"as_wave105_0x{r.o:06X}", r.o, r.n,
        "Action-script residual full cover; free only")
      mark(claimed, r.o, r.n)
      bump("as", r.n)

  var rem = 0
  var rn = 0
  var sandwich = 0
  for r in freeRuns(claimed):
    rem += r.n
    rn += 1
    let leftCode = r.o > 0 and isCode[r.o - 1]
    let rightCode = r.o + r.n < isCode.len and isCode[r.o + r.n]
    if leftCode and rightCode:
      sandwich += r.n

  echo &"  # WAVE105 TOTAL residual: {total} B in {spanCount} spans"
  var keys = toSeq(totals.keys)
  keys.sort()
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}={totals[k]}/{nSpans[k]}"
  echo &"  # breakdown: {parts.join(\" \")}"
  echo &"  # residual left after wave105: {rem} B in {rn} runs (sandwich ~{sandwich})"
  let exact = (3145728 - rem).float * 100.0 / 3145728.0
  echo &"  # expected coverage ~{exact:.4f}%"

main()
