## Wave100 residual scout: size hist + loosened families + context.
import
  std/[algorithm, strformat, strutils, tables, sets],
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

  var runs = freeRuns(claimed)
  runs.sort(proc(a,b: auto): int = cmp(b.n, a.n))
  var totalFree = 0
  for r in runs: totalFree += r.n
  echo &"total free={totalFree} runs={runs.len}"

  # size histogram
  var hist: array[9, int]  # 1,2-3,4-7,8-15,16-31,32-63,64-127,128+
  for r in runs:
    let n = r.n
    if n == 1: hist[0] += n
    elif n <= 3: hist[1] += n
    elif n <= 7: hist[2] += n
    elif n <= 15: hist[3] += n
    elif n <= 31: hist[4] += n
    elif n <= 63: hist[5] += n
    elif n <= 127: hist[6] += n
    elif n <= 255: hist[7] += n
    else: hist[8] += n
  echo "size hist bytes: 1=", hist[0], " 2-3=", hist[1], " 4-7=", hist[2],
    " 8-15=", hist[3], " 16-31=", hist[4], " 32-63=", hist[5],
    " 64-127=", hist[6], " 128-255=", hist[7], " 256+=", hist[8]

  # count runs by size buckets
  var rh: array[9, int]
  for r in runs:
    let n = r.n
    if n == 1: rh[0] += 1
    elif n <= 3: rh[1] += 1
    elif n <= 7: rh[2] += 1
    elif n <= 15: rh[3] += 1
    elif n <= 31: rh[4] += 1
    elif n <= 63: rh[5] += 1
    elif n <= 127: rh[6] += 1
    elif n <= 255: rh[7] += 1
    else: rh[8] += 1
  echo "size hist runs: 1=", rh[0], " 2-3=", rh[1], " 4-7=", rh[2],
    " 8-15=", rh[3], " 16-31=", rh[4], " 32-63=", rh[5],
    " 64-127=", rh[6], " 128-255=", rh[7], " 256+=", rh[8]

  # top 40 free with neighbors
  echo "\n=== top 40 free + neighbor kinds ==="
  # build kind map for quick lookup
  var kindAt = newSeq[string](g.len)
  for c in allRomChunksMeta():
    let kn = case c.kind
      of ckImplementedCode: "code"
      of ckImplementedMeta: "meta"
      of ckUnclaimed: "free"
    for j in 0 ..< c.length:
      if c.offset + j < kindAt.len: kindAt[c.offset + j] = kn

  for i in 0 ..< min(40, runs.len):
    let r = runs[i]
    var hx = ""
    for j in 0 ..< min(24, r.n):
      hx.add &"{g[r.o+j]:02X} "
    let left = if r.o > 0: kindAt[r.o - 1] else: "edge"
    let right = if r.o + r.n < g.len: kindAt[r.o + r.n] else: "edge"
    # entropy-ish unique count
    var seen: set[uint8]
    for j in 0 ..< r.n: seen.incl g[r.o+j]
    echo &"0x{r.o:06X}+{r.n:3} L={left:4} R={right:4} uniq={seen.card:3} | {hx}"

  # greedy loosened scouts
  var m = claimed
  var totals: Table[string, int]
  proc add(k: string; n: int) =
    if k notin totals: totals[k] = 0
    totals[k] = totals[k] + n

  # AS minlen 3
  for r in freeRuns(m):
    if r.n < 3: continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      mark(m, r.o, r.n); add("as3", r.n)

  # SS min gates looser (walk-based)
  for r in freeRuns(m):
    if r.n < 4: continue
    let w = walkScriptStream(g, r.o, r.o + r.n)
    if w.ended and w.length >= 4 and w.length <= r.n and w.badGlyphs == 0 and w.glyphs >= 2:
      mark(m, r.o, w.length); add("ss4", w.length)

  # term F0-FF multi/single quality
  for termByte in 0xF0..0xFF:
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
      if recs >= 2 and n >= 4:
        var tc = 0
        for j in 0..<n:
          if g[start+j] == termByte.uint8: tc += 1
        if tc == recs:
          mark(m, start, n); add(&"t{termByte:02X}", n); o = pos; continue
      # quality single: one term at end, len 4..32, not mostly term
      if recs == 1 and n >= 4 and n <= 32:
        var tc = 0
        for j in 0..<n:
          if g[start+j] == termByte.uint8: tc += 1
        if tc == 1 and g[start+n-1] == termByte.uint8:
          mark(m, start, n); add(&"t{termByte:02X}s", n); o = pos; continue
      o += 1

  # u8pair looser: 55% ratio, 4 recs
  for r in freeRuns(m):
    if r.n < 8 or r.n mod 2 != 0: continue
    let nRec = r.n div 2
    if nRec < 4: continue
    var ok, nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o+i*2]; let b = g[r.o+i*2+1]
      if a <= 0x50 or b <= 0x50: ok += 1
      if a != 0 or b != 0: nz += 1
    if ok * 100 < nRec * 55: continue
    if nz * 2 < nRec: continue
    mark(m, r.o, r.n); add("u8pair55", r.n)

  # countN looser: min 4, fill 25%
  const strides = [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,20,24,25,27,32,41]
  for r in freeRuns(m):
    if r.n < 4: continue
    var i = 0
    while i < r.n:
      var best = 0
      for hdr in 1..2:
        for stride in strides:
          if i + hdr > r.n: continue
          let cnt = if hdr == 1: g[r.o+i].int else:
            if i+1 >= r.n: continue else: g[r.o+i].int or (g[r.o+i+1].int shl 8)
          if cnt < 2 or cnt > 200: continue
          let need = hdr + cnt * stride
          if need < 4 or i + need > r.n: continue
          let rem = r.n - i
          if need < rem div 4 and need != rem: continue
          var z = 0
          for j in hdr ..< need:
            if g[r.o+i+j] == 0: z += 1
          if z * 2 > (need - hdr): continue
          if need > best: best = need
      if best >= 4 and isFree(m, r.o+i, best):
        mark(m, r.o+i, best); add("countNloose", best); i += best
      else: i += 1

  # fixN col looser 3..16, min 3 recs, cover 25%
  for rec in 3..16:
    for r in freeRuns(m):
      if r.n < rec * 3: continue
      for align in 0 ..< min(rec, 3):
        let nRec = (r.n - align) div rec
        if nRec < 3: continue
        let n = nRec * rec
        let base = r.o + align
        if not isFree(m, base, n): continue
        var col0: CountTable[int]
        var nz = 0
        for i in 0 ..< nRec:
          col0.inc(g[base + i*rec].int)
          for j in 0 ..< rec:
            if g[base+i*rec+j] != 0: nz += 1
        if nz < n div 3: continue
        var tops: seq[int] = @[]
        for _, c in col0.pairs: tops.add c
        tops.sort(proc(a,b:int): int = cmp(b,a))
        var cover = 0
        for i in 0 ..< min(3, tops.len): cover += tops[i]
        if cover * 100 < nRec * 25: continue
        mark(m, base, n); add(&"fix{rec}c25", n); break

  # plane pair 25%
  for r in freeRuns(m):
    if r.n < 12 or r.n mod 2 != 0: continue
    var eq = 0
    let pairs = r.n div 2
    for i in 0 ..< pairs:
      if g[r.o+i*2] == g[r.o+i*2+1]: eq += 1
    if eq * 100 < pairs * 25: continue
    mark(m, r.o, r.n); add("plane25", r.n)

  # cmd even 15%
  for r in freeRuns(m):
    if r.n < 12 or r.n mod 2 != 0: continue
    var ct: CountTable[int]
    let pairs = r.n div 2
    for i in 0 ..< pairs: ct.inc(g[r.o+i*2].int)
    var tops: seq[int] = @[]
    for _, c in ct.pairs: tops.add c
    tops.sort(proc(a,b:int): int = cmp(b,a))
    var cover = 0
    for i in 0 ..< min(3, tops.len): cover += tops[i]
    if cover * 100 < pairs * 15: continue
    mark(m, r.o, r.n); add("cmd15", r.n)

  # lowEnt top6 30%
  for r in freeRuns(m):
    if r.n < 12: continue
    var ct: CountTable[int]
    for j in 0 ..< r.n: ct.inc(g[r.o+j].int)
    var tops: seq[int] = @[]
    for _, c in ct.pairs: tops.add c
    tops.sort(proc(a,b:int): int = cmp(b,a))
    var cover = 0
    for i in 0 ..< min(6, tops.len): cover += tops[i]
    if cover * 100 < r.n * 30: continue
    mark(m, r.o, r.n); add("lowEnt30", r.n)

  # u8lo 55%
  for r in freeRuns(m):
    if r.n < 8: continue
    var lo = 0
    for j in 0 ..< r.n:
      if g[r.o+j] <= 0x3F: lo += 1
    if lo * 100 < r.n * 55: continue
    mark(m, r.o, r.n); add("u8lo55", r.n)

  # consecutive delta-smooth 1B stream
  for r in freeRuns(m):
    if r.n < 12: continue
    var sm = 0
    for j in 1 ..< r.n:
      if abs(g[r.o+j].int - g[r.o+j-1].int) <= 8: sm += 1
    if sm * 100 < (r.n-1) * 40: continue
    mark(m, r.o, r.n); add("smooth1", r.n)

  # run of printable/ASCII-ish (0x20-0x7E or EB text range)
  for r in freeRuns(m):
    if r.n < 6: continue
    var pr = 0
    for j in 0 ..< r.n:
      let b = g[r.o+j]
      if (b >= 0x20 and b <= 0x7E) or (b >= 0x50 and b <= 0x90): pr += 1
    if pr * 100 < r.n * 70: continue
    mark(m, r.o, r.n); add("print70", r.n)

  # zero pad
  for r in freeRuns(m):
    if r.n < 1: continue
    var z = true
    for j in 0 ..< r.n:
      if g[r.o+j] != 0: z = false
    if z: mark(m, r.o, r.n); add("zero", r.n)

  # const fill
  for r in freeRuns(m):
    if r.n < 3: continue
    var same = true
    let v = g[r.o]
    for j in 1 ..< r.n:
      if g[r.o+j] != v: same = false
    if same: mark(m, r.o, r.n); add("const", r.n)

  # far3 ≥1 (single far ptr)
  for r in freeRuns(m):
    if r.n < 3: continue
    var i = 0
    var claimedN = 0
    while i + 3 <= r.n:
      let b = g[r.o+i+2]
      if b >= 0xC0 and b <= 0xEF:
        claimedN += 3
        i += 3
      else: break
    if claimedN >= 3 and isFree(m, r.o, claimedN):
      mark(m, r.o, claimedN); add("far3s", claimedN)

  # remaining free after all
  var left = 0
  var leftRuns = 0
  for r in freeRuns(m):
    left += r.n
    leftRuns += 1

  echo "\n=== scout totals (greedy exclusive) ==="
  var keys: seq[string] = @[]
  for k in totals.keys: keys.add k
  keys.sort()
  var sum = 0
  for k in keys:
    echo &"  {k}: {totals[k]}"
    sum += totals[k]
  echo &"SUM claimable under loose: {sum}"
  echo &"residual left: {left} ({leftRuns} runs)"

  # show largest remaining after scouts
  var leftList = freeRuns(m)
  leftList.sort(proc(a,b: auto): int = cmp(b.n, a.n))
  echo "\n=== top 25 remaining after scouts ==="
  for i in 0 ..< min(25, leftList.len):
    let r = leftList[i]
    var hx = ""
    for j in 0 ..< min(24, r.n):
      hx.add &"{g[r.o+j]:02X} "
    echo &"0x{r.o:06X}+{r.n:3} | {hx}"

main()
