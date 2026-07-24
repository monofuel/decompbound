## Wave103 scout: all-bank AbsoluteLong into residual free + known-family leftovers.
import
  std/[algorithm, strformat, strutils, tables, sets, sequtils],
  ../decompbound/[memmap, rom_chunks, baserom_extract, action_script, text_decode, gfx_lz]

const
  AbsLongOps = {0xAF'u8, 0xCF'u8, 0xEF'u8, 0xBF'u8, 0xDF'u8, 0xFF'u8, 0x8F'u8, 0x9F'u8}
  LoadOps = {0xAF'u8, 0xBF'u8}

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

proc isFar3(g: seq[uint8]; o: int): bool =
  let lo = g[o].int or (g[o + 1].int shl 8)
  let b = g[o + 2]
  result = b >= 0xC0 and b <= 0xEF and lo != 0

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset + c.length, isCode.len):
        isCode[i] = true

  let runs = freeRuns(claimed)
  var freeTot = 0
  var maxRun = 0
  for r in runs:
    freeTot += r.n
    if r.n > maxRun:
      maxRun = r.n
  echo &"Residual free: {freeTot} B in {runs.len} runs (max {maxRun})"

  var runAt = newSeq[int](g.len)
  for i in 0 ..< g.len:
    runAt[i] = -1
  for r in runs:
    for j in 0 ..< r.n:
      runAt[r.o + j] = r.o

  type Hit = object
    op: uint8
    at: int
    fo: int
    runO: int
    runN: int
    srcBank: int
    snes: uint32

  var byRun = initTable[int, seq[Hit]]()
  var loadHits = 0
  var allHits = 0
  var c0c4Load = 0
  var lowBankLoad = 0

  for bank in 0 .. 0x2F:
    let base = bank * 0x10000
    let limit = min(base + 0x10000 - 4, g.len)
    var p = base
    while p < limit:
      if not isCode[p]:
        p += 1
        continue
      let op = g[p]
      if op in AbsLongOps:
        let snes = g[p + 1].uint32 or (g[p + 2].uint32 shl 8) or
          (g[p + 3].uint32 shl 16)
        let fo = snesToFile(snes)
        if fo >= 0 and fo < g.len and not claimed[fo]:
          let ro = runAt[fo]
          if ro >= 0:
            var rl = 0
            for r in runs:
              if r.o == ro:
                rl = r.n
                break
            let h = Hit(op: op, at: p, fo: fo, runO: ro, runN: rl,
              srcBank: bank, snes: snes)
            if ro notin byRun:
              byRun[ro] = @[]
            byRun[ro].add h
            allHits += 1
            if op in LoadOps:
              loadHits += 1
              if bank <= 4:
                c0c4Load += 1
              if bank <= 0x0F:
                lowBankLoad += 1
      p += 1

  echo &"AbsoluteLong → residual free: {allHits} total, {loadHits} LDA.L/X, " &
    &"C0-C4 LDA={c0c4Load}, C0-CF LDA={lowBankLoad}, runs={byRun.len}"

  type Rank = object
    ro: int
    loadsLow: int
    loads: int
    hits: int
    runN: int

  var ranks: seq[Rank] = @[]
  for ro, hs in byRun.pairs:
    var ll = 0
    var l = 0
    for h in hs:
      if h.op in LoadOps:
        l += 1
        if h.srcBank <= 0x0F:
          ll += 1
    ranks.add Rank(ro: ro, loadsLow: ll, loads: l, hits: hs.len, runN: hs[0].runN)
  ranks.sort(proc(a, b: Rank): int =
    result = cmp(b.loadsLow, a.loadsLow)
    if result == 0:
      result = cmp(b.loads, a.loads)
    if result == 0:
      result = cmp(b.runN, a.runN)
    if result == 0:
      result = cmp(a.ro, b.ro))

  echo "\n=== Top residual runs with LDA.L/X (prefer C0-CF src) ==="
  var shown = 0
  for rnk in ranks:
    if shown >= 40:
      break
    if rnk.loads == 0:
      continue
    let hs = byRun[rnk.ro]
    var hx = ""
    for b in 0 ..< min(16, rnk.runN):
      hx.add &"{g[rnk.ro + b]:02X} "
    echo &"  0x{rnk.ro:06X}+{rnk.runN} loadsLow={rnk.loadsLow} loads={rnk.loads} " &
      &"hits={rnk.hits} head={hx}"
    var seen = initHashSet[uint32]()
    var n = 0
    for h in hs:
      if h.op notin LoadOps:
        continue
      if h.snes in seen:
        continue
      seen.incl h.snes
      let mn = if h.op == 0xAF: "LDA.L" else: "LDA.L,X"
      echo &"    {mn} ${h.snes:06X} fo=0x{h.fo:06X} from ${0xC0 + h.srcBank:02X}@0x{h.at:06X}"
      n += 1
      if n >= 6:
        break
    shown += 1
  if shown == 0:
    echo "  (none)"

  # Also report top non-load hits for awareness
  echo "\n=== Top residual runs with any AbsLong (no LDA filter) top 15 ==="
  ranks.sort(proc(a, b: Rank): int =
    result = cmp(b.hits, a.hits)
    if result == 0:
      result = cmp(b.runN, a.runN))
  for i in 0 ..< min(15, ranks.len):
    let rnk = ranks[i]
    let hs = byRun[rnk.ro]
    var ops: CountTable[uint8]
    for h in hs:
      ops.inc h.op
    var opstr = ""
    for k, v in ops.pairs:
      opstr.add &"{k:02X}x{v} "
    echo &"  0x{rnk.ro:06X}+{rnk.runN} hits={rnk.hits} ops=[{opstr}] loads={rnk.loads}"

  echo "\n=== Known family leftover scan ==="
  var totals = initTable[string, int]()
  var counts = initTable[string, int]()
  proc bump(k: string; n: int) =
    if k notin totals:
      totals[k] = 0
      counts[k] = 0
    totals[k] = totals[k] + n
    counts[k] = counts[k] + 1

  var claimed2 = claimed

  for r in freeRuns(claimed2):
    var ok = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        ok = false
        break
    if ok and r.n >= 1:
      bump("zero", r.n)
      mark(claimed2, r.o, r.n)

  for r in freeRuns(claimed2):
    if r.n < ActionScriptMinLen:
      continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      bump("as", r.n)
      mark(claimed2, r.o, r.n)
    else:
      let w = walkActionScript(g, r.o, r.o + r.n)
      if isGoodActionScriptWalk(w) and w.length >= ActionScriptMinLen and
          w.length <= r.n:
        if isGoodActionScriptSpan(g, r.o, w.length):
          bump("asHead", w.length)
          mark(claimed2, r.o, w.length)

  for r in freeRuns(claimed2):
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
      bump("const", r.n)
      mark(claimed2, r.o, r.n)

  for r in freeRuns(claimed2):
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
    if ok * 100 >= nRec * 55 and nz * 2 >= nRec:
      bump("u8pair", r.n)
      mark(claimed2, r.o, r.n)

  for r in freeRuns(claimed2):
    if r.n < 3:
      continue
    var bestN = 0
    var bestA = -1
    for align in 0 .. 2:
      let rem = r.n - align
      if rem < 3 or rem mod 3 != 0:
        continue
      var ok = true
      let nRec = rem div 3
      for i in 0 ..< nRec:
        if not isFar3(g, r.o + align + i * 3):
          ok = false
          break
      if ok and rem > bestN:
        bestN = rem
        bestA = align
    if bestA >= 0:
      bump("far3", bestN)
      mark(claimed2, r.o + bestA, bestN)

  for r in freeRuns(claimed2):
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
      bump("bitFlag", r.n)
      mark(claimed2, r.o, r.n)

  for r in freeRuns(claimed2):
    if r.n < 12 or r.n mod 4 != 0:
      continue
    let nRec = r.n div 4
    if nRec < 3:
      continue
    var banks = initCountTable[uint8]()
    for i in 0 ..< nRec:
      banks.inc g[r.o + i * 4 + 3]
    var bankCnt = 0
    var majBank: uint8 = 0
    for k, v in banks.pairs:
      if v > bankCnt:
        bankCnt = v
        majBank = k
    if bankCnt * 100 >= nRec * 40 and majBank >= 0xC0 and majBank <= 0xEF:
      bump("fix4bank", r.n)
      mark(claimed2, r.o, r.n)

  for termByte in 0xF0 .. 0xFF:
    var o = 0
    while o < g.len:
      if claimed2[o]:
        o += 1
        continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not claimed2[pos]:
        var k = pos
        while k < g.len and not claimed2[k] and g[k] != termByte.uint8 and
            (k - pos) < 48:
          k += 1
        if k >= g.len or claimed2[k] or g[k] != termByte.uint8:
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
          bump("term", n)
          mark(claimed2, start, n)
          o = pos
          continue
      o += 1

  for r in freeRuns(claimed2):
    if r.n < 6:
      continue
    var good = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if (b >= 0x20 and b <= 0x7E) or (b >= 0x50 and b <= 0x90):
        good += 1
    if good * 100 >= r.n * 70:
      bump("print70", r.n)
      mark(claimed2, r.o, r.n)

  for r in freeRuns(claimed2):
    if r.n < 8:
      continue
    var eq = 0
    let pairs = r.n div 2
    for i in 0 ..< pairs:
      if g[r.o + i * 2] == g[r.o + i * 2 + 1]:
        eq += 1
    if pairs > 0 and eq * 100 >= pairs * 25:
      var nz = 0
      for j in 0 ..< r.n:
        if g[r.o + j] != 0:
          nz += 1
      if nz * 2 >= r.n:
        bump("plane25", r.n)
        mark(claimed2, r.o, r.n)

  for r in freeRuns(claimed2):
    if r.n < 4 or r.n > 64:
      continue
    let slice = g[r.o ..< r.o + r.n]
    let (data, consumed, clean) = decodeWithConsumed(slice)
    if clean and consumed == r.n and data.len > 0:
      bump("gfxLz", r.n)
      mark(claimed2, r.o, r.n)

  for r in freeRuns(claimed2):
    if r.n < 6:
      continue
    let wss = walkScriptStream(g, r.o, r.o + r.n)
    if isGoodScriptStream(wss) and wss.length == r.n:
      bump("ss", r.n)
      mark(claimed2, r.o, r.n)

  echo "Claimable leftovers by family:"
  var keys = toSeq(totals.keys)
  keys.sort()
  var tot = 0
  for k in keys:
    echo &"  {k}: {totals[k]} B / {counts[k]} spans"
    tot += totals[k]
  echo &"TOTAL claimable under known gates: {tot} B"

  echo "\n=== Extended family probes ==="
  var alphCounts = initCountTable[string]()
  var d8 = 0
  for r in freeRuns(claimed):
    if r.o shr 16 != 0x18:
      continue
    if r.n < 4:
      continue
    var set = initHashSet[uint8]()
    for j in 0 ..< r.n:
      set.incl g[r.o + j]
    if set.len <= 5:
      var keys2 = toSeq(set)
      keys2.sort()
      var s = ""
      for k in keys2:
        s.add &"{k:02X},"
      alphCounts.inc s, r.n
      d8 += r.n
  echo &"D8 residual free ≥4B low-alphabet: {d8} B"
  var aks = toSeq(alphCounts.keys)
  aks.sort(proc(a, b: string): int = cmp(alphCounts[b], alphCounts[a]))
  for i in 0 ..< min(15, aks.len):
    echo &"  {{{aks[i]}}} = {alphCounts[aks[i]]} B"

  var far3mid = 0
  var far3n = 0
  for r in freeRuns(claimed):
    if r.n < 3:
      continue
    var i = 0
    while i + 3 <= r.n:
      if isFar3(g, r.o + i):
        far3mid += 3
        far3n += 1
        i += 3
      else:
        i += 1
  echo &"mid-run far3 singles: {far3mid} B / {far3n} ptrs"

  var codeShape = 0
  for r in freeRuns(claimed):
    if r.n >= 2 and g[r.o] == 0xC2 and g[r.o + 1] in [0x20u8, 0x30u8, 0x31u8]:
      codeShape += r.n
      echo &"  code-shape 0x{r.o:06X}+{r.n}"
    elif r.n >= 3 and g[r.o] == 0x6B and g[r.o + 1] == 0xC2:
      codeShape += r.n
      echo &"  RTL+REP 0x{r.o:06X}+{r.n}"
  echo &"code-shape free total tagged: {codeShape}"

  var countN = 0
  let strides = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 17, 25, 27, 41]
  for r in freeRuns(claimed):
    if r.n < 5:
      continue
    for stride in strides:
      let cnt = g[r.o].int
      if cnt >= 2 and 1 + cnt * stride == r.n:
        var nz = 0
        for j in 1 ..< r.n:
          if g[r.o + j] != 0:
            nz += 1
        if nz * 100 >= r.n * 30:
          countN += r.n
          echo &"  countN u8*{stride} 0x{r.o:06X}+{r.n} cnt={cnt}"
      if r.n >= 2:
        let cnt16 = g[r.o].int or (g[r.o + 1].int shl 8)
        if cnt16 >= 2 and cnt16 < 200 and 2 + cnt16 * stride == r.n:
          var nz = 0
          for j in 2 ..< r.n:
            if g[r.o + j] != 0:
              nz += 1
          if nz * 100 >= r.n * 30:
            countN += r.n
            echo &"  countN u16*{stride} 0x{r.o:06X}+{r.n} cnt={cnt16}"
  echo &"countN exact full-run: {countN} B"

main()
