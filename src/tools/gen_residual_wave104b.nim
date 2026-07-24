## Emit residual-only claims for wave104b (post-wave104 re-scraps).
## After mid-run term/bit claims, pure zero/const remainders reappear;
## also u8pair min3 leftovers of the known pair packing family.
## Hard gate: free residual only (no code_spans overlap).

import
  std/[algorithm, strformat, strutils, tables, sequtils],
  ../decompbound/[rom_chunks, baserom_extract, action_script]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

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

proc emit(kind, name: string; o, n: int; note: string) =
  echo &"""  BaseromExtractSpan(
    name: "{name}",
    offset: 0x{o:06X},
    length: {n},
    kind: {kind},
    note: "{note}"),"""

proc main() =
  ## Build residual-only claim list for wave104b.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
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

  echo "  # --- residual wave104b: zero/const/as/u8pair3 re-scraps ---"

  for r in freeRuns(claimed):
    var ok = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0: ok = false; break
    if ok and r.n >= 1:
      emit("ekZeroPad", &"zero_wave104b_0x{r.o:06X}", r.o, r.n,
        "Zero-pad residual free remainder; free only")
      mark(claimed, r.o, r.n)
      bump("zero", r.n)

  for r in freeRuns(claimed):
    if r.n < 2: continue
    let v = g[r.o]
    if v == 0: continue
    var same = true
    for j in 1 ..< r.n:
      if g[r.o + j] != v: same = false; break
    if same:
      emit("ekTable", &"table_constFill_w104b_0x{r.o:06X}", r.o, r.n,
        &"Constant-byte residual fill 0x{v:02X} remainder; free only")
      mark(claimed, r.o, r.n)
      bump("const", r.n)

  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen: continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      emit("ekActionScript", &"as_wave104b_0x{r.o:06X}", r.o, r.n,
        "Action-script residual full cover; free only")
      mark(claimed, r.o, r.n)
      bump("as", r.n)

  for r in freeRuns(claimed):
    if r.n < 6 or r.n mod 2 != 0: continue
    let nRec = r.n div 2
    if nRec < 3: continue
    var ok = 0
    var nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o + i * 2]
      let b = g[r.o + i * 2 + 1]
      if a <= 0x50 or b <= 0x50: ok += 1
      if a != 0 or b != 0: nz += 1
    if ok * 100 < nRec * 55: continue
    if nz * 2 < nRec: continue
    let leftCode = r.o > 0 and isCode[r.o - 1]
    let rightCode = r.o + r.n < isCode.len and isCode[r.o + r.n]
    if leftCode and rightCode: continue
    emit("ekTable", &"table_u8pair3_w104b_0x{r.o:06X}", r.o, r.n,
      "u8 pair residual (≥3 recs, ≥55% lo-byte≤0x50); free only")
    mark(claimed, r.o, r.n)
    bump("u8pair3", r.n)

  var rem = 0
  var rn = 0
  var sandwich = 0
  for r in freeRuns(claimed):
    rem += r.n
    rn += 1
    let leftCode = r.o > 0 and isCode[r.o - 1]
    let rightCode = r.o + r.n < isCode.len and isCode[r.o + r.n]
    if leftCode and rightCode: sandwich += r.n

  echo &"  # WAVE104b TOTAL residual: {total} B in {spanCount} spans"
  var keys = toSeq(totals.keys)
  keys.sort()
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}={totals[k]}/{nSpans[k]}"
  echo &"  # breakdown: {parts.join(\" \")}"
  echo &"  # residual left after wave104b: {rem} B in {rn} runs (sandwich ~{sandwich})"
  let exact = (3145728 - rem).float * 100.0 / 3145728.0
  echo &"  # expected coverage ~{exact:.4f}%"

main()
