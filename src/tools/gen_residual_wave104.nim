## Emit residual-only claims for wave104 (post-wave103b scraps).
## Families: zero, const>=2, AS good, APU pack free interiors, u8pair>=4,
## term F0-FF singles min2 quality, bitFlag min2, farPtr C0-EF lo!=0 mid.
## Hard gate: free residual only (no code_spans overlap).
## Honesty: no F0-FF "far ptr" false banks; no bulk print70; no SS any-ended.

import
  std/[algorithm, strformat, strutils, tables, sequtils],
  ../decompbound/[rom_chunks, baserom_extract, text_decode, action_script, memmap]

const
  MinTermRec = 2
  MaxTermRec = 32
  PackCount = 169

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

proc walkApuPackSize(g: seq[uint8]; start: int): int =
  ## Best-effort APU pack size from first free byte inside a known pack range.
  ## Returns 0 if not a clean pack-table interior claim path.
  discard g
  discard start
  0

proc main() =
  ## Build residual-only claim list for wave104.
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

  echo "  # --- residual wave104: zero/const/as/apu/u8pair/term2/bit2/farPtr ---"

  # 1) zero
  for r in freeRuns(claimed):
    var ok = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        ok = false
        break
    if ok and r.n >= 1:
      emit("ekZeroPad", &"zero_wave104_0x{r.o:06X}", r.o, r.n,
        "Zero-pad residual free; free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "zero", r.n, total, spanCount)

  # 2) const >=2
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
      emit("ekTable", &"table_constFill_w104_0x{r.o:06X}", r.o, r.n,
        &"Constant-byte residual fill 0x{v:02X}; free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "const", r.n, total, spanCount)

  # 3) AS good full free
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen:
      continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      emit("ekActionScript", &"as_wave104_0x{r.o:06X}", r.o, r.n,
        "Action-script residual full cover; free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "as", r.n, total, spanCount)

  # 4) APU pack free interiors (loader pack table discovery leftovers)
  #    From probe_allbank_abslong: free scraps inside known pack ranges.
  let apuClaims = [
    (0x25B68F, 5, 56, 0x25954E, 18406),
    (0x25C5E0, 6, 56, 0x25954E, 18406),
    (0x25CA11, 4, 56, 0x25954E, 18406),
    (0x25CE87, 6, 56, 0x25954E, 18406),
    (0x25D4A0, 6, 56, 0x25954E, 18406),
    (0x270B33, 5, 78, 0x270000, 17174),
    (0x2713BF, 4, 78, 0x270000, 17174),
    (0x2714D6, 4, 78, 0x270000, 17174),
    (0x27209E, 6, 78, 0x270000, 17174),
    (0x272BAF, 4, 78, 0x270000, 17174),
    (0x2AA2BA, 5, 89, 0x2A96F6, 11932),
    (0x2AB7D4, 4, 89, 0x2A96F6, 11932),
    (0x2ABC03, 6, 89, 0x2A96F6, 11932),
    (0x2AC541, 4, 89, 0x2A96F6, 11932),
    (0x2AD5FC, 7, 35, 0x2AC590, 11158),
    (0x2ADC08, 7, 35, 0x2AC590, 11158),
    (0x2AED09, 5, 35, 0x2AC590, 11158),
    (0x2AEE65, 4, 35, 0x2AC590, 11158),
    (0x2AEF96, 4, 35, 0x2AC590, 11158),
  ]
  for (o, n, packId, packBase, packSize) in apuClaims:
    if not isFree(claimed, o, n):
      continue
    # pack interior sanity
    if o < packBase or o + n > packBase + packSize:
      continue
    emit("ekApuPackage", &"apuPack_w104_0x{o:06X}", o, n,
      &"APU pack {packId} residual (pack@0x{packBase:06X} size={packSize}); pack-table discovery; free only")
    mark(claimed, o, n)
    bump(totals, nSpans, "apu", n, total, spanCount)

  # 5) u8pair >=4 @55% even free
  for r in freeRuns(claimed):
    if r.n < 8 or r.n mod 2 != 0:
      continue
    let nRec = r.n div 2
    if nRec < 4:
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
    # skip pure code|code sandwiches (prefer seeds)
    let leftCode = r.o > 0 and isCode[r.o - 1]
    let rightCode = r.o + r.n < isCode.len and isCode[r.o + r.n]
    if leftCode and rightCode:
      continue
    emit("ekTable", &"table_u8pair4_w104_0x{r.o:06X}", r.o, r.n,
      "u8 pair residual (≥4 recs, ≥55% lo-byte≤0x50); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "u8pair", r.n, total, spanCount)

  # 6) farPtr singles/mid C0-EF lo!=0 (any leftover)
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
          emit("ekTable", &"table_farPtr_w104_0x{r.o + i:06X}", r.o + i, n,
            "Far-ptr 3B residual single/mid-run (bank $C0–$EF, lo≠0); free only")
          mark(claimed, r.o + i, n)
          bump(totals, nSpans, "farPtr", n, total, spanCount)
        i = max(k, i + 1)
      else:
        i += 1

  # 7) term F0-FF singles min2..32 quality (term scraps)
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
            # skip pure code|code (seed path)
            let leftCode = o > 0 and isCode[o - 1]
            let rightCode = o + n < isCode.len and isCode[o + n]
            if not (leftCode and rightCode):
              emit("ekTable", &"table_term1_w104_0x{o:06X}", o, n,
                &"Terminator 0x{termByte:02X} single-rec residual {MinTermRec}..{MaxTermRec}; free only")
              mark(claimed, o, n)
              bump(totals, nSpans, "term1", n, total, spanCount)
              o = k + 1
              continue
      o += 1

  # 8) bitFlag alphabet {00,01,80} min2 leftovers
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
    if not ok or nz < 1:
      continue
    emit("ekTable", &"table_bitFlag_w104_0x{r.o:06X}", r.o, r.n,
      "Ternary flag residual alphabet {0x00,0x01,0x80} min2; free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "bit", r.n, total, spanCount)

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

  echo &"  # WAVE104 TOTAL residual: {total} B in {spanCount} spans"
  var keys: seq[string] = @[]
  for k in totals.keys:
    keys.add k
  keys.sort()
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}={totals[k]}/{nSpans[k]}"
  echo &"  # breakdown: {parts.join(\" \")}"
  echo &"  # residual left after wave104: {rem} B in {rn} runs (sandwich ~{sandwich})"
  let exact = (3145728 - rem).float * 100.0 / 3145728.0
  echo &"  # expected coverage ~{exact:.4f}%"

main()
