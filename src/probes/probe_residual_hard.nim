import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract]

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
  var tot = 0
  for r in runs: tot += r.n
  echo &"free={tot} runs={runs.len}"
  var bankTot: array[0x30, int]
  for r in runs:
    let b = r.o shr 16
    if b < bankTot.len: bankTot[b] += r.n
  var pairs: seq[tuple[b,n:int]] = @[]
  for b in 0..<bankTot.len:
    if bankTot[b] > 0: pairs.add (b, bankTot[b])
  pairs.sort(proc(a,b: auto): int = cmp(b.n, a.n))
  echo "top banks:"
  for p in pairs[0 ..< min(12, pairs.len)]:
    echo &"  ${p.b+0xC0:02X}: {p.n}"
  # size hist
  var h = [0,0,0,0,0,0]
  for r in runs:
    if r.n == 1: h[0]+=r.n
    elif r.n <= 3: h[1]+=r.n
    elif r.n <= 7: h[2]+=r.n
    elif r.n <= 11: h[3]+=r.n
    elif r.n <= 15: h[4]+=r.n
    else: h[5]+=r.n
  echo &"bytes by size: 1={h[0]} 2-3={h[1]} 4-7={h[2]} 8-11={h[3]} 12-15={h[4]} 16+={h[5]}"
  # top 30
  var kindAt = newSeq[string](g.len)
  for c in allRomChunksMeta():
    let kn = case c.kind
      of ckImplementedCode: "code"
      of ckImplementedMeta: "meta"
      of ckUnclaimed: "free"
    for j in 0..<c.length:
      if c.offset+j < kindAt.len: kindAt[c.offset+j] = kn
  echo "top free:"
  for i in 0 ..< min(30, runs.len):
    let r = runs[i]
    var hx = ""
    for j in 0 ..< min(20, r.n): hx.add &"{g[r.o+j]:02X} "
    let L = if r.o>0: kindAt[r.o-1] else: "edge"
    let R = if r.o+r.n < g.len: kindAt[r.o+r.n] else: "edge"
    # classify
    var why = "dense-binary"
    if r.n >= 7 and g[r.o]==0xC2 and g[r.o+1]==0x31 and g[r.o+2]==0x22:
      why = "code-like REP#31 JSL (code_span miss)"
    elif r.n >= 4 and g[r.o]==0x42 and g[r.o+3] >= 0xC0:
      why = "AS FAR-CALL head (incomplete walk)"
    elif r.n >= 4 and g[r.o]==0xC2:
      why = "code-like REP prologue"
    echo &"0x{r.o:06X}+{r.n:2} L={L} R={R} | {hx}| {why}"
main()
