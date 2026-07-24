## Emit residual-only claims for wave100b (post-wave100 scraps).
## Hard gate: free residual only (no code_spans overlap).

import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, text_decode, action_script]

const
  MinU8PairRecs = 4
  U8PairOkRatio = 55
  U8PairFieldMax = 0x50
  MinCountN = 4
  MaxCount = 160
  MinFixRecs = 3
  MinColCover = 30
  MinFar3 = 1
  MinPrint = 6
  PrintRatio = 70

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
  ## Build residual-only claim list for wave100b.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var total = 0
  var spanCount = 0
  var totals: Table[string, int]
  var nSpans: Table[string, int]

  echo "  # --- residual wave100b: u8pair4/countN4/fix3/far3/print/zero/const ---"

  # zero
  for r in freeRuns(claimed):
    if r.n < 1:
      continue
    var allZ = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        allZ = false
        break
    if not allZ:
      continue
    emit("ekZeroPad", &"zero_wave100b_0x{r.o:06X}", r.o, r.n,
      "Zero-pad residual free; free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "zero", r.n, total, spanCount)

  # const ≥2
  for r in freeRuns(claimed):
    if r.n < 2:
      continue
    let v = g[r.o]
    var same = true
    for j in 1 ..< r.n:
      if g[r.o + j] != v:
        same = false
        break
    if not same:
      continue
    emit("ekTable", &"table_constFill_w100b_0x{r.o:06X}", r.o, r.n,
      &"Constant-byte residual fill 0x{v:02X}; free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "const", r.n, total, spanCount)

  # action-script residual
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen:
      continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      emit("ekActionScript", &"as_wave100b_0x{r.o:06X}", r.o, r.n,
        "Action-script residual (MinLen4); free only")
      mark(claimed, r.o, r.n)
      bump(totals, nSpans, "as", r.n, total, spanCount)

  # u8pair ≥4 recs
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
    emit("ekTable", &"table_u8pair4_w100b_0x{r.o:06X}", r.o, r.n,
      "u8-pair residual (≥55% field ≤0x50, ≥4 recs); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "u8pair4", r.n, total, spanCount)

  # countN min4 fill 30%
  const strides = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 17, 20, 24, 25, 27, 32, 41]
  for r in freeRuns(claimed):
    if r.n < MinCountN:
      continue
    var i = 0
    while i < r.n:
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
          if need < rem * 3 div 10 and need != rem:
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
        emit("ekTable", &"table_countN_w100b_0x{r.o + i:06X}", r.o + i, best,
          "count+N*stride residual (≥30% fill, min4); free only")
        mark(claimed, r.o + i, best)
        bump(totals, nSpans, "countN", best, total, spanCount)
        i += best
      else:
        i += 1

  # fix3 bank/type ≥40% min3
  for r in freeRuns(claimed):
    if r.n < MinFixRecs * 3:
      continue
    for align in 0 .. 2:
      let nRec = (r.n - align) div 3
      if nRec < MinFixRecs:
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
      if nz * 2 < nRec:
        continue
      if banks * 5 < nRec * 2 and types * 5 < nRec * 2:
        continue
      emit("ekTable", &"table_fix3_w100b_0x{base:06X}", base, n,
        "Fixed 3B residual (≥40% bank/type, ≥3 recs); free only")
      mark(claimed, base, n)
      bump(totals, nSpans, "fix3", n, total, spanCount)
      break

  # fix4 hi0/bank ≥40% min3
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
      emit("ekTable", &"table_fix4_w100b_0x{base:06X}", base, n,
        "Fixed 4B residual (≥40% hi0/bank, ≥3 recs); free only")
      mark(claimed, base, n)
      bump(totals, nSpans, "fix4", n, total, spanCount)
      break

  # far3 ≥1 bank C0-EF, lo16 != 0
  for r in freeRuns(claimed):
    if r.n < 3:
      continue
    var i = 0
    var cnt = 0
    while i + 3 <= r.n:
      let lo = g[r.o + i].int or (g[r.o + i + 1].int shl 8)
      let b = g[r.o + i + 2]
      if b >= 0xC0 and b <= 0xEF and lo != 0:
        cnt += 1
        i += 3
      else:
        break
    let n = cnt * 3
    if cnt >= MinFar3 and isFree(claimed, r.o, n):
      emit("ekTable", &"table_far3_w100b_0x{r.o:06X}", r.o, n,
        "Far-ptr 3B residual (bank $C0–$EF, lo≠0, ≥1); free only")
      mark(claimed, r.o, n)
      bump(totals, nSpans, "far3", n, total, spanCount)

  # print ≥6
  for r in freeRuns(claimed):
    if r.n < MinPrint:
      continue
    var pr = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if (b >= 0x20 and b <= 0x7E) or (b >= 0x50 and b <= 0x90):
        pr += 1
    if pr * 100 < r.n * PrintRatio:
      continue
    emit("ekTable", &"table_print70_w100b_0x{r.o:06X}", r.o, r.n,
      "Printable/EB-glyph residual (≥70%, ≥6); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "print70", r.n, total, spanCount)

  # plane ≥25% min 8
  for r in freeRuns(claimed):
    if r.n < 8 or r.n mod 2 != 0:
      continue
    var eq = 0
    let pairs = r.n div 2
    for i in 0 ..< pairs:
      if g[r.o + i * 2] == g[r.o + i * 2 + 1]:
        eq += 1
    if eq * 100 < pairs * 25:
      continue
    emit("ekTable", &"table_plane25_w100b_0x{r.o:06X}", r.o, r.n,
      "SNES bitplane-like residual (≥25% equal pairs); free only")
    mark(claimed, r.o, r.n)
    bump(totals, nSpans, "plane25", r.n, total, spanCount)

  var left = 0
  for r in freeRuns(claimed):
    left += r.n
  var keys: seq[string] = @[]
  for k in totals.keys:
    keys.add k
  keys.sort()
  echo ""
  echo &"  # WAVE100b TOTAL residual: {total} B in {spanCount} spans"
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}={totals[k]}/{nSpans[k]}"
  echo &"  # breakdown: {parts.join(\" \")}"
  echo &"  # residual left after wave100b: {left} B"
  let newPct = 100.0 * float(3_145_728 - left) / 3_145_728.0
  echo &"  # expected coverage ~{newPct:.2f}%"

main()
