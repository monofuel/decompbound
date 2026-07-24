## Scout residual free for wave99 structural families.
import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, memmap, text_decode, action_script]

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

  # count-prefix: u8 count in 2..64, payload = count * stride, stride 1..12
  block:
    var tot = 0
    for r in freeRuns(m):
      if r.n < 4: continue
      var i = 0
      while i < r.n:
        let cnt = g[r.o + i].int
        if cnt < 2 or cnt > 64:
          i += 1
          continue
        var claimedHere = false
        for stride in [1, 2, 3, 4, 5, 6, 7, 8, 10, 12]:
          let pay = cnt * stride
          let n = 1 + pay
          if n > r.n - i or n < 5: continue
          # require payload not all equal to count, and some structure
          var anyDiff = false
          var zeros = 0
          for j in 1 ..< n:
            if g[r.o + i + j] != g[r.o + i]: anyDiff = true
            if g[r.o + i + j] == 0: zeros += 1
          if not anyDiff: continue
          if zeros * 2 > pay: continue
          # for stride>=2 prefer low-variance first column or monotonic-ish
          if isFree(m, r.o + i, n):
            mark(m, r.o + i, n)
            add("countN", n)
            tot += n
            i += n
            claimedHere = true
            break
        if not claimedHere: i += 1

  # fixed rec size 3..12 with column structure: ≥4 recs, column 0 variance low OR col hi-byte constrained
  for rec in [3, 4, 5, 6, 7, 8, 9, 10, 12]:
    var tot = 0
    for r in freeRuns(m):
      if r.n < rec * 4: continue
      # slide for best align
      for align in 0 .. min(rec-1, r.n-1):
        let avail = r.n - align
        let nRec = avail div rec
        if nRec < 4: continue
        let n = nRec * rec
        let base = r.o + align
        # column stats
        var col0: CountTable[int]
        var hiOk = 0
        var nonZero = 0
        for i in 0 ..< nRec:
          col0.inc(g[base + i*rec].int)
          if rec >= 3:
            let bk = g[base + i*rec + rec-1].int
            if bk <= 0x0F or (bk >= 0xC0 and bk <= 0xEF) or bk == 0: hiOk += 1
          for j in 0 ..< rec:
            if g[base + i*rec + j] != 0: nonZero += 1
        if nonZero < n div 2: continue
        # top-1 of col0 covers ≥25% OR last column constrained ≥60%
        var top1 = 0
        for _, c in col0.pairs: top1 = max(top1, c)
        let lastOk = if rec >= 3: hiOk * 100 >= nRec * 60 else: false
        let colOk = top1 * 100 >= nRec * 25 and col0.len <= nRec div 2 + 2
        if not (colOk or lastOk): continue
        # not pure random: unique rows ratio
        var rows: CountTable[string]
        for i in 0 ..< nRec:
          var s = ""
          for j in 0 ..< rec: s.add char(g[base + i*rec + j])
          rows.inc(s)
        if rows.len < 2: continue
        if rows.len * 2 > nRec * 3 and not lastOk: continue # too unique unless last constrained
        if isFree(m, base, n):
          mark(m, base, n)
          add(&"fix{rec}", n)
          tot += n
          break # one align per run

  # FC/FB/FA multi-term recs 2..40
  for termByte in [0xFC, 0xFB, 0xFA, 0xF9, 0xF8]:
    var o = 0
    while o < g.len:
      if m[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not m[pos]:
        var k = pos
        while k < g.len and not m[k] and g[k] != termByte.uint8 and (k-pos) < 40: k += 1
        if k >= g.len or m[k] or g[k] != termByte.uint8: break
        let rl = k - pos + 1
        if rl < 2 or rl > 40: break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4 and isFree(m, start, n):
        var t = 0
        for j in 0..<n:
          if g[start+j] == termByte.uint8: t += 1
        if t == recs and t * 3 <= n * 2 and t < n:
          mark(m, start, n)
          add(&"t{termByte:02X}", n)
          o = pos
          continue
      o += 1

  # looser plane 40% ≥16B
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

  # looser cmd: top-3 cover ≥25%, min 12
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
    if isFree(m, r.o, r.n):
      mark(m, r.o, r.n)
      add("cmd25", r.n)

  # looser seqE0: e0xx>=1 notes>=2 e0>=1 dens lower
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

  # u16 LE table with hi-byte mostly 0 or small (bank-local-ish), ≥6 entries
  for r in freeRuns(m):
    if r.n < 12: continue
    var i = 0
    while i + 12 <= r.n:
      let base = r.o + i
      var cnt = 0
      var j = 0
      var prev = -1
      var hi0 = 0
      while i + j + 2 <= r.n:
        let v = g[base+j].int or (g[base+j+1].int shl 8)
        let hi = g[base+j+1].int
        if hi == 0 or hi <= 0x3F: hi0 += 1
        # allow non-mono if hi constrained
        cnt += 1
        j += 2
        prev = v
        if cnt >= 64: break
      # claim longest even prefix where ≥70% hi-byte ≤0x3F and not all zero
      # recompute from start with stop on bad hi streak
      cnt = 0; j = 0; hi0 = 0
      var anyNZ = false
      while i + j + 2 <= r.n:
        let lo = g[base+j].int
        let hi = g[base+j+1].int
        if hi > 0x7F: break
        if lo != 0 or hi != 0: anyNZ = true
        if hi <= 0x3F: hi0 += 1
        cnt += 1
        j += 2
        if cnt >= 128: break
      if cnt >= 6 and hi0 * 100 >= cnt * 70 and anyNZ:
        let n = cnt * 2
        if isFree(m, base, n):
          mark(m, base, n)
          add("u16lo", n)
          i += n
          continue
      i += 2

  # smooth 4-col residual: adjacent records change by small deltas (curve/path tables)
  for rec in [4, 5]:
    for r in freeRuns(m):
      if r.n < rec * 6: continue
      for align in 0..0:
        let nRec = (r.n - align) div rec
        if nRec < 6: continue
        let base = r.o + align
        var small = 0
        var totalCmp = 0
        for i in 1 ..< nRec:
          for j in 0 ..< rec:
            let a = g[base + (i-1)*rec + j].int
            let b = g[base + i*rec + j].int
            let d = abs(a - b)
            totalCmp += 1
            if d <= 8: small += 1
        if totalCmp == 0: continue
        if small * 100 < totalCmp * 55: continue
        # not constant
        var same = true
        for j in 0 ..< rec:
          if g[base+j] != g[base+rec+j]: same = false
        if same: continue
        let n = nRec * rec
        if isFree(m, base, n):
          mark(m, base, n)
          add(&"smooth{rec}", n)

  # AS remaining
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

  # ss remaining
  for r in freeRuns(m):
    if r.n < ScriptStreamMinLen: continue
    let consumed = consumeScriptStreamRun(g, r.o, r.n)
    if consumed >= ScriptStreamMinLen and isFree(m, r.o, consumed):
      mark(m, r.o, consumed)
      add("ss", consumed)

  # zero residual
  for r in freeRuns(m):
    if r.n < 2: continue
    var allZ = true
    for j in 0..<r.n:
      if g[r.o+j] != 0: allZ = false; break
    if allZ:
      mark(m, r.o, r.n)
      add("zero", r.n)

  # const residual
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

  # low-entropy residual: top-4 bytes cover ≥50%, len≥24
  for r in freeRuns(m):
    if r.n < 24: continue
    var u: CountTable[int]
    for j in 0..<r.n: u.inc(g[r.o+j].int)
    var top: seq[int] = @[]
    for _, c in u.pairs: top.add c
    top.sort(proc(a,b:int): int = cmp(b,a))
    var cover = 0
    for i in 0 ..< min(4, top.len): cover += top[i]
    if cover * 100 < r.n * 50: continue
    if u.len < 3: continue
    # not already zero/const
    mark(m, r.o, r.n)
    add("lowEnt", r.n)

  # u8 dense pair: byte[i] often equals byte[i+2] (interleaved streams)
  for r in freeRuns(m):
    if r.n < 20: continue
    var match = 0
    let lim = r.n - 2
    for j in 0..<lim:
      if g[r.o+j] == g[r.o+j+2]: match += 1
    if match * 100 < lim * 45: continue
    mark(m, r.o, r.n)
    add("stride2", r.n)

  var sum = 0
  var keys = newSeq[string]()
  for k in totals.keys: keys.add k
  keys.sort()
  echo "=== wave99 scout (greedy exclusive) ==="
  for k in keys:
    echo &"  {k}: {totals[k]} B / {spans[k]} spans"
    sum += totals[k]
  echo &"SUM: {sum} B (~{sum.float*100.0/3145728.0:.2f}%)"
  var left = 0
  for r in freeRuns(m): left += r.n
  echo &"left: {left} B"
  echo &"expected coverage ~{98.02 + sum.float*100.0/3145728.0:.2f}%"

main()
