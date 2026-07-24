## Quick residual free-run stats + hex heads + format scouts.
import
  std/[algorithm, strformat, strutils, tables, sets],
  ../decompbound/[rom_chunks, baserom_extract, memmap, text_decode, action_script, gfx_lz]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

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

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len: return false
  for j in 0 ..< n:
    if claimed[o + j]: return false
  true

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
  var runs = freeRuns(claimed)
  runs.sort(proc(a,b: auto): int = cmp(b.n, a.n))

  # bank residual totals
  var bankTot: array[0x30, int]
  for r in runs:
    let b = r.o shr 16
    if b < bankTot.len: bankTot[b] += r.n
  echo "=== residual by file bank ==="
  var pairs: seq[tuple[b, n: int]] = @[]
  for b in 0 ..< bankTot.len:
    if bankTot[b] > 0: pairs.add (b, bankTot[b])
  pairs.sort(proc(a,b: auto): int = cmp(b.n, a.n))
  for p in pairs[0 ..< min(20, pairs.len)]:
    echo &"  bank 0x{p.b:02X} (${p.b+0xC0:02X}): {p.n} B"

  echo "\n=== top 25 free runs (head hex + stats) ==="
  for i in 0 ..< min(25, runs.len):
    let r = runs[i]
    var zs, ffs, e0s, hi = 0
    let show = min(32, r.n)
    var hx = ""
    for j in 0 ..< r.n:
      if g[r.o+j] == 0: zs += 1
      if g[r.o+j] == 0xFF: ffs += 1
      if g[r.o+j] >= 0xE0: e0s += 1
      if g[r.o+j] >= 0x80: hi += 1
    for j in 0 ..< show:
      hx.add &"{g[r.o+j]:02X} "
    echo &"0x{r.o:06X}+{r.n:4} z={zs:3} ff={ffs:3} e0={e0s:3} hi={hi:3} | {hx}"

  # scout formats not yet drained
  var claimMask = claimed
  var totals: Table[string, int]
  proc add(k: string; n: int) =
    if k notin totals: totals[k] = 0
    totals[k] = totals[k] + n

  # FE-terminated short recs 2..32 multi
  block:
    var o = 0
    var tot = 0
    while o < g.len:
      if claimMask[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not claimMask[pos]:
        var k = pos
        while k < g.len and not claimMask[k] and g[k] != 0xFE and (k-pos) < 32: k += 1
        if k >= g.len or claimMask[k] or g[k] != 0xFE: break
        let rl = k - pos + 1
        if rl < 2 or rl > 32: break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var fe = 0
        for j in 0..<n:
          if g[start+j] == 0xFE: fe += 1
        if fe == recs and fe * 3 <= n * 2:
          mark(claimMask, start, n)
          tot += n
          o = pos
          continue
      o += 1
    add("feRec", tot)

  # u16 LE monotonic bank-local ptr tables (>=8 entries, free)
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 16 or r.n mod 2 != 0: continue
      # scan for longest monotonic increasing u16 runs with high-ish values
      var i = 0
      while i + 16 <= r.n:
        let base = r.o + i
        var cnt = 1
        var prev = g[base].int or (g[base+1].int shl 8)
        var j = 2
        while i + j + 2 <= r.n:
          let v = g[base+j].int or (g[base+j+1].int shl 8)
          if v < prev: break
          if v == 0 and prev == 0: break
          prev = v
          cnt += 1
          j += 2
        if cnt >= 8 and prev > 0x100:
          let n = cnt * 2
          if isFree(claimMask, base, n):
            mark(claimMask, base, n)
            tot += n
            i += n
            continue
        i += 2
    add("u16mono", tot)

  # fixed-size: try rec sizes 5..20 on free runs ≥40, score consistency of high-byte pattern
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 40: continue
      var bestSz = 0
      var bestScore = 0.0
      for sz in 5..20:
        if r.n < sz * 4: continue
        let nRec = r.n div sz
        if nRec < 4: continue
        # score: fraction of records where byte@pos has low variance, bank-like high bytes
        var bankish = 0
        for i in 0 ..< nRec:
          let b = g[r.o + i*sz + sz - 1]
          if b >= 0xC0 and b <= 0xEF: bankish += 1
        let score = bankish.float / nRec.float
        if score > bestScore:
          bestScore = score
          bestSz = sz
      if bestScore >= 0.7 and bestSz > 0:
        let n = (r.n div bestSz) * bestSz
        if n >= bestSz * 4 and isFree(claimMask, r.o, n):
          mark(claimMask, r.o, n)
          tot += n
    add("fixedFarHi", tot)

  # 2B far bank pairs? actually 4B far ptrs bank C0-EF
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 16: continue
      var p = r.o
      while p + 16 <= r.o + r.n:
        var q = p
        var good = 0
        while q + 4 <= r.o + r.n:
          let bk = g[q+2].int
          let pad = g[q+3].int
          if bk < 0xC0 or bk > 0xEF: break
          if pad != 0 and pad != 0x00: break  # allow only 00 pad
          good += 1
          q += 4
        if good >= 4:
          let n = good * 4
          if isFree(claimMask, p, n):
            mark(claimMask, p, n)
            tot += n
          p = q
        else:
          p += 1
    add("far4", tot)

  # 5B [far3][00][type] like CE62EE
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 20: continue
      var p = r.o
      while p + 20 <= r.o + r.n:
        var q = p
        var good = 0
        while q + 5 <= r.o + r.n:
          let bk = g[q+2].int
          let z = g[q+3].int
          let t = g[q+4].int
          if bk < 0xC0 or bk > 0xEF: break
          if z != 0: break
          if t < 1 or t > 8: break
          good += 1
          q += 5
        if good >= 4:
          let n = good * 5
          if isFree(claimMask, p, n):
            mark(claimMask, p, n)
            tot += n
          p = q
        else:
          p += 1
    add("far5type", tot)

  # residual AS with looser gates
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 4: continue
      for d in 0 ..< min(2, r.n):
        let w = walkActionScript(g, r.o + d, r.o + r.n)
        if w.length >= 4 and w.ended and w.length <= r.n - d:
          if isFree(claimMask, r.o+d, w.length):
            mark(claimMask, r.o+d, w.length)
            tot += w.length
            break
    add("asLoose", tot)

  # residual SS with looser (min glyphs 2, ratio 0.2, min len 4)
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 4: continue
      let w = walkScriptStream(g, r.o, r.o + r.n)
      if w.ended and w.badGlyphs == 0 and w.length >= 4 and w.glyphs >= 2:
        let totTok = w.glyphs + w.controls
        if totTok > 0 and w.glyphs.float / totTok.float >= 0.2:
          if isFree(claimMask, r.o, w.length):
            mark(claimMask, r.o, w.length)
            tot += w.length
    add("ssLoose", tot)

  # FF rec expand to 48
  block:
    var o = 0
    var tot = 0
    while o < g.len:
      if claimMask[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not claimMask[pos]:
        var k = pos
        while k < g.len and not claimMask[k] and g[k] != 0xFF and (k-pos) < 48: k += 1
        if k >= g.len or claimMask[k] or g[k] != 0xFF: break
        let rl = k - pos + 1
        if rl < 2 or rl > 48: break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var ff = 0
        for j in 0..<n:
          if g[start+j] == 0xFF: ff += 1
        if ff == recs and ff * 3 <= n * 2 and ff < n:
          mark(claimMask, start, n)
          tot += n
          o = pos
          continue
      o += 1
    add("ffRec48", tot)

  # singles FF 33..64 quality
  block:
    var o = 0
    var tot = 0
    while o < g.len:
      if claimMask[o]: o += 1; continue
      var k = o
      while k < g.len and not claimMask[k] and g[k] != 0xFF and (k-o) < 64: k += 1
      if k < g.len and not claimMask[k] and g[k] == 0xFF:
        let n = k - o + 1
        if n >= 33 and n <= 64:
          var ff, hi, z = 0
          for j in 0..<n:
            if g[o+j] == 0xFF: ff += 1
            if g[o+j] >= 0xE0: hi += 1
            if g[o+j] == 0: z += 1
          if ff == 1 and hi * 2 <= n and z * 3 <= n:
            mark(claimMask, o, n)
            tot += n
            o = k + 1
            continue
      o += 1
    add("ffSingleLong", tot)

  # 2B words with high byte 0 (u16 LE low)
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 16 or r.n mod 2 != 0: continue
      let words = r.n div 2
      if words < 8: continue
      var zhi = 0
      for i in 0..<words:
        if g[r.o + i*2 + 1] == 0: zhi += 1
      if zhi == words:
        var any = false
        for j in 0..<r.n:
          if g[r.o+j] != 0: any = true; break
        if any and isFree(claimMask, r.o, r.n):
          mark(claimMask, r.o, r.n)
          tot += r.n
    add("w2hi0", tot)

  # residual runs that are entirely BRR-like (loop flags etc) — skip for now

  # partial free runs that are 100% fill with constant non-zero
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 8: continue
      let v = g[r.o]
      if v == 0: continue
      var all = true
      for j in 1..<r.n:
        if g[r.o+j] != v: all = false; break
      if all:
        mark(claimMask, r.o, r.n)
        tot += r.n
    add("constFill", tot)

  # count+N*payload patterns: u8 count then count*k
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 8: continue
      # try at start of run
      for stride in [2, 3, 4, 5, 6, 8, 10, 12]:
        let cnt = g[r.o].int
        if cnt < 2 or cnt > 40: continue
        let need = 1 + cnt * stride
        if need > r.n: continue
        # verify remainder is free and maybe ends cleanly
        if isFree(claimMask, r.o, need):
          # weak: require trailing free < stride or exact
          if need == r.n or (r.n - need) < stride:
            mark(claimMask, r.o, need)
            tot += need
            break
    add("countN", tot)

  echo "\n=== format scout totals (mutually exclusive greedy) ==="
  var keys = newSeq[string]()
  for k in totals.keys: keys.add k
  keys.sort()
  var sum = 0
  for k in keys:
    echo &"  {k}: {totals[k]} B"
    sum += totals[k]
  echo &"SUM: {sum} B  (~{sum.float*100.0/3145728.0:.2f}% coverage delta)"

  # remaining after scouts
  var rem = 0
  for r in freeRuns(claimMask): rem += r.n
  echo &"residual left after scouts: {rem} B"

main()
