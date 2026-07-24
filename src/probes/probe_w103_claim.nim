## Enumerate honestly claimable residual by extending known gates slightly.
import
  std/[algorithm, strformat, strutils, tables, sets, sequtils],
  ../decompbound/[rom_chunks, baserom_extract, action_script, text_decode, gfx_lz]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len: return false
  for j in 0 ..< n:
    if claimed[o + j]: return false
  true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  result = @[]
  var rs = -1
  var rl = 0
  for o in 0 ..< claimed.len:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0: result.add (rs, rl); rs = -1
  if rs >= 0: result.add (rs, rl)

proc emit(kind, name: string; o, n: int; note: string) =
  echo &"""  BaseromExtractSpan(
    name: "{name}",
    offset: 0x{o:06X},
    length: {n},
    kind: {kind},
    note: "{note}"),"""

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset+c.length, isCode.len): isCode[i] = true

  var total = 0
  var spanCount = 0
  var totals = initTable[string, int]()
  var counts = initTable[string, int]()
  proc bump(k: string; n: int) =
    if k notin totals: totals[k]=0; counts[k]=0
    totals[k]+=n; counts[k]+=1
    total += n; spanCount += 1

  echo "  # --- residual wave103: plane even-prefix + bitmask + cfRec5 + fix scraps ---"

  # 1) plane even prefix ≥8, ≥50% equal pairs (stricter than plane25), not code|code
  for r in freeRuns(claimed):
    let evenN = r.n and not 1  # clear low bit
    if evenN < 8: continue
    # skip pure code sandwiches (prefer code seeds)
    let leftCode = r.o > 0 and isCode[r.o - 1]
    let rightCode = r.o + evenN < isCode.len and isCode[r.o + evenN]
    if leftCode and rightCode: continue
    var eq = 0
    let pairs = evenN div 2
    for i in 0 ..< pairs:
      if g[r.o + i*2] == g[r.o + i*2 + 1]: eq += 1
    if eq * 100 < pairs * 50: continue
    var nz = 0
    for j in 0 ..< evenN:
      if g[r.o + j] != 0: nz += 1
    if nz * 2 < evenN: continue
    # not pure zero / not single-byte alphabet of only FF
    emit("ekTable", &"table_plane50_w103_0x{r.o:06X}", r.o, evenN,
      "SNES bitplane-like residual even-prefix (≥50% equal pairs, ≥8); free only")
    mark(claimed, r.o, evenN)
    bump("plane50", evenN)

  # 2) classic bit-mask residual: set of distinct powers-of-two, ≥4
  for r in freeRuns(claimed):
    if r.n < 4: continue
    var ok = true
    var seen = initHashSet[uint8]()
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if b notin [0x01u8,0x02u8,0x04u8,0x08u8,0x10u8,0x20u8,0x40u8,0x80u8]:
        ok = false; break
      if b in seen: ok = false; break
      seen.incl b
    if not ok: continue
    emit("ekTable", &"table_bitMask_w103_0x{r.o:06X}", r.o, r.n,
      "Bit-index mask residual (distinct powers-of-two); free only")
    mark(claimed, r.o, r.n)
    bump("bitMask", r.n)

  # 3) cfRec5 family: residual free complete records matching 0A 01 00 80 xx pattern
  #    or general 5B with fixed head from claimed neighbors
  block:
    # scan free runs of multiple of 5 with head 0A 01 00 80
    for r in freeRuns(claimed):
      if r.n < 5: continue
      var pos = 0
      var start = -1
      var endp = 0
      while pos + 5 <= r.n:
        let o = r.o + pos
        if g[o]==0x0A and g[o+1]==0x01 and g[o+2]==0x00 and g[o+3]==0x80:
          if start < 0: start = o
          endp = o + 5
          pos += 5
        else:
          if start >= 0 and endp > start:
            let n = endp - start
            if n >= 5 and isFree(claimed, start, n):
              emit("ekTable", &"table_cfRec5_w103_0x{start:06X}", start, n,
                "CF 5B rec residual (0A 01 00 80 + u8); free only")
              mark(claimed, start, n)
              bump("cfRec5", n)
          start = -1
          pos += 1
      if start >= 0 and endp > start:
        let n = endp - start
        if n >= 5 and isFree(claimed, start, n):
          emit("ekTable", &"table_cfRec5_w103_0x{start:06X}", start, n,
            "CF 5B rec residual (0A 01 00 80 + u8); free only")
          mark(claimed, start, n)
          bump("cfRec5", n)

  # 4) fix4 even free ≥3 recs with bank@+3 majority ≥40% in C0-EF (even if n not multiple - use floor)
  for r in freeRuns(claimed):
    let nRec = r.n div 4
    if nRec < 3: continue
    let n = nRec * 4
    var banks = initCountTable[uint8]()
    for i in 0 ..< nRec:
      banks.inc g[r.o + i*4 + 3]
    var bankCnt = 0
    var maj: uint8 = 0
    for k,v in banks.pairs:
      if v > bankCnt: bankCnt = v; maj = k
    if bankCnt * 100 >= nRec * 40 and maj >= 0xC0 and maj <= 0xEF:
      if isFree(claimed, r.o, n):
        emit("ekTable", &"table_fix4_w103_0x{r.o:06X}", r.o, n,
          "Fixed 4B residual (≥40% bank@+3 $C0–$EF); free only")
        mark(claimed, r.o, n)
        bump("fix4", n)

  # 5) fix3 ≥3 recs type@+0 majority ≥40% in small range OR bank@+2
  for r in freeRuns(claimed):
    let nRec = r.n div 3
    if nRec < 3: continue
    let n = nRec * 3
    var banks = initCountTable[uint8]()
    for i in 0 ..< nRec:
      banks.inc g[r.o + i*3 + 2]
    var bankCnt = 0
    var maj: uint8 = 0
    for k,v in banks.pairs:
      if v > bankCnt: bankCnt = v; maj = k
    if bankCnt * 100 >= nRec * 40 and maj >= 0xC0 and maj <= 0xEF:
      if isFree(claimed, r.o, n):
        emit("ekTable", &"table_fix3_w103_0x{r.o:06X}", r.o, n,
          "Fixed 3B residual (≥40% bank@+2 $C0–$EF); free only")
        mark(claimed, r.o, n)
        bump("fix3", n)

  # 6) bitFlag min 3 (was ≥4)
  for r in freeRuns(claimed):
    if r.n < 3 or r.n >= 4: continue  # only min3 leftovers; ≥4 drained
    var ok = true
    var nz = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if b notin [0x00u8, 0x01u8, 0x80u8]: ok = false; break
      if b != 0: nz += 1
    if ok and nz >= 1:
      emit("ekTable", &"table_bitFlag_w103_0x{r.o:06X}", r.o, r.n,
        "Ternary flag residual alphabet {0x00,0x01,0x80} min3; free only")
      mark(claimed, r.o, r.n)
      bump("bitFlag3", r.n)

  # 7) far3 pure rem with ≥1 (align) — already drained for pure rem; try head-only pure chain of ≥1
  #    only claim if entire free run is pure far3 after align (same as before) - skip if drained

  # 8) zero leftovers
  for r in freeRuns(claimed):
    var ok = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0: ok = false; break
    if ok and r.n >= 1:
      emit("ekZeroPad", &"zero_wave103_0x{r.o:06X}", r.o, r.n,
        "Zero-pad residual free; free only")
      mark(claimed, r.o, r.n)
      bump("zero", r.n)

  # 9) const ≥2
  for r in freeRuns(claimed):
    if r.n < 2: continue
    let v = g[r.o]
    if v == 0: continue
    var same = true
    for j in 1 ..< r.n:
      if g[r.o + j] != v: same = false; break
    if same:
      emit("ekTable", &"table_constFill_w103_0x{r.o:06X}", r.o, r.n,
        &"Constant-byte residual fill 0x{v:02X}; free only")
      mark(claimed, r.o, r.n)
      bump("const", r.n)

  # 10) AS good remaining
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen: continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      emit("ekActionScript", &"as_wave103_0x{r.o:06X}", r.o, r.n,
        "Action-script residual full cover; free only")
      mark(claimed, r.o, r.n)
      bump("as", r.n)

  echo &"  # WAVE103 TOTAL residual: {total} B in {spanCount} spans"
  var keys = toSeq(totals.keys)
  keys.sort()
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}={totals[k]}/{counts[k]}"
  echo &"  # breakdown: {parts.join(\" \")}"
  var rem = 0
  for r in freeRuns(claimed): rem += r.n
  echo &"  # residual left after wave103: {rem} B"
  let exact = (3145728 - rem).float * 100.0 / 3145728.0
  echo &"  # expected coverage ~{exact:.2f}%"

main()
