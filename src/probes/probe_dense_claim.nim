## Deep RE on loader-backed residual candidates in CA/CE/D7/DB.

import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[memmap, rom_chunks, baserom_extract, generated/code_spans]

const Gold = "bin/Earthbound (U) [!].smc"

proc isFree(claimed: seq[bool]; o, n: int): bool =
  ## True when [o, o+n) is entirely unclaimed.
  if o < 0 or o + n > claimed.len: return false
  for j in 0..<n:
    if claimed[o + j]: return false
  true

proc mark(claimed: var seq[bool]; o, n: int) =
  ## Mark a span claimed.
  for j in 0..<n: claimed[o + j] = true

proc hexDump(g: string; o, n: int): string =
  ## Hex dump n bytes at o.
  result = ""
  for i in 0..<n:
    if i > 0 and i mod 16 == 0: result.add "\n    "
    result.add &"{g[o+i].uint8:02X} "

proc main() =
  ## Analyze claimable residual free runs in dense banks.
  let g = readFile(Gold)
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  echo "=== 1) CE62EE 5-byte table (loader C2EBDF LDA.L,X) ==="
  block:
    let base = 0x0E62EE
    echo &"  base file 0x{base:06X} residual={not claimed[base]}"
    var i = 0
    var good = 0
    var freeBytes = 0
    var freeRuns: seq[tuple[o, n: int]] = @[]
    var runS = -1
    var runL = 0
    while base + i + 5 <= g.len and i < 0x3000:
      let o = base + i
      let bk = g[o+2].uint8
      let z = g[o+3].uint8
      let ty = g[o+4].uint8
      let ok = z == 0 and ty >= 1 and ty <= 6 and bk >= 0xC0 and bk <= 0xFF
      if not ok:
        break
      good += 1
      if isFree(claimed, o, 5):
        freeBytes += 5
        if runS < 0: runS = o; runL = 5
        elif o == runS + runL: runL += 5
        else:
          freeRuns.add (runS, runL)
          runS = o; runL = 5
      else:
        if runL > 0:
          freeRuns.add (runS, runL)
          runS = -1; runL = 0
      i += 5
    if runL > 0: freeRuns.add (runS, runL)
    echo &"  consecutive 5B recs from base: {good} ({good*5} B)"
    echo &"  residual free among them: {freeBytes} B in {freeRuns.len} runs"
    for r in freeRuns:
      echo &"    free 0x{r.o:06X}+{r.n}  ({r.n div 5} recs)"
    let ld = 0x02EBDF
    echo &"  loader @0x{ld:06X}: {hexDump(g, ld-8, 24)}"

  echo "\n=== 2) D7A800 map-attr residual (1-byte cells, loader-documented) ==="
  block:
    let base = 0x17A800
    # How far is the table? Scan loaders for D7A800
    # residual holes in base..base+0x2000
    var free = 0
    var runs: seq[tuple[o, n: int]] = @[]
    var rs = -1
    let win = 0x2000
    for o in base ..< min(base + win, g.len):
      if not claimed[o]:
        free += 1
        if rs < 0: rs = o
      else:
        if rs >= 0:
          runs.add (rs, o - rs)
          rs = -1
    if rs >= 0: runs.add (rs, min(base+win, g.len) - rs)
    echo &"  residual in D7A800+{win:#X}: {free} B, {runs.len} runs"
    runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))
    for r in runs[0 ..< min(15, runs.len)]:
      echo &"    0x{r.o:06X}+{r.n}"

  echo "\n=== 3) D7B200 u16 tile-prop residual ==="
  block:
    let base = 0x17B200
    var free = 0
    var runs: seq[tuple[o, n: int]] = @[]
    var rs = -1
    for o in base ..< base + 0x1000:
      if not claimed[o]:
        free += 1
        if rs < 0: rs = o
      else:
        if rs >= 0:
          runs.add (rs, o - rs)
          rs = -1
    if rs >= 0: runs.add (rs, base + 0x1000 - rs)
    echo &"  residual D7B200+4K: {free} B"
    for r in runs:
      if r.n >= 2:
        echo &"    0x{r.o:06X}+{r.n}  align2={r.o mod 2 == 0}"

  echo "\n=== 4) C0-C4 LDA.L/LDA.L,X bases near large residual (window) ==="
  var largeRuns: seq[tuple[o, n: int]] = @[]
  for c in allRomChunksMeta():
    if c.kind == ckUnclaimed and c.length >= 80:
      let fb = c.offset div 0x10000
      if fb in {0x0A, 0x0E, 0x17, 0x1B}:
        largeRuns.add (c.offset, c.length)

  type BH = object
    fo, n: int
    residual: bool
    sites: seq[int]
    nearRuns: seq[int]
  var byBase = initTable[int, BH]()
  for bank in 0..4:
    let b0 = bank * 0x10000
    for p in b0 ..< b0 + 0x10000 - 4:
      let op = g[p].uint8
      if op notin {0xAF'u8, 0xBF'u8}: continue
      let snes = g[p+1].uint8.uint32 or (g[p+2].uint8.uint32 shl 8) or
        (g[p+3].uint8.uint32 shl 16)
      let fbank = int((snes shr 16) and 0xFF) - 0xC0
      if fbank notin {0x0A, 0x0E, 0x17, 0x1B}: continue
      let fo = snesToFile(snes)
      if fo < 0: continue
      var near: seq[int] = @[]
      for r in largeRuns:
        if fo >= r.o - 0x1000 and fo < r.o + r.n + 0x100:
          near.add r.o
      if near.len == 0: continue
      if fo notin byBase:
        byBase[fo] = BH(fo: fo, n: 0, residual: not claimed[fo], sites: @[], nearRuns: near)
      byBase[fo].n += 1
      if byBase[fo].sites.len < 4:
        byBase[fo].sites.add p

  var items: seq[BH] = @[]
  for _, v in byBase: items.add v
  items.sort(proc(a, b: BH): int = cmp(b.n, a.n))
  echo &"  bases: {items.len}"
  for it in items[0 ..< min(30, items.len)]:
    let snes = fileToSnes(it.fo)
    echo &"    ${snes:06X} fo=0x{it.fo:06X} res={it.residual} refs={it.n} sites={it.sites} nearRuns={it.nearRuns}"

  echo "\n=== 5) CE FF short-rec residual remaining (same gate as prior wave) ==="
  block:
    # scan CE bank residual for FF-terminated L2..16 majority-00 records
    var claimed2 = claimed
    var total = 0
    var spans: seq[tuple[o, n: int]] = @[]
    let bankStart = 0x0E0000
    let bankEnd = 0x0F0000
    var o = bankStart
    while o < bankEnd:
      if claimed2[o]:
        o += 1
        continue
      # try walk FF records
      var p = o
      var recs = 0
      var zeros = 0
      var bytes = 0
      while p < bankEnd and not claimed2[p]:
        var q = p
        while q < bankEnd and not claimed2[q] and g[q].uint8 != 0xFF and q - p < 32:
          q += 1
        if q >= bankEnd or claimed2[q] or g[q].uint8 != 0xFF:
          break
        let recLen = q - p + 1
        if recLen < 2 or recLen > 16:
          break
        for k in p..<q:
          if g[k].uint8 == 0: zeros += 1
        bytes += recLen
        recs += 1
        p = q + 1
        if recs >= 200: break
      let zeroRatio = if bytes > 0: zeros.float / bytes.float else: 0
      # claim-quality: ≥3 recs, some zero density OR known path-like
      if recs >= 4 and bytes >= 12:
        spans.add (o, bytes)
        total += bytes
        for j in 0..<bytes: claimed2[o + j] = true
        o += bytes
      else:
        o += 1
    echo &"  candidate FF-rec residual spans: {spans.len} totaling {total} B"
    spans.sort(proc(a, b: auto): int = cmp(b.n, a.n))
    for s in spans[0 ..< min(20, spans.len)]:
      echo &"    0x{s.o:06X}+{s.n}  head {hexDump(g, s.o, min(12, s.n))}"

  echo "\n=== 6) Global residual composition (all banks) for false-code note ==="
  block:
    var byFb: array[48, tuple[code, meta, unc: int]]
    for c in allRomChunksMeta():
      let fb = c.offset div 0x10000
      if fb > 47: continue
      case c.kind
      of ckImplementedCode: byFb[fb].code += c.length
      of ckImplementedMeta: byFb[fb].meta += c.length
      of ckUnclaimed: byFb[fb].unc += c.length
    # banks with high code% but residual dense binary likely false-code
    echo "  banks with code>45K and unc>3K (likely data mislabeled as code):"
    for fb in 0..47:
      if byFb[fb].code > 45000 and byFb[fb].unc > 3000:
        let snes = 0xC0 + fb
        let pct = byFb[fb].code.float * 100.0 / 65536.0
        echo &"    ${snes:02X}: code={byFb[fb].code} ({pct:.1f}%) meta={byFb[fb].meta} unc={byFb[fb].unc}"

  echo "\n=== 7) Try u16-pair stream on DB714F (looks like tile/sprite ids) ==="
  block:
    let ro = 0x1B714F
    let rl = 814
    # values as u16 LE
    var vals: seq[int] = @[]
    for i in 0 ..< rl div 2:
      vals.add(g[ro + i*2].int or (g[ro + i*2 + 1].int shl 8))
    # histogram of high bytes
    var hiC: array[256, int]
    for v in vals: hiC[v shr 8] += 1
    echo "  high-byte histogram (non0):"
    for h in 0..255:
      if hiC[h] > 5:
        echo &"    hi={h:02X}: {hiC[h]}"
    # group as records of 3 u16?
    echo &"  first 20 u16: {vals[0 ..< 20]}"

  echo "\n=== 8) CAB440 pattern (E0-terminated? audio?) ==="
  block:
    let ro = 0x0AB440
    let rl = 396
    var e0 = 0
    for i in 0..<rl:
      if g[ro+i].uint8 == 0xE0: e0 += 1
    echo &"  E0 count: {e0}/{rl}"
    echo &"  head: {hexDump(g, ro, 48)}"
    # check if gfx_lz or apu-like
    # consecutive 2-byte: low = index, high = E0/20/A0/60 pattern
    var pairOk = 0
    var i = 0
    while i + 1 < rl:
      let hi = g[ro+i+1].uint8
      if hi in {0xE0'u8, 0x20'u8, 0xA0'u8, 0x60'u8, 0x00'u8, 0x01'u8}:
        pairOk += 1
      i += 2
    echo &"  even pairs with hi in {{E0,20,A0,60,00,01}}: {pairOk}/{rl div 2}"

main()
