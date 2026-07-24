## Wave99c: max solid residual free with structure.
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

  # --- u8pair ≥65% range-limited, ≥8 recs ---
  for r in freeRuns(m):
    if r.n < 16 or r.n mod 2 != 0: continue
    let nRec = r.n div 2
    if nRec < 8: continue
    var ok, nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o + i*2]; let b = g[r.o + i*2 + 1]
      if a <= 0x40 or b <= 0x40: ok += 1
      if a != 0 or b != 0: nz += 1
    if ok * 100 < nRec * 65: continue
    if nz * 4 < nRec * 3: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n); add("u8pair", r.n)

  # --- countN mid-scan: any free offset, need exact or ≥40% of remaining free to end of run ---
  for r in freeRuns(m):
    if r.n < 6: continue
    var i = 0
    while i < r.n:
      if not isFree(m, r.o + i, 1): i += 1; continue
      var best = 0
      for hdr in 1..2:
        for stride in [1,2,3,4,5,6,7,8,10,12,14,16,17,25,27,41]:
          if i + hdr > r.n: continue
          let cnt = if hdr == 1: g[r.o+i].int else:
            if i+1 >= r.n: continue else: g[r.o+i].int or (g[r.o+i+1].int shl 8)
          if cnt < 2 or cnt > 100: continue
          let need = hdr + cnt * stride
          if need < 6 or i + need > r.n: continue
          # fill ≥40% of remaining run from i, or exact remaining
          let rem = r.n - i
          if need < rem * 2 div 5 and need != rem: continue
          var z, nz = 0
          for j in hdr ..< need:
            if g[r.o+i+j] == 0: z += 1
            else: nz += 1
          if z * 2 > (need - hdr): continue
          if nz < 2: continue
          if need > best: best = need
      if best >= 6 and isFree(m, r.o+i, best):
        mark(m, r.o+i, best); add("countN", best); i += best
      else:
        i += 1

  # --- u16tab ≥40% hi≤0x3F, ≥8 words ---
  for r in freeRuns(m):
    if r.n < 16 or r.n mod 2 != 0: continue
    let words = r.n div 2
    if words < 8: continue
    var lohi, nz = 0
    for i in 0 ..< words:
      if g[r.o + i*2 + 1] < 0x40: lohi += 1
      if g[r.o+i*2] != 0 or g[r.o+i*2+1] != 0: nz += 1
    if lohi * 5 < words * 2: continue  # ≥40%
    if nz * 4 < words * 3: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n); add("u16tab", r.n)

  # --- smooth rec 3/4/5 with align + prefix (longest) ---
  for rec in [3, 4, 5]:
    for r in freeRuns(m):
      if r.n < rec * 8: continue
      var bestO, bestN = 0
      for align in 0 ..< rec:
        let avail = r.n - align
        var nRec = avail div rec
        while nRec >= 8:
          let n = nRec * rec
          let base = r.o + align
          if not isFree(m, base, n):
            nRec -= 1
            continue
          var small, totalCmp = 0
          for i in 1 ..< nRec:
            for j in 0 ..< rec:
              let a = g[base + (i-1)*rec + j].int
              let b = g[base + i*rec + j].int
              totalCmp += 1
              if abs(a - b) <= 10: small += 1
          if small * 100 >= totalCmp * 50:
            # not constant first two rows
            var same = true
            for j in 0 ..< rec:
              if g[base+j] != g[base+rec+j]: same = false
            if not same and n > bestN:
              bestO = base; bestN = n
            break
          nRec -= 1
      if bestN >= rec * 8:
        mark(m, bestO, bestN); add(&"smooth{rec}", bestN)

  # --- fix3 bank/type ≥50% ---
  for r in freeRuns(m):
    if r.n < 18: continue
    for align in 0..2:
      let avail = r.n - align
      let nRec = avail div 3
      if nRec < 6: continue
      let n = nRec * 3
      let base = r.o + align
      if not isFree(m, base, n): continue
      var banks, types, nz = 0
      for i in 0 ..< nRec:
        let b = g[base + i*3 + 2].int
        if b >= 0xC0 and b <= 0xEF: banks += 1
        if b <= 0x0F: types += 1
        if g[base+i*3] != 0 or g[base+i*3+1] != 0 or g[base+i*3+2] != 0: nz += 1
      if nz * 4 < nRec * 3: continue
      if banks * 2 < nRec and types * 2 < nRec: continue
      mark(m, base, n); add("fix3", n); break

  # --- fix4 hi0/bank ≥50% ---
  for r in freeRuns(m):
    if r.n < 24: continue
    for align in 0..3:
      let nRec = (r.n - align) div 4
      if nRec < 6: continue
      let n = nRec * 4
      let base = r.o + align
      if not isFree(m, base, n): continue
      var zhi, banks, nz = 0
      for i in 0 ..< nRec:
        if g[base + i*4 + 3] == 0: zhi += 1
        let b = g[base + i*4 + 2].int
        if b >= 0xC0 and b <= 0xEF: banks += 1
        for j in 0..3:
          if g[base+i*4+j] != 0: nz += 1
      if nz < nRec * 2: continue
      if zhi * 2 < nRec and banks * 2 < nRec: continue
      mark(m, base, n); add("fix4", n); break

  # --- col-constrained fix 5..12 ---
  for rec in [5, 6, 7, 8, 9, 10, 12]:
    for r in freeRuns(m):
      if r.n < rec * 5: continue
      for align in 0 ..< min(rec, 4):
        let nRec = (r.n - align) div rec
        if nRec < 5: continue
        let n = nRec * rec
        let base = r.o + align
        if not isFree(m, base, n): continue
        var col0: CountTable[int]
        var nz = 0
        for i in 0 ..< nRec:
          col0.inc(g[base + i*rec].int)
          for j in 0 ..< rec:
            if g[base+i*rec+j] != 0: nz += 1
        if nz < n div 2: continue
        var tops: seq[int] = @[]
        for _, c in col0.pairs: tops.add c
        tops.sort(proc(a,b:int): int = cmp(b,a))
        var cover = 0
        for i in 0 ..< min(3, tops.len): cover += tops[i]
        if cover * 100 < nRec * 35: continue
        mark(m, base, n); add(&"fix{rec}col", n); break

  # --- term multi F8-FC ---
  for termByte in [0xFC, 0xFB, 0xFA, 0xF9, 0xF8]:
    var o = 0
    while o < g.len:
      if m[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not m[pos]:
        var k = pos
        while k < g.len and not m[k] and g[k] != termByte.uint8 and (k-pos) < 48: k += 1
        if k >= g.len or m[k] or g[k] != termByte.uint8: break
        let rl = k - pos + 1
        if rl < 2 or rl > 48: break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4 and isFree(m, start, n):
        var t = 0
        for j in 0..<n:
          if g[start+j] == termByte.uint8: t += 1
        if t == recs and t * 3 <= n * 2 and t < n:
          mark(m, start, n); add(&"t{termByte:02X}", n); o = pos; continue
      o += 1

  # --- plane 35% ---
  for r in freeRuns(m):
    if r.n < 16: continue
    let np = r.n div 2
    if np < 8: continue
    var pairs = 0
    for i in 0..<np:
      if g[r.o+i*2] == g[r.o+i*2+1]: pairs += 1
    if pairs.float / np.float < 0.35: continue
    var any, ff = 0
    for j in 0..<r.n:
      if g[r.o+j] != 0: any += 1
      if g[r.o+j] == 0xFF: ff += 1
    if any == 0 or ff*4 >= r.n: continue
    let n = np*2
    if isFree(m, r.o, n):
      mark(m, r.o, n); add("plane35", n)

  # --- cmd top-3 ≥22% ---
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
    if cover * 100 < np * 22: continue
    if top[0].c < 2: continue
    var pr = 0
    for j in 0..<r.n:
      if g[r.o+j] >= 0x20 and g[r.o+j] < 0x7F: pr += 1
    if pr * 2 > r.n: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n); add("cmd22", r.n)

  # --- seq loose ---
  for r in freeRuns(m):
    if r.n < 8: continue
    var e0, notes, z, e0xx = 0
    for j in 0..<r.n:
      let b = g[r.o+j].int
      if b == 0: z += 1
      elif b >= 0x80 and b <= 0xC7: notes += 1
      elif b >= 0xE0:
        e0 += 1
        if b == 0xE0 and j+1 < r.n and g[r.o+j+1] < 0x40: e0xx += 1
    if e0xx >= 1 and notes >= 2 and e0 >= 1 and z*5 <= r.n and
        (notes+e0)*5 >= r.n and isFree(m, r.o, r.n):
      mark(m, r.o, r.n); add("seqLoose", r.n)

  # --- far3 ≥2 ---
  for r in freeRuns(m):
    if r.n < 6: continue
    var p = r.o
    while p + 6 <= r.o + r.n:
      var q = p
      var good = 0
      while q + 3 <= r.o + r.n:
        let bk = g[q + 2].int
        if bk < 0xC0 or bk > 0xEF: break
        good += 1; q += 3
      if good >= 2:
        let n = good * 3
        if isFree(m, p, n):
          mark(m, p, n); add("far3", n)
        p = q
      else: p += 1

  # --- AS/SS/zero/const ---
  for r in freeRuns(m):
    if r.n < 4: continue
    var pos = r.o; var taken = 0
    while pos < r.o + r.n:
      let w = walkActionScript(g, pos, r.o + r.n)
      if w.ended and w.length >= 4 and w.ops >= 1 and pos + w.length <= r.o + r.n:
        taken += w.length; pos += w.length
      else: break
    if taken >= 4 and isFree(m, r.o, taken):
      if taken >= 12 and countSignatureBytes(g, r.o, taken) < 1: continue
      mark(m, r.o, taken); add("as", taken)

  for r in freeRuns(m):
    if r.n < ScriptStreamMinLen: continue
    let consumed = consumeScriptStreamRun(g, r.o, r.n)
    if consumed >= ScriptStreamMinLen and isFree(m, r.o, consumed):
      mark(m, r.o, consumed); add("ss", consumed)

  for r in freeRuns(m):
    if r.n < 2: continue
    var allZ = true
    for j in 0..<r.n:
      if g[r.o+j] != 0: allZ = false; break
    if allZ: mark(m, r.o, r.n); add("zero", r.n)

  for r in freeRuns(m):
    if r.n < 4: continue
    let v = g[r.o]
    if v == 0: continue
    var all = true
    for j in 1..<r.n:
      if g[r.o+j] != v: all = false; break
    if all: mark(m, r.o, r.n); add("const", r.n)

  # --- u8lo ≥70% bytes ≤0x3F ---
  for r in freeRuns(m):
    if r.n < 12: continue
    var lo, nz = 0
    for j in 0..<r.n:
      if g[r.o+j] <= 0x3F: lo += 1
      if g[r.o+j] != 0: nz += 1
    if lo * 10 < r.n * 7: continue
    if nz * 4 < r.n * 3: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n); add("u8lo", r.n)

  # --- stride2 ≥40% ---
  for r in freeRuns(m):
    if r.n < 16: continue
    var match = 0
    let lim = r.n - 2
    for j in 0..<lim:
      if g[r.o+j] == g[r.o+j+2]: match += 1
    if match * 100 < lim * 40: continue
    var nz = 0
    for j in 0..<r.n:
      if g[r.o+j] != 0: nz += 1
    if nz * 2 < r.n: continue
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n); add("stride2", r.n)

  # --- lowEnt: top-6 cover ≥45%, len≥20 ---
  for r in freeRuns(m):
    if r.n < 20: continue
    var u: CountTable[int]
    for j in 0..<r.n: u.inc(g[r.o+j].int)
    var top: seq[int] = @[]
    for _, c in u.pairs: top.add c
    top.sort(proc(a,b:int): int = cmp(b,a))
    var cover = 0
    for i in 0 ..< min(6, top.len): cover += top[i]
    if cover * 100 < r.n * 45: continue
    if u.len < 3 or u.len > r.n div 2: continue
    mark(m, r.o, r.n); add("lowEnt", r.n)

  var sum = 0
  var keys = newSeq[string]()
  for k in totals.keys: keys.add k
  keys.sort()
  echo "=== wave99c max solid ==="
  for k in keys:
    echo &"  {k}: {totals[k]} B / {spans[k]} spans"
    sum += totals[k]
  echo &"SUM: {sum} B (~{sum.float*100.0/3145728.0:.2f}%)"
  var left = 0
  for r in freeRuns(m): left += r.n
  echo &"left: {left} B"
  echo &"expected coverage ~{98.02 + sum.float*100.0/3145728.0:.2f}%"

main()
