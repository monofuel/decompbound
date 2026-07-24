## Wave99 tight structural residual scout.
import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, text_decode, action_script]

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
  var rs = -1; var rl = 0
  for o in 0 ..< claimed.len:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0: result.add (rs, rl); rs = -1
  if rs >= 0: result.add (rs, rl)

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
  var m = claimed
  var totals: Table[string, int]
  var spans: Table[string, int]
  proc add(k: string; n: int) =
    if k notin totals: totals[k] = 0; spans[k] = 0
    totals[k] = totals[k] + n
    spans[k] = spans[k] + 1

  # 1) u8pair: even runs, ≥8 recs, ≥75% have a or b ≤0x40
  for r in freeRuns(m):
    if r.n < 16 or r.n mod 2 != 0: continue
    let nRec = r.n div 2
    if nRec < 8: continue
    var ok, nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o + i*2]
      let b = g[r.o + i*2 + 1]
      if a <= 0x40 or b <= 0x40: ok += 1
      if a != 0 or b != 0: nz += 1
    if ok * 4 < nRec * 3: continue
    if nz * 4 < nRec * 3: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n)
      add("u8pair", r.n)

  # 2) countN strict: u8/u16 count * stride, payload within run, low zero
  for r in freeRuns(m):
    if r.n < 6: continue
    var best = 0
    var bestTag = ""
    for hdr in 1..2:
      for stride in [1, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 17, 25, 27, 41]:
        let cnt = if hdr == 1: g[r.o].int else: g[r.o].int or (g[r.o+1].int shl 8)
        if cnt < 2 or cnt > 80: continue
        let need = hdr + cnt * stride
        if need > r.n or need < 6: continue
        # must fill ≥ half the free run OR exact end
        if need < r.n div 2 and need != r.n: continue
        var z = 0
        for j in hdr ..< need:
          if g[r.o+j] == 0: z += 1
        if z * 2 > (need - hdr): continue
        # first payload byte differs from count pattern noise
        if g[r.o + hdr] == 0 and g[r.o + hdr + 1] == 0 and stride > 1:
          # allow some zeros but require non-zero payload overall
          var nz = 0
          for j in hdr ..< need:
            if g[r.o+j] != 0: nz += 1
          if nz * 3 < (need - hdr): continue
        if need > best:
          best = need
          bestTag = &"c{hdr}s{stride}"
    if best >= 6 and isFree(m, r.o, best):
      mark(m, r.o, best)
      add("countN", best)

  # 3) u16table: even, ≥8 words, ≥50% hi≤0x3F, ≥75% nonzero
  for r in freeRuns(m):
    if r.n < 16 or r.n mod 2 != 0: continue
    let words = r.n div 2
    if words < 8: continue
    var lohi, nz = 0
    for i in 0 ..< words:
      if g[r.o + i*2 + 1] < 0x40: lohi += 1
      if g[r.o + i*2] != 0 or g[r.o + i*2 + 1] != 0: nz += 1
    if lohi * 2 < words: continue
    if nz * 4 < words * 3: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n)
      add("u16tab", r.n)

  # 4) smooth4/5 curve tables (≥6 recs, ≥55% adj delta ≤8)
  for rec in [4, 5]:
    for r in freeRuns(m):
      if r.n < rec * 6: continue
      # only natural align 0 (whole run)
      if r.n mod rec != 0: continue
      let nRec = r.n div rec
      if nRec < 6: continue
      var small, totalCmp = 0
      for i in 1 ..< nRec:
        for j in 0 ..< rec:
          let a = g[r.o + (i-1)*rec + j].int
          let b = g[r.o + i*rec + j].int
          totalCmp += 1
          if abs(a - b) <= 8: small += 1
      if small * 100 < totalCmp * 55: continue
      var same = true
      for j in 0 ..< rec:
        if g[r.o+j] != g[r.o+rec+j]: same = false
      if same: continue
      # require some column mono-ish
      var colMono = 0
      for j in 0 ..< rec:
        var mono = 0
        for i in 1 ..< nRec:
          let a = g[r.o + (i-1)*rec + j].int
          let b = g[r.o + i*rec + j].int
          if b >= a - 2: mono += 1  # non-increasing-ish loose
        if mono * 100 >= (nRec-1) * 70: colMono += 1
      if colMono < 1: continue
      if isFree(m, r.o, r.n):
        mark(m, r.o, r.n)
        add(&"smooth{rec}", r.n)

  # 5) fix3: ≥6 recs, last byte bank $C0-$EF OR type-like ≤0x0F ≥70%
  for r in freeRuns(m):
    if r.n < 18 or r.n mod 3 != 0: continue
    let nRec = r.n div 3
    if nRec < 6: continue
    var banks, types, nz = 0
    for i in 0 ..< nRec:
      let b = g[r.o + i*3 + 2].int
      if b >= 0xC0 and b <= 0xEF: banks += 1
      if b <= 0x0F: types += 1
      if g[r.o+i*3] != 0 or g[r.o+i*3+1] != 0 or g[r.o+i*3+2] != 0: nz += 1
    if nz * 4 < nRec * 3: continue
    if banks * 5 < nRec * 4 and types * 5 < nRec * 4: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n)
      add("fix3", r.n)

  # 6) fix4: ≥6, last byte 0 ≥70% OR bank@+2
  for r in freeRuns(m):
    if r.n < 24 or r.n mod 4 != 0: continue
    let nRec = r.n div 4
    if nRec < 6: continue
    var zhi, banks, nz = 0
    for i in 0 ..< nRec:
      if g[r.o + i*4 + 3] == 0: zhi += 1
      let b = g[r.o + i*4 + 2].int
      if b >= 0xC0 and b <= 0xEF: banks += 1
      for j in 0..3:
        if g[r.o+i*4+j] != 0: nz += 1
    if nz < nRec * 2: continue
    if zhi * 10 < nRec * 7 and banks * 5 < nRec * 4: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n)
      add("fix4", r.n)

  # 7) FC multi 2..40
  block:
    var o = 0
    while o < g.len:
      if m[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not m[pos]:
        var k = pos
        while k < g.len and not m[k] and g[k] != 0xFC and (k-pos) < 40: k += 1
        if k >= g.len or m[k] or g[k] != 0xFC: break
        let rl = k - pos + 1
        if rl < 2 or rl > 40: break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4 and isFree(m, start, n):
        var t = 0
        for j in 0..<n:
          if g[start+j] == 0xFC: t += 1
        if t == recs and t * 3 <= n * 2 and t < n:
          mark(m, start, n)
          add("fcRec", n)
          o = pos
          continue
      o += 1

  # 8) plane 40%
  for r in freeRuns(m):
    if r.n < 16: continue
    let np = r.n div 2
    if np < 8: continue
    var pairs = 0
    for i in 0..<np:
      if g[r.o+i*2] == g[r.o+i*2+1]: pairs += 1
    if pairs.float / np.float < 0.40: continue
    var any, ff = 0
    for j in 0..<r.n:
      if g[r.o+j] != 0: any += 1
      if g[r.o+j] == 0xFF: ff += 1
    if any == 0 or ff*4 >= r.n: continue
    let n = np*2
    if isFree(m, r.o, n):
      mark(m, r.o, n)
      add("plane40", n)

  # 9) cmd top-3 ≥25%
  for r in freeRuns(m):
    if r.n < 12 or r.n mod 2 != 0: continue
    let np = r.n div 2
    var u: CountTable[int]
    for i in 0..<np: u.inc(g[r.o+i*2].int)
    var top: seq[tuple[b,c:int]] = @[]
    for b,c in u.pairs: top.add (b,c)
    top.sort(proc(a,b: auto): int = cmp(b.c, a.c))
    if top.len < 2: continue
    var cover = top[0].c
    if top.len > 1: cover += top[1].c
    if top.len > 2: cover += top[2].c
    if cover * 100 < np * 25: continue
    if top[0].c < 2: continue
    var pr = 0
    for j in 0..<r.n:
      if g[r.o+j] >= 0x20 and g[r.o+j] < 0x7F: pr += 1
    if pr * 2 > r.n: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n)
      add("cmd25", r.n)

  # 10) seq loose
  for r in freeRuns(m):
    if r.n < 10: continue
    var e0, notes, z, e0xx = 0
    for j in 0..<r.n:
      let b = g[r.o+j].int
      if b == 0: z += 1
      elif b >= 0x80 and b <= 0xC7: notes += 1
      elif b >= 0xE0:
        e0 += 1
        if b == 0xE0 and j+1 < r.n and g[r.o+j+1] < 0x40: e0xx += 1
    if e0xx >= 1 and notes >= 2 and e0 >= 1 and z*6 <= r.n and
        (notes+e0)*5 >= r.n and isFree(m, r.o, r.n):
      mark(m, r.o, r.n)
      add("seqLoose", r.n)

  # 11) AS
  for r in freeRuns(m):
    if r.n < 4: continue
    var pos = r.o
    var taken = 0
    while pos < r.o + r.n:
      let w = walkActionScript(g, pos, r.o + r.n)
      if w.ended and w.length >= 4 and w.ops >= 1 and pos + w.length <= r.o + r.n:
        taken += w.length
        pos += w.length
      else: break
    if taken >= 4 and isFree(m, r.o, taken):
      if taken >= 12 and countSignatureBytes(g, r.o, taken) < 1: continue
      mark(m, r.o, taken)
      add("as", taken)

  # 12) SS
  for r in freeRuns(m):
    if r.n < ScriptStreamMinLen: continue
    let consumed = consumeScriptStreamRun(g, r.o, r.n)
    if consumed >= ScriptStreamMinLen and isFree(m, r.o, consumed):
      mark(m, r.o, consumed)
      add("ss", consumed)

  # 13) zero ≥2, const ≥4
  for r in freeRuns(m):
    if r.n < 2: continue
    var allZ = true
    for j in 0..<r.n:
      if g[r.o+j] != 0: allZ = false; break
    if allZ:
      mark(m, r.o, r.n)
      add("zero", r.n)
  for r in freeRuns(m):
    if r.n < 4: continue
    let v = g[r.o]
    if v == 0: continue
    var all = true
    for j in 1..<r.n:
      if g[r.o+j] != v: all = false; break
    if all:
      mark(m, r.o, r.n)
      add("const", r.n)

  # 14) rec5/6 with constrained col0 density (top-3 cover ≥40%)
  for rec in [5, 6, 7, 8, 10, 12]:
    for r in freeRuns(m):
      if r.n < rec * 5: continue
      if r.n mod rec != 0: continue
      let nRec = r.n div rec
      if nRec < 5: continue
      var col0: CountTable[int]
      var nz = 0
      for i in 0 ..< nRec:
        col0.inc(g[r.o + i*rec].int)
        for j in 0 ..< rec:
          if g[r.o+i*rec+j] != 0: nz += 1
      if nz < nRec * rec div 2: continue
      var tops: seq[int] = @[]
      for _, c in col0.pairs: tops.add c
      tops.sort(proc(a,b:int): int = cmp(b,a))
      var cover = 0
      for i in 0 ..< min(3, tops.len): cover += tops[i]
      if cover * 100 < nRec * 40: continue
      if col0.len > nRec: continue
      if isFree(m, r.o, r.n):
        mark(m, r.o, r.n)
        add(&"fix{rec}col", r.n)

  # 15) low-range u8 stream: ≥80% of bytes ≤0x3F, len≥16, not all zero
  for r in freeRuns(m):
    if r.n < 16: continue
    var lo, nz = 0
    for j in 0..<r.n:
      if g[r.o+j] <= 0x3F: lo += 1
      if g[r.o+j] != 0: nz += 1
    if lo * 5 < r.n * 4: continue
    if nz * 4 < r.n * 3: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n)
      add("u8lo", r.n)

  # 16) stride-2 repeat ≥45%
  for r in freeRuns(m):
    if r.n < 20: continue
    var match = 0
    let lim = r.n - 2
    for j in 0..<lim:
      if g[r.o+j] == g[r.o+j+2]: match += 1
    if match * 100 < lim * 45: continue
    var nz = 0
    for j in 0..<r.n:
      if g[r.o+j] != 0: nz += 1
    if nz * 2 < r.n: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n)
      add("stride2", r.n)

  var sum = 0
  var keys = newSeq[string]()
  for k in totals.keys: keys.add k
  keys.sort()
  echo "=== wave99b tight scout ==="
  for k in keys:
    echo &"  {k}: {totals[k]} B / {spans[k]} spans"
    sum += totals[k]
  echo &"SUM: {sum} B (~{sum.float*100.0/3145728.0:.2f}%)"
  var left = 0
  for r in freeRuns(m): left += r.n
  echo &"left: {left} B"
  echo &"expected coverage ~{98.02 + sum.float*100.0/3145728.0:.2f}%"

  # sample top remaining
  var runs = freeRuns(m)
  runs.sort(proc(a,b: auto): int = cmp(b.n, a.n))
  echo "\ntop remaining:"
  for i in 0 ..< min(12, runs.len):
    let r = runs[i]
    var hx = ""
    for j in 0 ..< min(20, r.n):
      hx.add &"{g[r.o+j]:02X} "
    echo &"  0x{r.o:06X}+{r.n} | {hx}"

main()
