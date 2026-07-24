## Strict leftover: exact prior-wave gates only.
import
  std/[strformat, algorithm],
  ../decompbound/[rom_chunks, baserom_extract, action_script, gfx_lz]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len:
      c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len:
    return false
  for j in 0 ..< n:
    if claimed[o + j]:
      return false
  true

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

const
  MinFixRecs = 3
  MinCountN = 4
  MaxCount = 64
  MinPrint = 6
  PrintRatio = 70
  strides = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 17, 20, 24, 25, 27, 32, 41]

proc isFar3(g: seq[uint8]; o: int): bool =
  let lo = g[o].int or (g[o + 1].int shl 8)
  let b = g[o + 2]
  result = b >= 0xC0 and b <= 0xEF and lo != 0

proc main() =
  ## Report residual free that still passes exact prior-wave honest gates.
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
      echo &"ZERO 0x{r.o:06X}+{r.n}"
      zB += r.n
      zN += 1
  echo &"zero total {zB}/{zN}"

  var aB = 0
  var aN = 0
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen:
      continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      echo &"AS full 0x{r.o:06X}+{r.n}"
      aB += r.n
      aN += 1
      continue
    let w = walkActionScript(g, r.o, r.o + r.n)
    if isGoodActionScriptWalk(w) and w.length >= ActionScriptMinLen and
        w.length <= r.n and isFree(claimed, r.o, w.length) and
        isGoodActionScriptSpan(g, r.o, w.length):
      echo &"AS head 0x{r.o:06X}+{w.length}"
      aB += w.length
      aN += 1
  echo &"AS total {aB}/{aN}"

  var cB = 0
  var cN = 0
  for r in freeRuns(claimed):
    if r.n < 2:
      continue
    let v = g[r.o]
    if v == 0:
      continue
    var same = true
    for j in 1 ..< r.n:
      if g[r.o + j] != v:
        same = false
        break
    if same:
      echo &"CONST 0x{r.o:06X}+{r.n} ={v:02X}"
      cB += r.n
      cN += 1
  echo &"const total {cB}/{cN}"

  var f3B = 0
  var f3N = 0
  for r in freeRuns(claimed):
    if r.n < MinFixRecs * 3:
      continue
    for align in 0 .. 2:
      let nRec = (r.n - align) div 3
      if nRec < MinFixRecs:
        continue
      let n = nRec * 3
      let base = r.o + align
      if not isFree(claimed, base, n):
        continue
      var banks = 0
      var types = 0
      var nz = 0
      for i in 0 ..< nRec:
        let b = g[base + i * 3 + 2].int
        if b >= 0xC0 and b <= 0xEF:
          banks += 1
        if b <= 0x0F:
          types += 1
        if g[base + i * 3] != 0 or g[base + i * 3 + 1] != 0 or
            g[base + i * 3 + 2] != 0:
          nz += 1
      if nz * 2 < nRec:
        continue
      if banks * 5 < nRec * 2 and types * 5 < nRec * 2:
        continue
      echo &"fix3 0x{base:06X}+{n} recs={nRec} banks={banks} types={types}"
      f3B += n
      f3N += 1
      break
  echo &"fix3 total {f3B}/{f3N}"

  var f4B = 0
  var f4N = 0
  for r in freeRuns(claimed):
    if r.n < MinFixRecs * 4:
      continue
    for align in 0 .. 3:
      let nRec = (r.n - align) div 4
      if nRec < MinFixRecs:
        continue
      let n = nRec * 4
      let base = r.o + align
      if not isFree(claimed, base, n):
        continue
      var zhi = 0
      var banks = 0
      var nz = 0
      for i in 0 ..< nRec:
        let b = base + i * 4
        if g[b + 3] == 0:
          zhi += 1
        if g[b + 3] >= 0xC0:
          banks += 1
        for j in 0 .. 3:
          if g[b + j] != 0:
            nz += 1
      if nz < nRec * 2:
        continue
      if zhi * 5 < nRec * 2 and banks * 5 < nRec * 2:
        continue
      echo &"fix4 0x{base:06X}+{n} recs={nRec} zhi={zhi} banks={banks}"
      f4B += n
      f4N += 1
      break
  echo &"fix4 total {f4B}/{f4N}"

  var cnB = 0
  var cnN = 0
  for r in freeRuns(claimed):
    if r.n < MinCountN:
      continue
    var i = 0
    while i < r.n:
      if not isFree(claimed, r.o + i, 1):
        i += 1
        continue
      var best = 0
      for hdr in 1 .. 2:
        for stride in strides:
          if i + hdr > r.n:
            continue
          let cnt =
            if hdr == 1:
              g[r.o + i].int
            else:
              if i + 1 >= r.n:
                continue
              g[r.o + i].int or (g[r.o + i + 1].int shl 8)
          if cnt < 2 or cnt > MaxCount:
            continue
          let need = hdr + cnt * stride
          if need < MinCountN or i + need > r.n:
            continue
          let rem = r.n - i
          if need < rem * 3 div 10 and need != rem:
            continue
          var z = 0
          var nz = 0
          for j in hdr ..< need:
            if g[r.o + i + j] == 0:
              z += 1
            else:
              nz += 1
          if z * 2 > (need - hdr):
            continue
          if nz < 2:
            continue
          if need > best:
            best = need
      if best >= MinCountN and isFree(claimed, r.o + i, best):
        echo &"countN 0x{r.o + i:06X}+{best}"
        cnB += best
        cnN += 1
        i += best
      else:
        i += 1
  echo &"countN total {cnB}/{cnN}"

  var prB = 0
  var prN = 0
  for r in freeRuns(claimed):
    if r.n < MinPrint:
      continue
    var pr = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if (b >= 0x20 and b <= 0x7E) or (b >= 0x50 and b <= 0x90):
        pr += 1
    if pr * 100 < r.n * PrintRatio:
      continue
    echo &"print 0x{r.o:06X}+{r.n}"
    prB += r.n
    prN += 1
  echo &"print total {prB}/{prN}"

  var plB = 0
  var plN = 0
  for r in freeRuns(claimed):
    if r.n < 8 or r.n mod 2 != 0:
      continue
    var eq = 0
    let pairs = r.n div 2
    for i in 0 ..< pairs:
      if g[r.o + i * 2] == g[r.o + i * 2 + 1]:
        eq += 1
    if eq * 100 < pairs * 25:
      continue
    echo &"plane 0x{r.o:06X}+{r.n} eq={eq}/{pairs}"
    plB += r.n
    plN += 1
  echo &"plane total {plB}/{plN}"

  var gzB = 0
  var gzN = 0
  for r in freeRuns(claimed):
    if r.n < 4:
      continue
    let slice = g[r.o ..< min(r.o + r.n, g.len)]
    let (data, consumed, clean) = decodeWithConsumed(slice)
    if not clean:
      continue
    if consumed < 4 or consumed > r.n:
      continue
    if data.len < 16:
      continue
    var hx = ""
    for j in 0 ..< min(12, r.n):
      hx.add &"{g[r.o + j]:02X} "
    echo &"gfx 0x{r.o:06X} consumed={consumed}/{r.n} dec={data.len} hex={hx}"
    gzB += consumed
    gzN += 1
  echo &"gfx total {gzB}/{gzN}"

  var farB = 0
  var farN = 0
  for r in freeRuns(claimed):
    if r.n < 3:
      continue
    var bestN = 0
    var bestA = -1
    for align in 0 .. 2:
      let rem = r.n - align
      if rem < 3 or rem mod 3 != 0:
        continue
      var ok = true
      for i in 0 ..< (rem div 3):
        if not isFar3(g, r.o + align + i * 3):
          ok = false
          break
      if ok and rem > bestN:
        bestN = rem
        bestA = align
    if bestA >= 0:
      echo &"far3pure 0x{r.o + bestA:06X}+{bestN}"
      farB += bestN
      farN += 1
  echo &"far3pure total {farB}/{farN}"

  var bB = 0
  var bN = 0
  for r in freeRuns(claimed):
    if r.n < 4:
      continue
    var ok = true
    var nz = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if b notin [0x00u8, 0x01u8, 0x80u8]:
        ok = false
        break
      if b != 0:
        nz += 1
    if ok and nz >= 1:
      echo &"bit 0x{r.o:06X}+{r.n}"
      bB += r.n
      bN += 1
  echo &"bit total {bB}/{bN}"

  var byBank: array[48, int]
  for r in freeRuns(claimed):
    let b = r.o shr 16
    if b < 48:
      byBank[b] += r.n
  echo "banks:"
  for b in 0 ..< 48:
    if byBank[b] > 0:
      echo &"  0x{b:02X}: {byBank[b]}"

  var kindAt = newSeq[string](g.len)
  for c in allRomChunksMeta():
    let kn = case c.kind
      of ckImplementedCode: "code"
      of ckImplementedMeta: "meta"
      of ckUnclaimed: "free"
    for j in 0 ..< c.length:
      if c.offset + j < kindAt.len:
        kindAt[c.offset + j] = kn

  var runs = freeRuns(claimed)
  runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))
  echo "TOP30:"
  for i in 0 ..< min(30, runs.len):
    let r = runs[i]
    var hx = ""
    for j in 0 ..< min(18, r.n):
      hx.add &"{g[r.o + j]:02X} "
    let L = if r.o > 0: kindAt[r.o - 1] else: "edge"
    let R = if r.o + r.n < g.len: kindAt[r.o + r.n] else: "edge"
    echo &"  0x{r.o:06X}+{r.n:2} L={L} R={R} {hx}"

  var sandwich = 0
  var sn = 0
  for r in freeRuns(claimed):
    let L = if r.o > 0: kindAt[r.o - 1] else: ""
    let R = if r.o + r.n < g.len: kindAt[r.o + r.n] else: ""
    if L == "code" and R == "code":
      sandwich += r.n
      sn += 1
  echo &"code|code sandwich {sandwich}/{sn}"
  var total = 0
  for r in freeRuns(claimed):
    total += r.n
  let maxRun = if runs.len > 0: runs[0].n else: 0
  echo &"TOTAL FREE {total} runs={freeRuns(claimed).len} max={maxRun}"
  let exactPct = (3145728 - total).float * 100.0 / 3145728.0
  echo &"inventory coverage if free->claimed meta: {exactPct:.2f}% (free still unclaimed)"

main()
