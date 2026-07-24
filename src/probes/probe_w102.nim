## Residual wave102 scout: every known honest gate leftover + top clusters.
import
  std/[algorithm, strformat, strutils, tables],
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

proc isFar3(g: seq[uint8]; o: int): bool =
  let lo = g[o].int or (g[o + 1].int shl 8)
  let b = g[o + 2]
  result = b >= 0xC0 and b <= 0xEF and lo != 0

proc main() =
  ## Report leftover residual under prior-wave honest gates.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)

  var totalFree = 0
  for r in freeRuns(claimed): totalFree += r.n
  echo &"free={totalFree} runs={freeRuns(claimed).len}"

  var m = claimed
  var zB, asB, termB, u8B, constB, farB, bitB = 0
  var zN, asN, termN, u8N, constN, farN, bitN = 0

  for r in freeRuns(m):
    var allZ = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0: allZ = false; break
    if allZ:
      zB += r.n; zN += 1; mark(m, r.o, r.n)

  for r in freeRuns(m):
    if r.n < ActionScriptMinLen: continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      asB += r.n; asN += 1; mark(m, r.o, r.n)
      continue
    let w = walkActionScript(g, r.o, r.o + r.n)
    if isGoodActionScriptWalk(w) and w.length >= ActionScriptMinLen and
        w.length <= r.n and isFree(m, r.o, w.length):
      if isGoodActionScriptSpan(g, r.o, w.length):
        asB += w.length; asN += 1; mark(m, r.o, w.length)

  for termByte in 0xF0 .. 0xFF:
    var o = 0
    while o < g.len:
      if m[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not m[pos]:
        var k = pos
        while k < g.len and not m[k] and g[k] != termByte.uint8 and (k - pos) < 48:
          k += 1
        if k >= g.len or m[k] or g[k] != termByte.uint8: break
        let rl = k - pos + 1
        if rl < 2 or rl > 48: break
        recs += 1; pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var tc = 0
        for j in 0 ..< n:
          if g[start + j] == termByte.uint8: tc += 1
        if tc == recs and isFree(m, start, n):
          termB += n; termN += 1; mark(m, start, n); o = pos; continue
      if recs == 1 and n >= 4 and n <= 32:
        var tc = 0
        for j in 0 ..< n:
          if g[start + j] == termByte.uint8: tc += 1
        if tc == 1 and g[start + n - 1] == termByte.uint8 and isFree(m, start, n):
          termB += n; termN += 1; mark(m, start, n); o = pos; continue
      o += 1

  for r in freeRuns(m):
    if r.n < 8 or r.n mod 2 != 0: continue
    let nRec = r.n div 2
    if nRec < 4: continue
    var ok, nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o + i * 2]; let b = g[r.o + i * 2 + 1]
      if a <= 0x50 or b <= 0x50: ok += 1
      if a != 0 or b != 0: nz += 1
    if ok * 100 < nRec * 55: continue
    if nz * 2 < nRec: continue
    u8B += r.n; u8N += 1; mark(m, r.o, r.n)

  for r in freeRuns(m):
    if r.n < 2: continue
    let v = g[r.o]
    if v == 0: continue
    var same = true
    for j in 1 ..< r.n:
      if g[r.o + j] != v: same = false; break
    if same:
      constB += r.n; constN += 1; mark(m, r.o, r.n)

  for r in freeRuns(m):
    if r.n < 3: continue
    var bestN = 0
    var bestA = -1
    for align in 0 .. 2:
      let rem = r.n - align
      if rem < 3 or rem mod 3 != 0: continue
      var ok = true
      for i in 0 ..< (rem div 3):
        if not isFar3(g, r.o + align + i * 3): ok = false; break
      if ok and rem > bestN: bestN = rem; bestA = align
    if bestA >= 0:
      farB += bestN; farN += 1; mark(m, r.o + bestA, bestN)

  for r in freeRuns(m):
    if r.n < 4: continue
    var ok = true; var nz = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if b notin [0x00u8, 0x01u8, 0x80u8]: ok = false; break
      if b != 0: nz += 1
    if ok and nz >= 1:
      bitB += r.n; bitN += 1; mark(m, r.o, r.n)

  echo &"w101 leftover: zero={zB}/{zN} as={asB}/{asN} term={termB}/{termN} u8={u8B}/{u8N} const={constB}/{constN} far3={farB}/{farN} bit={bitB}/{bitN}"

  # print70 wave100b: >=6, 70% printable or EB-glyph range 0x50-0x90
  var prB, prN = 0
  for r in freeRuns(m):
    if r.n < 6: continue
    var pr = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if (b >= 0x20 and b <= 0x7E) or (b >= 0x50 and b <= 0x90): pr += 1
    if pr * 100 >= r.n * 70:
      prB += r.n; prN += 1
  echo &"print70 (w100b gate) remaining: {prB}/{prN}"

  # plane25
  var plB, plN = 0
  for r in freeRuns(m):
    if r.n < 8 or r.n mod 2 != 0: continue
    var eq = 0
    let pairs = r.n div 2
    for i in 0 ..< pairs:
      if g[r.o + i * 2] == g[r.o + i * 2 + 1]: eq += 1
    if eq * 100 >= pairs * 25:
      plB += r.n; plN += 1
  echo &"plane25 remaining: {plB}/{plN}"

  # smooth1 wave100: consecutive |diff|<=1 ratio
  var smB, smN = 0
  for r in freeRuns(m):
    if r.n < 12: continue
    var smooth = 0
    for j in 1 ..< r.n:
      let d = abs(int(g[r.o + j]) - int(g[r.o + j - 1]))
      if d <= 1: smooth += 1
    if smooth * 100 >= (r.n - 1) * 45:
      smB += r.n; smN += 1
  echo &"smooth1 ≥45% remaining: {smB}/{smN}"

  # SS good
  var ssB, ssN = 0
  for r in freeRuns(m):
    if r.n < ScriptStreamMinLen: continue
    let w = walkScriptStream(g, r.o, r.o + r.n)
    if isGoodScriptStream(w) and w.length <= r.n and isFree(m, r.o, w.length):
      ssB += w.length; ssN += 1
  echo &"SS good remaining: {ssB}/{ssN}"

  # countN mid-scan (wave100 style): u8 count + count*stride exact free subspan
  var cnB, cnN = 0
  for r in freeRuns(m):
    if r.n < 5: continue
    var i = 0
    while i < r.n:
      let cnt = int(g[r.o + i])
      if cnt < 2 or cnt > 40:
        i += 1; continue
      var best = 0
      for stride in [1, 2, 3, 4, 5, 6, 8, 10, 12, 16]:
        let need = 1 + cnt * stride
        if need < 5 or i + need > r.n: continue
        var nz = 0
        for j in 1 ..< need:
          if g[r.o + i + j] != 0: nz += 1
        if nz * 100 < need * 30: continue
        if need > best: best = need
      if best >= 5:
        cnB += best; cnN += 1
        i += best
      else:
        i += 1
  echo &"countN mid-scan remaining: {cnB}/{cnN}"

  # fix3/fix4 wave100b-like ≥40%
  var f3B, f3N, f4B, f4N = 0
  for r in freeRuns(m):
    if r.n < 9: continue
    for align in 0 .. 2:
      let rem = r.n - align
      if rem < 9 or rem mod 3 != 0: continue
      let nRec = rem div 3
      if nRec < 3: continue
      var banks, types, nz = 0
      for i in 0 ..< nRec:
        let b0 = g[r.o + align + i * 3]
        let b1 = g[r.o + align + i * 3 + 1]
        let b2 = g[r.o + align + i * 3 + 2]
        if b2 >= 0xC0 and b2 <= 0xFF: banks += 1
        if b0 <= 0x20: types += 1
        if b0 != 0 or b1 != 0 or b2 != 0: nz += 1
      if nz < nRec: continue
      if banks * 5 < nRec * 2 and types * 5 < nRec * 2: continue
      f3B += rem; f3N += 1
      break
  for r in freeRuns(m):
    if r.n < 12: continue
    for align in 0 .. 3:
      let rem = r.n - align
      if rem < 12 or rem mod 4 != 0: continue
      let nRec = rem div 4
      if nRec < 3: continue
      var zhi, banks, nz = 0
      for i in 0 ..< nRec:
        let base = r.o + align + i * 4
        if g[base + 3] == 0: zhi += 1
        if g[base + 3] >= 0xC0: banks += 1
        for j in 0 .. 3:
          if g[base + j] != 0: nz += 1
      if nz < nRec * 2: continue
      if zhi * 5 < nRec * 2 and banks * 5 < nRec * 2: continue
      f4B += rem; f4N += 1
      break
  echo &"fix3≥40% rem: {f3B}/{f3N}  fix4≥40% rem: {f4B}/{f4N}"

  # far3 head-only ≥1 (w100b style, not pure rem)
  var f3hB, f3hN = 0
  for r in freeRuns(m):
    if r.n < 3: continue
    var i = 0
    var cnt = 0
    while i + 3 <= r.n:
      if isFar3(g, r.o + i):
        cnt += 1; i += 3
      else: break
    if cnt >= 1:
      f3hB += cnt * 3; f3hN += 1
  echo &"far3 head-chain ≥1 remaining: {f3hB}/{f3hN}"

  # gfx_lz free starts
  var gzB, gzN = 0
  for r in freeRuns(m):
    if r.n < 4: continue
    let slice = g[r.o ..< r.o + r.n]
    let (data, consumed, clean) = decodeWithConsumed(slice)
    if clean and consumed >= 4 and consumed <= r.n and data.len >= 8:
      gzB += consumed; gzN += 1
      if gzN <= 10:
        echo &"  gfx 0x{r.o:06X} consumed={consumed} dec={data.len}"
  echo &"gfx_lz free starts: {gzB}/{gzN}"

  # expanded alphabets
  let alphaNames = ["00/01/80/90", "00/01/03", "00/01/03/80/90", "00/80/90", "00/01/02/03"]
  let alphaSets = [
    @[0x00u8, 0x01, 0x80, 0x90],
    @[0x00u8, 0x01, 0x03],
    @[0x00u8, 0x01, 0x03, 0x80, 0x90],
    @[0x00u8, 0x80, 0x90],
    @[0x00u8, 0x01, 0x02, 0x03],
  ]
  for ai in 0 ..< alphaNames.len:
    let name = alphaNames[ai]
    let alph = alphaSets[ai]
    var aB, aN = 0
    for r in freeRuns(m):
      if r.n < 4: continue
      var ok = true
      var nz = 0
      var seen: set[uint8]
      for j in 0 ..< r.n:
        let b = g[r.o + j]
        if b notin alph: ok = false; break
        seen.incl b
        if b != 0: nz += 1
      if ok and nz >= 1 and seen.len >= 2:
        aB += r.n; aN += 1
    echo &"alpha {name} ≥4 multi: {aB}/{aN}"

  # AS walk any-ended with ops>=2 sig>=1
  var as2B, as2N = 0
  for r in freeRuns(m):
    if r.n < 4: continue
    let w = walkActionScript(g, r.o, r.o + r.n)
    if w.ended and w.ops >= 2 and w.sig >= 1 and w.length >= 4 and w.length <= r.n:
      as2B += w.length; as2N += 1
      if as2N <= 12:
        echo &"  AS ops≥2 0x{r.o:06X}+{w.length} ops={w.ops} sig={w.sig}"
  echo &"AS ended ops≥2 sig≥1: {as2B}/{as2N}"

  # top 30 free
  var runs = freeRuns(m)
  runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))
  var rem = 0
  for r in freeRuns(m): rem += r.n
  echo &"\nafter w101 leftover mark free={rem}"
  echo "TOP 30:"
  for i in 0 ..< min(30, runs.len):
    let r = runs[i]
    var hx = ""
    for j in 0 ..< min(20, r.n): hx.add &"{g[r.o + j]:02X} "
    echo &"  0x{r.o:06X}+{r.n:2} {hx}"

  # CF cluster detail
  echo "\n=== CF 0x0FB207 cluster free ==="
  var cfB = 0
  for r in freeRuns(claimed):
    if r.o >= 0x0FB207 and r.o < 0x0FB207 + 1100:
      cfB += r.n
      var hx = ""
      for j in 0 ..< min(20, r.n): hx.add &"{g[r.o + j]:02X} "
      echo &"  0x{r.o:06X}+{r.n} {hx}"
  echo &"total {cfB}"

  echo "\n=== bank18 free ≥4 alph≤5 ==="
  var b18s = 0
  for r in freeRuns(claimed):
    if r.o shr 16 != 0x18 or r.n < 4: continue
    var seen: set[uint8]
    for j in 0 ..< r.n: seen.incl g[r.o + j]
    if seen.len <= 5:
      b18s += r.n
      var hx = ""
      for j in 0 ..< min(14, r.n): hx.add &"{g[r.o + j]:02X} "
      var sk: seq[string] = @[]
      for v in seen: sk.add &"{v:02X}"
      echo &"  0x{r.o:06X}+{r.n} alph={{{sk.join(\",\")}}} {hx}"
  echo &"bank18 small-alph bytes {b18s}"

  # loader: scan AbsoluteLong AF/BF in gold banks C0-C4 into free residual
  echo "\n=== C0-C4 LDA.L AF/BF into free residual (sample) ==="
  var hits = 0
  var hitBytes = 0
  for bank in 0 .. 4:
    let base = bank * 0x10000
    var pc = base
    let endb = base + 0x10000
    while pc + 4 <= endb and pc + 4 <= g.len:
      let op = g[pc]
      if op == 0xAF or op == 0xBF:  # LDA.L / LDA.L,X
        let lo = g[pc + 1].int or (g[pc + 2].int shl 8)
        let b = g[pc + 3].int
        if b >= 0xC0 and b <= 0xFF:
          let fileOff = ((b - 0xC0) shl 16) or lo
          if fileOff < claimed.len and not claimed[fileOff]:
            # free run containing this
            var s = fileOff
            while s > 0 and not claimed[s - 1]: s -= 1
            var e = fileOff
            while e + 1 < claimed.len and not claimed[e + 1]: e += 1
            let n = e - s + 1
            hits += 1
            hitBytes += n
            if hits <= 25:
              echo &"  LDA.L @0x{pc:06X} -> 0x{fileOff:06X} freeRun 0x{s:06X}+{n}"
        pc += 4
      else:
        pc += 1
  echo &"hits into free {hits} (run-bytes counted with dups {hitBytes})"

main()
