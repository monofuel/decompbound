## Deeper residual packing: audio-like, tileplane pairs, u8/u16 tables, FE, count*N.
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
  var claimMask = claimed
  var totals: Table[string, int]
  proc add(k: string; n: int) =
    if k notin totals: totals[k] = 0
    totals[k] = totals[k] + n

  # --- mirrored-pair bitplane residual (common in SNES 2bpp/4bpp rows) ---
  # pattern: pairs of equal bytes, or ab ab ab...
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 32: continue
      # measure pair-repeat: g[i]==g[i+1] for even i
      var pairs = 0
      let nPairs = r.n div 2
      for i in 0 ..< nPairs:
        if g[r.o + i*2] == g[r.o + i*2 + 1]: pairs += 1
      let ratio = pairs.float / nPairs.float
      if ratio >= 0.45 and nPairs >= 16:
        # claim full even length
        let n = nPairs * 2
        if isFree(claimMask, r.o, n):
          mark(claimMask, r.o, n)
          tot += n
    add("pairMirror", tot)

  # --- SPC-ish command streams: many high ops (>=0x80) with short payload ---
  # heuristic: free run where ≥40% of bytes in 0x80-0x9F and low zero rate
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 24: continue
      var opish, z, e0 = 0
      for j in 0 ..< r.n:
        let b = g[r.o+j]
        if b >= 0x80 and b <= 0x9F: opish += 1
        if b == 0: z += 1
        if b >= 0xE0: e0 += 1
      if opish * 5 >= r.n * 2 and z * 10 <= r.n and e0 * 4 <= r.n:
        if isFree(claimMask, r.o, r.n):
          mark(claimMask, r.o, r.n)
          tot += r.n
    add("spcOpish", tot)

  # --- FE-terminated multi (2..40) ---
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
        while k < g.len and not claimMask[k] and g[k] != 0xFE and (k-pos) < 40: k += 1
        if k >= g.len or claimMask[k] or g[k] != 0xFE: break
        let rl = k - pos + 1
        if rl < 2 or rl > 40: break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var fe = 0
        for j in 0..<n:
          if g[start+j] == 0xFE: fe += 1
        if fe == recs and fe * 3 <= n * 2 and fe < n:
          mark(claimMask, start, n)
          tot += n
          o = pos
          continue
      o += 1
    add("feRec", tot)

  # --- FE single quality 3..40 ---
  block:
    var o = 0
    var tot = 0
    while o < g.len:
      if claimMask[o]: o += 1; continue
      var k = o
      while k < g.len and not claimMask[k] and g[k] != 0xFE and (k-o) < 40: k += 1
      if k < g.len and not claimMask[k] and g[k] == 0xFE:
        let n = k - o + 1
        if n >= 3 and n <= 40:
          var fe, hi, z = 0
          for j in 0..<n:
            if g[o+j] == 0xFE: fe += 1
            if g[o+j] >= 0xE0: hi += 1
            if g[o+j] == 0: z += 1
          if fe == 1 and hi * 2 <= n and z * 3 <= n:
            mark(claimMask, o, n)
            tot += n
            o = k + 1
            continue
      o += 1
    add("feSingle", tot)

  # --- 2B fixed records with range-limited fields (common anim/table) ---
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 16 or r.n mod 2 != 0: continue
      let nRec = r.n div 2
      if nRec < 8: continue
      # both bytes usually small-ish or structured
      var ok = 0
      for i in 0 ..< nRec:
        let a = g[r.o + i*2]
        let b = g[r.o + i*2 + 1]
        if a <= 0x40 or b <= 0x40: ok += 1
      if ok * 4 >= nRec * 3:
        if isFree(claimMask, r.o, r.n):
          mark(claimMask, r.o, r.n)
          tot += r.n
    add("u8pair", tot)

  # --- AS good walks with minLen 4, minSig 0, ops>=1 ended ---
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 4: continue
      var pos = r.o
      var taken = 0
      while pos < r.o + r.n:
        let w = walkActionScript(g, pos, r.o + r.n)
        if w.ended and w.length >= 4 and w.ops >= 1 and pos + w.length <= r.o + r.n:
          taken += w.length
          pos += w.length
        else:
          break
      if taken >= 4 and taken >= r.n div 2:  # majority of run
        # claim only taken prefix if free
        if isFree(claimMask, r.o, taken):
          mark(claimMask, r.o, taken)
          tot += taken
    add("asChain", tot)

  # --- SS looser ---
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

  # --- count + N*stride with stricter verification (header count matches) ---
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 6: continue
      var best = 0
      for hdr in 1..2:  # 1-byte or 2-byte count
        for stride in [1, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 17]:
          let cnt = if hdr == 1: g[r.o].int else: g[r.o].int or (g[r.o+1].int shl 8)
          if cnt < 2 or cnt > 80: continue
          let need = hdr + cnt * stride
          if need > r.n or need < 6: continue
          # score: low zero density in payload unless stride large
          var z = 0
          for j in hdr ..< need:
            if g[r.o+j] == 0: z += 1
          if z * 2 > need: continue
          if need > best: best = need
      if best >= 6 and isFree(claimMask, r.o, best):
        mark(claimMask, r.o, best)
        tot += best
    add("countNstrict", tot)

  # --- 3B records with bank-ish third byte (not full far - mid range) ---
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 24 or r.n mod 3 != 0: continue
      let nRec = r.n div 3
      if nRec < 8: continue
      var banks = 0
      for i in 0 ..< nRec:
        let b = g[r.o + i*3 + 2]
        if b >= 0xC0 and b <= 0xEF: banks += 1
      if banks * 5 >= nRec * 4:
        if isFree(claimMask, r.o, r.n):
          mark(claimMask, r.o, r.n)
          tot += r.n
    add("rec3far", tot)

  # --- 8B records residual ---
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 64 or r.n mod 8 != 0: continue
      let nRec = r.n div 8
      if nRec < 4: continue
      # require each record's last or mid byte patterned
      var score = 0
      for i in 0 ..< nRec:
        let b = g[r.o + i*8 + 2]
        if b >= 0xC0 and b <= 0xEF: score += 1
        let b2 = g[r.o + i*8 + 3]
        if b2 == 0: score += 1
      if score >= nRec:  # average ≥1 patterned field
        if isFree(claimMask, r.o, r.n):
          mark(claimMask, r.o, r.n)
          tot += r.n
    add("rec8", tot)

  # --- residual u16 table entire free run (even len, mostly non-zero) ---
  block:
    var tot = 0
    for r in freeRuns(claimMask):
      if r.n < 16 or r.n mod 2 != 0: continue
      var nz = 0
      for j in 0 ..< r.n:
        if g[r.o+j] != 0: nz += 1
      if nz * 4 < r.n * 3: continue
      # many u16 tables have high byte often small
      var lohi = 0
      let words = r.n div 2
      for i in 0 ..< words:
        if g[r.o + i*2 + 1] < 0x40: lohi += 1
      if lohi * 2 >= words:
        if isFree(claimMask, r.o, r.n):
          mark(claimMask, r.o, r.n)
          tot += r.n
    add("u16table", tot)

  # --- residual "dense binary" with fixed stride auto-detect via GCD of peaks ---
  # try: majority of free run is non-zero, claim whole run as ekTable if ≥48 and
  # entropy not too high? actually that's too weak for honest RE.
  # Instead: runs that are almost fully claimed except free, if free is mid-table
  # of known sizes already drained.

  echo "=== dense residual scouts ==="
  var keys = newSeq[string]()
  for k in totals.keys: keys.add k
  keys.sort()
  var sum = 0
  for k in keys:
    echo &"  {k}: {totals[k]} B"
    sum += totals[k]
  echo &"SUM: {sum} B (~{sum.float*100.0/3145728.0:.2f}%)"
  var rem = 0
  for r in freeRuns(claimMask): rem += r.n
  echo &"left: {rem} B"

  # hex dump of a few still-large after
  var runs = freeRuns(claimMask)
  runs.sort(proc(a,b: auto): int = cmp(b.n, a.n))
  echo "\nremaining top 15:"
  for i in 0 ..< min(15, runs.len):
    let r = runs[i]
    var hx = ""
    for j in 0 ..< min(24, r.n):
      hx.add &"{g[r.o+j]:02X} "
    echo &"  0x{r.o:06X}+{r.n} | {hx}"

main()
