## Wave98 residual scout: only structures that can pass extract tests.
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
  var invClaimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)
      mark(invClaimed, c.offset, c.length)
  var cm = claimed
  var totals: Table[string, int]
  var nSpans: Table[string, int]
  proc add(k: string; n: int) =
    if k notin totals: totals[k] = 0; nSpans[k] = 0
    totals[k] = totals[k] + n
    nSpans[k] = nSpans[k] + 1

  # 1) FE-term multi 2..32 (mirror ffRec quality)
  block:
    var o = 0
    while o < g.len:
      if cm[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not cm[pos]:
        var k = pos
        while k < g.len and not cm[k] and g[k] != 0xFE and (k-pos) < 32: k += 1
        if k >= g.len or cm[k] or g[k] != 0xFE: break
        let rl = k - pos + 1
        if rl < 2 or rl > 32: break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var fe = 0
        for j in 0..<n:
          if g[start+j] == 0xFE: fe += 1
        if fe == recs and fe * 3 <= n * 2 and fe < n:
          mark(cm, start, n); add("feRec", n); o = pos; continue
      o += 1

  # 2) FE single quality 3..32
  block:
    var o = 0
    while o < g.len:
      if cm[o]: o += 1; continue
      var k = o
      while k < g.len and not cm[k] and g[k] != 0xFE and (k-o) < 32: k += 1
      if k < g.len and not cm[k] and g[k] == 0xFE:
        let n = k - o + 1
        if n >= 3 and n <= 32:
          var fe, hi, z = 0
          for j in 0..<n:
            if g[o+j] == 0xFE: fe += 1
            if g[o+j] >= 0xE0: hi += 1
            if g[o+j] == 0: z += 1
          if fe == 1 and hi * 2 <= n and z * 3 <= n:
            mark(cm, o, n); add("feSingle", n); o = k + 1; continue
      o += 1

  # 3) AS that pass isGoodActionScriptSpan (current gates)
  block:
    for r in freeRuns(cm):
      if r.n < ActionScriptMinLen: continue
      if isGoodActionScriptSpan(g, r.o, r.n):
        mark(cm, r.o, r.n); add("asGood", r.n)
        continue
      # also consume prefix of run
      let taken = consumeActionScriptRun(g, r.o, r.n)
      if taken >= ActionScriptMinLen and isGoodActionScriptSpan(g, r.o, taken):
        mark(cm, r.o, taken); add("asGood", taken)

  # 4) SS that pass isGoodScriptStream (full end in free)
  block:
    for r in freeRuns(cm):
      if r.n < ScriptStreamMinLen: continue
      let consumed = consumeScriptStreamRun(g, r.o, r.n)
      if consumed >= ScriptStreamMinLen:
        mark(cm, r.o, consumed); add("ssGood", consumed)

  # 5) ssPrefix (cross-boundary) remaining
  block:
    for r in freeRuns(cm):
      if r.n < ScriptStreamMinLen: continue
      let wFree = walkScriptStream(g, r.o, r.o + r.n)
      if wFree.badGlyphs != 0 or wFree.ended or wFree.length != r.n: continue
      if wFree.glyphs < ScriptStreamMinGlyphs: continue
      let totalTok = wFree.glyphs + wFree.controls
      if totalTok == 0: continue
      if wFree.glyphs.float / totalTok.float < ScriptStreamMinGlyphRatio: continue
      if r.o + r.n >= g.len or not invClaimed[r.o + r.n]: continue
      let wFull = walkScriptStream(g, r.o, min(r.o + ScriptStreamMaxLen, g.len))
      if not isGoodScriptStream(wFull) or wFull.length <= r.n: continue
      mark(cm, r.o, r.n); add("ssPrefix", r.n)

  # 6) far3 remaining ≥3 chain
  block:
    for r in freeRuns(cm):
      if r.n < 9: continue
      var p = r.o
      while p + 9 <= r.o + r.n:
        var q = p
        var good = 0
        while q + 3 <= r.o + r.n:
          let bk = g[q+2].int
          if bk < 0xC0 or bk > 0xEF: break
          good += 1
          q += 3
        if good >= 3:
          let n = good * 3
          if isFree(cm, p, n):
            mark(cm, p, n); add("far3", n)
          p = q
        else:
          p += 1

  # 7) far4 ≥3 (lo16+bank+00)
  block:
    for r in freeRuns(cm):
      if r.n < 12: continue
      var p = r.o
      while p + 12 <= r.o + r.n:
        var q = p
        var good = 0
        while q + 4 <= r.o + r.n:
          let bk = g[q+2].int
          let pad = g[q+3].int
          if bk < 0xC0 or bk > 0xEF or pad != 0: break
          good += 1
          q += 4
        if good >= 3:
          let n = good * 4
          if isFree(cm, p, n):
            mark(cm, p, n); add("far4", n)
          p = q
        else:
          p += 1

  # 8) zRec remaining with slightly looser: ≥2 recs, 2..16
  block:
    var o = 0
    while o < g.len:
      if cm[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not cm[pos]:
        var k = pos
        while k < g.len and not cm[k] and g[k] != 0 and (k-pos) < 16: k += 1
        if k >= g.len or cm[k] or g[k] != 0: break
        let rl = k - pos + 1
        if rl < 2 or rl > 16: break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var zeros, hi, printable = 0
        for j in 0..<n:
          if g[start+j] == 0: zeros += 1
          if g[start+j] >= 0x80: hi += 1
          if g[start+j] >= 0x20 and g[start+j] < 0x7F: printable += 1
        if zeros == recs and hi * 3 <= n and printable * 2 >= n:
          mark(cm, start, n); add("zRec2", n); o = pos; continue
      o += 1

  # 9) w4hi0 remaining ≥2 words (looser)
  block:
    for r in freeRuns(cm):
      if r.n < 8 or r.n mod 4 != 0: continue
      let words = r.n div 4
      if words < 2: continue
      var zhi = 0
      for i in 0..<words:
        if g[r.o + i*4 + 3] == 0: zhi += 1
      if zhi != words: continue
      var any = false
      for j in 0..<r.n:
        if g[r.o+j] != 0: any = true; break
      if not any: continue
      mark(cm, r.o, r.n); add("w4hi0", r.n)

  # 10) const non-zero fill ≥8
  block:
    for r in freeRuns(cm):
      if r.n < 8: continue
      let v = g[r.o]
      if v == 0: continue
      var all = true
      for j in 1..<r.n:
        if g[r.o+j] != v: all = false; break
      if all:
        mark(cm, r.o, r.n); add("constFill", r.n)

  # 11) 5B [far][00][type1..8] ≥3
  block:
    for r in freeRuns(cm):
      if r.n < 15: continue
      var p = r.o
      while p + 15 <= r.o + r.n:
        var q = p
        var good = 0
        while q + 5 <= r.o + r.n:
          let bk = g[q+2].int
          if bk < 0xC0 or bk > 0xEF or g[q+3] != 0: break
          let t = g[q+4].int
          if t < 1 or t > 8: break
          good += 1
          q += 5
        if good >= 3:
          let n = good * 5
          if isFree(cm, p, n):
            mark(cm, p, n); add("far5t", n)
          p = q
        else:
          p += 1

  # 12) mirrored SNES plane rows: ≥32 B free, ≥60% adjacent equal pairs, not all 0
  block:
    for r in freeRuns(cm):
      if r.n < 32: continue
      let nPairs = r.n div 2
      var pairs = 0
      for i in 0 ..< nPairs:
        if g[r.o + i*2] == g[r.o + i*2 + 1]: pairs += 1
      if pairs * 5 < nPairs * 3: continue  # ≥60%
      var anyNZ = false
      for j in 0..<r.n:
        if g[r.o+j] != 0: anyNZ = true; break
      if not anyNZ: continue
      # reject if too many 0xFF (ffRec territory)
      var ff = 0
      for j in 0..<r.n:
        if g[r.o+j] == 0xFF: ff += 1
      if ff * 4 >= r.n: continue
      let n = nPairs * 2
      mark(cm, r.o, n); add("planePair", n)

  # 13) u16 mono ptr tables ≥6 entries, non-decreasing, values in bank-local range
  block:
    for r in freeRuns(cm):
      if r.n < 12: continue
      var i = 0
      while i + 12 <= r.n:
        let base = r.o + i
        var cnt = 1
        var prev = g[base].int or (g[base+1].int shl 8)
        var j = 2
        while i + j + 2 <= r.n:
          let v = g[base+j].int or (g[base+j+1].int shl 8)
          if v < prev: break
          if v == prev and v == 0: break
          # allow plateaus
          prev = v
          cnt += 1
          j += 2
        if cnt >= 6 and prev >= 0x100 and prev <= 0xFFFF:
          let n = cnt * 2
          if isFree(cm, base, n):
            mark(cm, base, n); add("u16mono", n)
            i += n
            continue
        i += 2

  # 14) FD-terminated short multi (some EB tables use FD)
  block:
    var o = 0
    while o < g.len:
      if cm[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not cm[pos]:
        var k = pos
        while k < g.len and not cm[k] and g[k] != 0xFD and (k-pos) < 32: k += 1
        if k >= g.len or cm[k] or g[k] != 0xFD: break
        let rl = k - pos + 1
        if rl < 2 or rl > 32: break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var fd = 0
        for j in 0..<n:
          if g[start+j] == 0xFD: fd += 1
        if fd == recs and fd * 3 <= n * 2 and fd < n:
          mark(cm, start, n); add("fdRec", n); o = pos; continue
      o += 1

  # 15) zero-pad remaining ≥2
  block:
    for r in freeRuns(cm):
      if r.n < 2: continue
      var allZ = true
      for j in 0..<r.n:
        if g[r.o+j] != 0: allZ = false; break
      if allZ:
        mark(cm, r.o, r.n); add("zeroPad", r.n)

  echo "=== wave98 solid scouts ==="
  var keys = newSeq[string]()
  for k in totals.keys: keys.add k
  keys.sort()
  var sum = 0
  for k in keys:
    echo &"  {k}: {totals[k]} B in {nSpans[k]} spans"
    sum += totals[k]
  echo &"SUM: {sum} B (~+{sum.float*100.0/3145728.0:.2f}% → ~{97.00+sum.float*100.0/3145728.0:.2f}%)"
  var rem = 0
  for r in freeRuns(cm): rem += r.n
  echo &"left residual: {rem} B"

main()
