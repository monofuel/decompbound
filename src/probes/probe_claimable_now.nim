## What is honestly claimable right now from residual free.
import
  std/[strformat, algorithm, tables],
  ../decompbound/[rom_chunks, baserom_extract, text_decode, action_script]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  result = @[]
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

proc main() =
  ## Enumerate residual free claims that pass honest structure gates.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var zB = 0
  var zN = 0
  for r in freeRuns(claimed):
    var ok = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        ok = false
        break
    if ok:
      zB += r.n
      zN += 1
      echo &"  ZERO 0x{r.o:06X}+{r.n}"
  echo &"ZERO total {zB}/{zN}"

  var cB = 0
  var cN = 0
  var byV: CountTable[uint8]
  for r in freeRuns(claimed):
    if r.n < 2:
      continue
    let v = g[r.o]
    var ok = true
    for j in 1 ..< r.n:
      if g[r.o + j] != v:
        ok = false
        break
    if ok and v != 0:
      cB += r.n
      cN += 1
      byV.inc(v, r.n)
      if cN <= 40:
        echo &"  CONST 0x{r.o:06X}+{r.n} =0x{v:02X}"
  echo &"CONST>=2 total {cB}/{cN}"
  var vk: seq[uint8] = @[]
  for k in byV.keys:
    vk.add k
  vk.sort()
  for k in vk:
    echo &"  val 0x{k:02X}: {byV[k]}"

  var aB = 0
  var aN = 0
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen:
      continue
    if consumeActionScriptRun(g, r.o, r.n) == r.n:
      aB += r.n
      aN += 1
      echo &"  AS 0x{r.o:06X}+{r.n}"
  echo &"AS full {aB}/{aN}"

  var sB = 0
  var sN = 0
  for r in freeRuns(claimed):
    if r.n < 2:
      continue
    let w = walkScriptStream(g, r.o, r.o + r.n)
    if isGoodScriptStream(w) and w.length <= r.n:
      sB += w.length
      sN += 1
      if sN <= 20:
        echo &"  SS 0x{r.o:06X}+{w.length} (run {r.n})"
  echo &"SS good {sB}/{sN}"

  var s2 = 0
  var s2n = 0
  for r in freeRuns(claimed):
    if r.n < 2:
      continue
    let w = walkScriptStream(g, r.o, r.o + r.n)
    if w.ended and w.badGlyphs == 0 and w.length >= 2 and w.length <= r.n:
      s2 += w.length
      s2n += 1
  echo &"SS ended any {s2}/{s2n}"

  var farB = 0
  var farN = 0
  for r in freeRuns(claimed):
    if r.n < 4:
      continue
    if g[r.o] notin [0x42u8, 0x4Cu8]:
      continue
    let bank = int(g[r.o + 3])
    if bank < 0xC0 or bank > 0xFF:
      continue
    let w = walkActionScript(g, r.o, r.o + r.n)
    if w.ended and w.length >= 4:
      farB += w.length
      farN += 1
      echo &"  FAR-walk 0x{r.o:06X}+{w.length} ops={w.ops} sig={w.sig}"
  echo &"FAR-walks {farB}/{farN}"

  # term remaining on a working mask
  var m = claimed
  var termB = 0
  var termN = 0
  for termByte in 0xF0 .. 0xFF:
    var o = 0
    while o < g.len:
      if m[o]:
        o += 1
        continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not m[pos]:
        var k = pos
        while k < g.len and not m[k] and g[k] != termByte.uint8 and
            (k - pos) < 48:
          k += 1
        if k >= g.len or m[k] or g[k] != termByte.uint8:
          break
        let rl = k - pos + 1
        if rl < 2 or rl > 48:
          break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var tc = 0
        for j in 0 ..< n:
          if g[start + j] == termByte.uint8:
            tc += 1
        if tc == recs:
          termB += n
          termN += 1
          mark(m, start, n)
          o = pos
          continue
      if recs == 1 and n >= 4 and n <= 32:
        var tc = 0
        for j in 0 ..< n:
          if g[start + j] == termByte.uint8:
            tc += 1
        if tc == 1 and g[start + n - 1] == termByte.uint8:
          termB += n
          termN += 1
          mark(m, start, n)
          o = pos
          continue
      o += 1
  echo &"term F0-FF remaining {termB}/{termN}"

  var u8 = 0
  var u8n = 0
  for r in freeRuns(claimed):
    if r.n < 8 or r.n mod 2 != 0:
      continue
    let nRec = r.n div 2
    if nRec < 4:
      continue
    var ok = 0
    var nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o + i * 2]
      let b = g[r.o + i * 2 + 1]
      if a <= 0x50 or b <= 0x50:
        ok += 1
      if a != 0 or b != 0:
        nz += 1
    if ok * 100 < nRec * 55:
      continue
    if nz * 2 < nRec:
      continue
    u8 += r.n
    u8n += 1
    echo &"  u8pair 0x{r.o:06X}+{r.n}"
  echo &"u8pair {u8}/{u8n}"

  var f3 = 0
  var f3n = 0
  for r in freeRuns(claimed):
    if r.n < 3:
      continue
    var i = 0
    while i + 3 <= r.n:
      let bank = int(g[r.o + i + 2])
      if bank >= 0xC0 and bank <= 0xFF:
        var k = i
        while k + 3 <= r.n:
          let b2 = int(g[r.o + k + 2])
          if b2 < 0xC0 or b2 > 0xFF:
            break
          k += 3
        let n = k - i
        if n >= 3:
          f3 += n
          f3n += 1
          if f3n <= 15:
            echo &"  far3 0x{r.o + i:06X}+{n}"
          i = k
        else:
          i += 1
      else:
        i += 1
  echo &"far3 packed {f3}/{f3n}"

  var pr = 0
  var prn = 0
  for r in freeRuns(claimed):
    if r.n < 6:
      continue
    var printable = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if (b >= 0x20 and b <= 0x7E) or b == 0:
        printable += 1
    if printable * 100 >= r.n * 70:
      pr += r.n
      prn += 1
  echo &"print70 {pr}/{prn}"

  # size hist again
  var hist: array[6, int]
  for r in freeRuns(claimed):
    if r.n == 1: hist[0] += r.n
    elif r.n == 2: hist[1] += r.n
    elif r.n <= 4: hist[2] += r.n
    elif r.n <= 8: hist[3] += r.n
    elif r.n <= 16: hist[4] += r.n
    else: hist[5] += r.n
  echo &"hist B: 1={hist[0]} 2={hist[1]} 3-4={hist[2]} 5-8={hist[3]} 9-16={hist[4]} 17+={hist[5]}"

main()
