## RE top residual islands: opcode histograms, stride, nearby loaders.
import
  std/[algorithm, strformat, strutils, tables, os],
  ../decompbound/[rom_chunks, baserom_extract, memmap, common]

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

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
  var runs = freeRuns(claimed)
  runs.sort(proc(a,b: auto): int = cmp(b.n, a.n))

  # For top 8 runs: byte histogram top, stride score, pair patterns
  for i in 0 ..< min(8, runs.len):
    let r = runs[i]
    echo &"\n======== 0x{r.o:06X}+{r.n} (SNES ${r.o + 0xC00000:06X}) ========"
    var hist: array[256, int]
    for j in 0 ..< r.n: hist[g[r.o+j]] += 1
    var tops: seq[tuple[b, c: int]] = @[]
    for b in 0..255:
      if hist[b] > 0: tops.add (b, hist[b])
    tops.sort(proc(a,b: auto): int = cmp(b.c, a.c))
    var th = ""
    for k in 0 ..< min(12, tops.len):
      th.add &"{tops[k].b:02X}:{tops[k].c} "
    echo "  top bytes: ", th

    # stride scores: for each stride 2..16, measure how often byte@offset0 is "op-like"
    for stride in [2, 3, 4, 5, 6, 8, 10, 12]:
      if r.n < stride * 4: continue
      let nRec = r.n div stride
      var op0: CountTable[int]
      for i in 0 ..< nRec:
        op0.inc(g[r.o + i*stride].int)
      # entropy-ish: top mode frequency
      var mode = 0
      for v in op0.values:
        if v > mode: mode = v
      let modeRatio = mode.float / nRec.float
      # field stability: for each field, unique count
      var fieldStable = 0
      for f in 0 ..< stride:
        var u: HashSet[int]
        for i in 0 ..< nRec:
          u.incl g[r.o + i*stride + f].int
        if u.len <= max(4, nRec div 4): fieldStable += 1
      if modeRatio >= 0.15 or fieldStable >= stride div 2:
        echo &"  stride {stride}: nRec={nRec} modeRatio={modeRatio:.2f} stableFields={fieldStable}/{stride}"

    # dump first 64 bytes as groups of 2 and 4
    var hx2 = ""
    for j in 0 ..< min(48, r.n):
      if j mod 2 == 0 and j > 0: hx2.add " "
      if j mod 16 == 0 and j > 0: hx2.add "\n           "
      hx2.add &"{g[r.o+j]:02X}"
    echo "  hex2:\n           ", hx2

  # Scan gold for AbsoluteLong AF/BF into top residual windows (C0-EF all banks)
  echo "\n======== AbsoluteLong AF/BF into top residual (all banks) ========"
  var tops = runs[0 ..< min(15, runs.len)]
  # Build set of residual ranges
  for ti, r in tops:
    let snesBase = r.o + 0xC00000  # wrong for banks - need proper
    discard snesBase
  # Correct: file offset to SNES via fileToSnes
  var hits: seq[tuple[opFo, tgtFo, bank: int]] = @[]
  # scan only low banks C0-C4 + a few gen for speed: banks 0x00-0x0F file
  for fo in 0 ..< min(g.len - 4, 0x100000):  # first 1MB code-ish
    let op = g[fo]
    if op != 0xAF and op != 0xBF: continue  # LDA.L / LDA.L,X
    let lo = g[fo+1].int
    let hi = g[fo+2].int
    let bk = g[fo+3].int
    if bk < 0xC0 or bk > 0xEF: continue
    let snes = uint32(lo or (hi shl 8) or (bk shl 16))
    let tgt = snesToFile(snes)
    if tgt < 0: continue
    for r in tops:
      if tgt >= r.o and tgt < r.o + r.n:
        hits.add (fo, tgt, bk)
        break
      # also near base (within 256 of start)
      if tgt >= r.o - 64 and tgt < r.o + 16:
        hits.add (fo, tgt, bk)
        break
  echo &"hits into top residual windows: {hits.len}"
  for h in hits[0 ..< min(40, hits.len)]:
    echo &"  op@0x{h.opFo:06X} -> 0x{h.tgtFo:06X} bank=${h.bank:02X}"

  # Also check if any pack table points near residual
  const PackTable = 0x04F947
  echo "\n======== pack table near residual ========"
  for i in 0 ..< 170:
    let b = PackTable + i * 3
    let bank = g[b].int
    let a = g[b+1].int or (g[b+2].int shl 8)
    if bank < 0xC0 or bank > 0xEF: continue
    let fo = snesToFile(uint32(a or (bank shl 16)))
    for r in tops:
      if fo >= r.o - 32 and fo < r.o + r.n:
        echo &"  pack[{i}] @0x{fo:06X} near residual 0x{r.o:06X}+{r.n}"

main()
