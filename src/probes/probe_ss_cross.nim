
## Find residual free runs that are prefixes of good script streams ending nearby.

import
  std/[algorithm, strformat],
  ../decompbound/[rom_chunks, baserom_extract, text_decode]

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset ..< min(c.offset + c.length, claimed.len):
      claimed[i] = true

var runs: seq[tuple[o, n: int]] = @[]
var rs = -1; var rl = 0
for o in 0 ..< g.len:
  if not claimed[o]:
    if rs < 0: rs = o; rl = 1
    else: rl += 1
  else:
    if rs >= 0: runs.add (rs, rl); rs = -1
if rs >= 0: runs.add (rs, rl)
runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))

var total = 0
var nSpans = 0
# For each free run ≥6, walk script with limit = run end + 512 into claimed
for r in runs:
  if r.n < 6: continue
  let extendLimit = min(r.o + r.n + 512, g.len)
  let w = walkScriptStream(g, r.o, extendLimit)
  if not isGoodScriptStream(w): continue
  # stream is good overall; claim only free prefix inside residual
  let claimLen = min(w.length, r.n)
  if claimLen < 6: continue
  # require most of free run is covered OR good stream starts at run
  echo &"  scriptStream 0x{r.o:06X}+{claimLen} (fullStream={w.length} glyphs={w.glyphs} ended={w.ended})"
  total += claimLen
  nSpans += 1
  for j in 0 ..< claimLen:
    claimed[r.o + j] = true

echo &"\n# SS cross-boundary residual claimable: {total} B in {nSpans} spans"

# Also: free mid-stream holes — walk from free start with extend
# re-list top remaining
runs = @[]; rs = -1; rl = 0
for o in 0 ..< g.len:
  if not claimed[o]:
    if rs < 0: rs = o; rl = 1
    else: rl += 1
  else:
    if rs >= 0: runs.add (rs, rl); rs = -1
if rs >= 0: runs.add (rs, rl)
runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))
echo &"# residual left: {runs.len} runs"
var left = 0
for r in runs: left += r.n
echo &"# residual bytes left: {left}"
