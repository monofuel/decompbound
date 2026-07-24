## Document top residual free gaps with context for handoff.
import
  std/[strformat, algorithm, tables, strutils],
  ../decompbound/[rom_chunks, baserom_extract, action_script, text_decode]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len:
      c[o + j] = true

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
  ## Print top residual free with neighbors and AS/SS peeks.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var extractName = newSeq[string](g.len)
  for s in KnownBaseromExtracts:
    for j in 0 ..< s.length:
      if s.offset + j < extractName.len:
        extractName[s.offset + j] = s.name

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

  echo "=== TOP 40 residual free (context) ==="
  for i in 0 ..< min(40, runs.len):
    let r = runs[i]
    var hx = ""
    for j in 0 ..< min(24, r.n):
      hx.add &"{g[r.o + j]:02X} "
    let L = if r.o > 0: kindAt[r.o - 1] else: "edge"
    let R = if r.o + r.n < g.len: kindAt[r.o + r.n] else: "edge"
    let Ln =
      if r.o > 0 and extractName[r.o - 1].len > 0: extractName[r.o - 1]
      else: L
    let Rn =
      if r.o + r.n < g.len and extractName[r.o + r.n].len > 0:
        extractName[r.o + r.n]
      else: R
    let aw = walkActionScript(g, r.o, r.o + r.n)
    let sw = walkScriptStream(g, r.o, r.o + r.n)
    echo &"0x{r.o:06X}+{r.n:2} L={Ln} R={Rn}"
    echo &"  hex={hx}"
    echo &"  as: ended={aw.ended} len={aw.length} ops={aw.ops} sig={aw.sig}" &
      &"  ss: ended={sw.ended} len={sw.length} g={sw.glyphs} bad={sw.badGlyphs}"

  type Cluster = object
    o, n, runs: int
  var clusters: seq[Cluster] = @[]
  var cur = Cluster(o: -1, n: 0, runs: 0)
  let ordered = runs.sorted(proc(a, b: auto): int = cmp(a.o, b.o))
  for r in ordered:
    if cur.o < 0:
      cur = Cluster(o: r.o, n: r.n, runs: 1)
    elif r.o <= cur.o + cur.n + 64:
      let endPos = max(cur.o + cur.n, r.o + r.n)
      cur.n = endPos - cur.o
      cur.runs += 1
    else:
      clusters.add cur
      cur = Cluster(o: r.o, n: r.n, runs: 1)
  if cur.o >= 0:
    clusters.add cur
  clusters.sort(proc(a, b: auto): int = cmp(b.n, a.n))
  echo "\n=== TOP 20 free clusters (merge gap≤64) ==="
  for i in 0 ..< min(20, clusters.len):
    let c = clusters[i]
    echo &"  0x{c.o:06X}+{c.n} runs={c.runs} bank=0x{c.o shr 16:02X}"

  echo "\n=== bank 0x18 free sample ==="
  var b18 = 0
  var shown = 0
  for r in freeRuns(claimed):
    if r.o shr 16 != 0x18:
      continue
    b18 += r.n
    if shown < 15 and r.n >= 4:
      var hx = ""
      for j in 0 ..< min(16, r.n):
        hx.add &"{g[r.o + j]:02X} "
      echo &"  0x{r.o:06X}+{r.n} {hx}"
      shown += 1
  echo &"bank18 total free {b18}"

  echo "\n=== single-byte zero-width AS terminals ==="
  var termOps: CountTable[int]
  for r in freeRuns(claimed):
    if r.n != 1:
      continue
    let op = int(g[r.o])
    if ActionScriptOperandWidths[op] == 0 and ActionScriptTerminal[op]:
      termOps.inc(op)
  for k in termOps.keys:
    echo &"  op 0x{k:02X}: {termOps[k]}"

  echo "\n=== incomplete FAR free heads ==="
  var ifn = 0
  for r in freeRuns(claimed):
    if g[r.o] notin [0x42u8, 0x4Cu8]:
      continue
    if r.n >= 4:
      let bank = int(g[r.o + 3])
      let lo = g[r.o + 1].int or (g[r.o + 2].int shl 8)
      var after = true
      if r.o + 4 < claimed.len:
        after = claimed[r.o + 4]
      echo &"  fullish 0x{r.o:06X}+{r.n} bank=0x{bank:02X} lo=0x{lo:04X} afterClaimed={after}"
    else:
      if r.o + 3 < g.len:
        let bank = int(g[r.o + 3])
        var hx = ""
        for j in 0 ..< min(8, r.n + 4):
          if r.o + j < g.len:
            let mark = if claimed[r.o + j]: "*" else: " "
            hx.add &"{g[r.o + j]:02X}{mark} "
        echo &"  short 0x{r.o:06X}+{r.n} peek bank=0x{bank:02X} ({hx})"
        ifn += 1
        if ifn > 25:
          break

  # Mid-run far3 that starts free with non-far then far chain
  echo "\n=== mid-run far3 potential (start offset within free) ==="
  var midFar = 0
  var midN = 0
  for r in freeRuns(claimed):
    if r.n < 6:
      continue
    var i = 1  # not at start (already claimed by wave100b from start)
    while i + 3 <= r.n:
      let lo = g[r.o + i].int or (g[r.o + i + 1].int shl 8)
      let b = g[r.o + i + 2]
      if b >= 0xC0 and b <= 0xEF and lo != 0:
        var k = i
        var cnt = 0
        while k + 3 <= r.n:
          let lo2 = g[r.o + k].int or (g[r.o + k + 1].int shl 8)
          let b2 = g[r.o + k + 2]
          if not (b2 >= 0xC0 and b2 <= 0xEF and lo2 != 0):
            break
          cnt += 1
          k += 3
        if cnt >= 2:
          midFar += cnt * 3
          midN += 1
          if midN <= 15:
            echo &"  mid far3 0x{r.o + i:06X}+{cnt * 3} (in free 0x{r.o:06X}+{r.n})"
          i = k
        else:
          i += 1
      else:
        i += 1
  echo &"mid far3≥2 total {midFar} B / {midN}"

main()
