## Final residual scout for 99.45% → 100% honest push.
import
  std/[algorithm, strformat, strutils, tables, sets],
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
  ## Scout residual free for honest final claims.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var runs = freeRuns(claimed)
  runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))
  var totalFree = 0
  for r in runs:
    totalFree += r.n
  let maxRun = if runs.len > 0: runs[0].n else: 0
  echo &"total free={totalFree} runs={runs.len} max={maxRun}"

  var pureZ = 0
  var pureZN = 0
  var pureConst = 0
  var pureConstN = 0
  var pureConstBy: CountTable[uint8]
  for r in freeRuns(claimed):
    var allZ = true
    var allC = true
    let v = g[r.o]
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        allZ = false
      if g[r.o + j] != v:
        allC = false
    if allZ:
      pureZ += r.n
      pureZN += 1
    elif allC and r.n >= 1:
      pureConst += r.n
      pureConstN += 1
      pureConstBy.inc(v, r.n)

  echo &"pure-zero free runs: {pureZ} B in {pureZN} spans"
  echo &"pure-const free runs (non-zero): {pureConst} B in {pureConstN} spans"
  var keys: seq[uint8] = @[]
  for k in pureConstBy.keys:
    keys.add k
  keys.sort()
  for k in keys:
    echo &"  const 0x{k:02X}: {pureConstBy[k]} B"

  var asB = 0
  var asN = 0
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen:
      continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      asB += r.n
      asN += 1
  echo &"good AS residual: {asB} B in {asN} spans (minLen={ActionScriptMinLen})"

  var asWalkB = 0
  var asWalkN = 0
  for r in freeRuns(claimed):
    if r.n < 2:
      continue
    let w = walkActionScript(g, r.o, r.o + r.n)
    if w.ended and w.length >= 2 and w.length <= r.n and true:
      asWalkB += w.length
      asWalkN += 1
  echo &"AS walk any-ended residual: {asWalkB} B in {asWalkN}"

  var ssB = 0
  var ssN = 0
  for r in freeRuns(claimed):
    if r.n < 2:
      continue
    let w = walkScriptStream(g, r.o, r.o + r.n)
    if w.ended and w.length >= 2 and w.length <= r.n and w.badGlyphs == 0 and
        w.glyphs >= 1:
      ssB += w.length
      ssN += 1
  echo &"SS walk residual (glyphs>=1 ended): {ssB} B in {ssN}"

  var sb: CountTable[uint8]
  var sbN = 0
  for r in freeRuns(claimed):
    if r.n == 1:
      sb.inc(g[r.o])
      sbN += 1
  echo &"single-byte free: {sbN}"
  var sk: seq[uint8] = @[]
  for k in sb.keys:
    sk.add k
  sk.sort(proc(a, b: uint8): int = cmp(sb[b], sb[a]))
  for i in 0 ..< min(20, sk.len):
    echo &"  0x{sk[i]:02X}: {sb[sk[i]]}"

  var t2: CountTable[string]
  var t2n = 0
  for r in freeRuns(claimed):
    if r.n == 2:
      t2.inc(&"{g[r.o]:02X}{g[r.o+1]:02X}")
      t2n += 1
  echo &"2-byte free: {t2n}"
  var tk: seq[string] = @[]
  for k in t2.keys:
    tk.add k
  tk.sort(proc(a, b: string): int = cmp(t2[b], t2[a]))
  for i in 0 ..< min(15, tk.len):
    echo &"  {tk[i]}: {t2[tk[i]]}"

  var byBank: array[48, int]
  for r in freeRuns(claimed):
    let b = r.o shr 16
    if b < 48:
      byBank[b] += r.n
  echo "residual by file bank:"
  for b in 0 ..< 48:
    if byBank[b] > 0:
      echo &"  bank 0x{b:02X}: {byBank[b]}"

  var kindAt = newSeq[string](g.len)
  for c in allRomChunksMeta():
    let kn = case c.kind
      of ckImplementedCode: "code"
      of ckImplementedMeta: "meta"
      of ckUnclaimed: "free"
    for j in 0 ..< c.length:
      if c.offset + j < kindAt.len:
        kindAt[c.offset + j] = kn

  echo "\ntop 25 free + neighbors:"
  for i in 0 ..< min(25, runs.len):
    let r = runs[i]
    var hx = ""
    for j in 0 ..< min(20, r.n):
      hx.add &"{g[r.o+j]:02X} "
    let L = if r.o > 0: kindAt[r.o - 1] else: "edge"
    let R = if r.o + r.n < g.len: kindAt[r.o + r.n] else: "edge"
    echo &"  0x{r.o:06X}+{r.n:2} L={L:4} R={R:4} | {hx}"

  var codeSandwich = 0
  var codeSandwichN = 0
  for r in freeRuns(claimed):
    let L = if r.o > 0: kindAt[r.o - 1] else: ""
    let R = if r.o + r.n < g.len: kindAt[r.o + r.n] else: ""
    if L == "code" and R == "code":
      codeSandwich += r.n
      codeSandwichN += 1
  echo &"\ncode-sandwiched free: {codeSandwich} B in {codeSandwichN} runs"

  var extractAt = newSeq[string](g.len)
  for s in KnownBaseromExtracts:
    for j in 0 ..< s.length:
      if s.offset + j < extractAt.len:
        extractAt[s.offset + j] = $s.kind

  var byNeigh: CountTable[string]
  for r in freeRuns(claimed):
    let L =
      if r.o > 0:
        if extractAt[r.o - 1].len > 0: extractAt[r.o - 1]
        elif kindAt[r.o - 1] == "code": "code"
        else: kindAt[r.o - 1]
      else: "edge"
    let R =
      if r.o + r.n < g.len:
        if extractAt[r.o + r.n].len > 0: extractAt[r.o + r.n]
        elif kindAt[r.o + r.n] == "code": "code"
        else: kindAt[r.o + r.n]
      else: "edge"
    byNeigh.inc(&"{L}|{R}", r.n)
  echo "neighbor pairs (bytes):"
  var nk: seq[string] = @[]
  for k in byNeigh.keys:
    nk.add k
  nk.sort(proc(a, b: string): int = cmp(byNeigh[b], byNeigh[a]))
  for i in 0 ..< min(25, nk.len):
    echo &"  {nk[i]}: {byNeigh[nk[i]]}"

main()
