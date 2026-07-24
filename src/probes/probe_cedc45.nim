## RE $CEDC45 u16 ptr table (loader $C4AA97 LDA.L,X) and residual claims.

import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[memmap, rom_chunks]

const Gold = "bin/Earthbound (U) [!].smc"
const
  PtrBase = 0x0EDC45
  BankBase = 0x0E0000
  BankSnes = 0xCE

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0..<n:
    if o+j < c.len: c[o+j] = true

proc isFree(c: seq[bool]; o, n: int): bool =
  if o < 0 or o+n > c.len: return false
  for j in 0..<n:
    if c[o+j]: return false
  true

proc main() =
  let g = readFile(Gold)
  var claimed = newSeq[bool](g.len)
  for ch in allRomChunksMeta():
    if ch.kind != ckUnclaimed:
      mark(claimed, ch.offset, ch.length)

  # Walk u16 ptrs while monotonic-ish and in bank range
  var ptrs: seq[tuple[id, off, fo: int]] = @[]
  var i = 0
  var prev = -1
  while PtrBase + i*2 + 1 < g.len and i < 512:
    let o = PtrBase + i*2
    let v = g[o].int or (g[o+1].int shl 8)
    if v < 0x1000 or v >= 0x10000:
      # allow after some entries?
      if i > 10 and (v == 0 or v < prev): break
      if i < 5: break
    if prev >= 0 and v < prev - 0x100:
      # big backwards = end
      if i > 20: break
    let fo = BankBase + v
    if fo >= 0x0F0000:
      if i > 20: break
    ptrs.add (i, v, fo)
    prev = v
    i += 1

  echo &"u16 ptrs from $CEDC45: {ptrs.len}"
  echo &"  first: id0=${ptrs[0].off:04X} fo=0x{ptrs[0].fo:06X} res={not claimed[ptrs[0].fo]}"
  echo &"  last:  id{ptrs[^1].id}=${ptrs[^1].off:04X} fo=0x{ptrs[^1].fo:06X}"
  echo &"  ptr table end: 0x{PtrBase + ptrs.len*2:06X}"

  # residual free in pointer table itself
  var ptrFree = 0
  var ptrRuns: seq[tuple[o,n:int]] = @[]
  var rs = -1
  let ptrEnd = PtrBase + ptrs.len * 2
  for o in PtrBase ..< ptrEnd:
    if not claimed[o]:
      ptrFree += 1
      if rs < 0: rs = o
    else: discard
    if claimed[o] or o == ptrEnd-1:
      let endO = if claimed[o]: o else: o+1
      if rs >= 0 and endO > rs:
        # fix run end
        discard
  # cleaner
  rs = -1
  var rl = 0
  ptrRuns = @[]
  for o in PtrBase ..< ptrEnd:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0:
        ptrRuns.add (rs, rl)
        rs = -1
  if rs >= 0: ptrRuns.add (rs, rl)
  echo &"  ptr table residual: {ptrFree} B? recount runs: {ptrRuns}"
  var pf = 0
  for r in ptrRuns: pf += r.n
  echo &"  ptr residual free bytes: {pf}"

  # Target record lengths via next ptr
  type Rec = object
    id, fo, ln: int
    free: bool
    freeBytes: int
  var recs: seq[Rec] = @[]
  var freeTot = 0
  var freeRecs = 0
  for j in 0 ..< ptrs.len - 1:
    let fo = ptrs[j].fo
    let ln = ptrs[j+1].fo - fo
    if ln <= 0 or ln > 0x800:
      recs.add Rec(id: ptrs[j].id, fo: fo, ln: ln, free: false, freeBytes: 0)
      continue
    var fb = 0
    for k in 0..<ln:
      if fo+k < g.len and not claimed[fo+k]: fb += 1
    let fully = isFree(claimed, fo, ln)
    if fully: freeRecs += 1
    freeTot += fb
    recs.add Rec(id: ptrs[j].id, fo: fo, ln: ln, free: fully, freeBytes: fb)

  echo &"  records with full residual free: {freeRecs}"
  echo &"  total residual bytes in targets: {freeTot}"
  # length histogram
  var lenH = initTable[int, int]()
  for r in recs:
    if r.ln > 0 and r.ln <= 0x200:
      lenH[r.ln] = lenH.getOrDefault(r.ln) + 1
  var lens: seq[int] = @[]
  for k in lenH.keys: lens.add k
  lens.sort()
  echo "  length histogram (len:count):"
  for k in lens:
    if lenH[k] >= 2:
      echo &"    {k}: {lenH[k]}"

  # Sample free residual runs as complete records
  echo "  fully-free residual records:"
  var claimBytes = 0
  var claimSpans: seq[tuple[o,n,id0,id1:int]] = @[]
  var runS = -1
  var runL = 0
  var id0, id1 = 0
  for r in recs:
    if r.free and r.ln > 0 and r.ln <= 0x400:
      if runS < 0:
        runS = r.fo; runL = r.ln; id0 = r.id; id1 = r.id
      elif r.fo == runS + runL:
        runL += r.ln; id1 = r.id
      else:
        claimSpans.add (runS, runL, id0, id1)
        claimBytes += runL
        runS = r.fo; runL = r.ln; id0 = r.id; id1 = r.id
    else:
      if runS >= 0:
        claimSpans.add (runS, runL, id0, id1)
        claimBytes += runL
        runS = -1
  if runS >= 0:
    claimSpans.add (runS, runL, id0, id1)
    claimBytes += runL
  echo &"  claimable residual complete-record spans: {claimSpans.len} totaling {claimBytes} B"
  for s in claimSpans[0 ..< min(20, claimSpans.len)]:
    var head = ""
    for b in 0 ..< min(12, s.n):
      head.add &"{g[s.o+b].uint8:02X} "
    echo &"    0x{s.o:06X}+{s.n} ids {s.id0}..{s.id1}  {head}"

  # Partial free mid-record residual holes
  var holeBytes = 0
  for r in recs:
    if not r.free and r.freeBytes > 0:
      holeBytes += r.freeBytes
  echo &"  partial mid-record residual (not full-record): {holeBytes} B"

  # Prefix analysis of records
  echo "  common prefixes (first 4B) among first 40 recs:"
  var pref = initTable[string, int]()
  for r in recs[0 ..< min(40, recs.len)]:
    if r.ln < 4: continue
    let p = &"{g[r.fo].uint8:02X}{g[r.fo+1].uint8:02X}{g[r.fo+2].uint8:02X}{g[r.fo+3].uint8:02X}"
    pref[p] = pref.getOrDefault(p) + 1
  var pp: seq[tuple[p: string, n: int]] = @[]
  for p, n in pref: pp.add (p, n)
  pp.sort(proc(a,b: auto): int = cmp(b.n, a.n))
  for x in pp[0 ..< min(10, pp.len)]:
    echo &"    {x.p}: {x.n}"

  # D7A800 residual claim as 1-byte map attr mid-table
  echo "\n=== D7A800 residual holes (map attr, LDA.L,X loaders) ==="
  let d7base = 0x17A800
  # Determine table size from max X index usage - typically ASL ASL suggests *4 then add?
  # loaders: ASL ASL CLC ADC $02 TAX -> index computation
  # 0x08F7: 0A 0A 18 65 02 AA BF 00 A8 D7 29 FF 00
  # So X is some computed index; table is byte array. How large?
  # residual holes only within known used range - find last non-claimed-as-something?
  # Scan until long stretch of different structure - map attr is typically 0x1000 or 0x2000 bytes
  # Claim residual free runs only between 0x17A800 and start of D7B200 (0x17B200)
  let d7end = 0x17B200
  var d7runs: seq[tuple[o,n:int]] = @[]
  rs = -1; rl = 0
  for o in d7base ..< d7end:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0:
        d7runs.add (rs, rl)
        rs = -1
  if rs >= 0: d7runs.add (rs, rl)
  var d7tot = 0
  for r in d7runs: d7tot += r.n
  echo &"  residual in [D7A800, D7B200): {d7tot} B in {d7runs.len} runs"
  for r in d7runs:
    echo &"    0x{r.o:06X}+{r.n}"

main()
