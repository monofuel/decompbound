
## Probe residual islands as script streams with default and relaxed scans.

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
echo "# script stream residual (good walk cover):"
for r in runs:
  if r.n < 8: continue
  # try start and offsets
  for d in 0 ..< min(4, r.n):
    let consumed = consumeScriptStreamRun(g, r.o + d, r.n - d)
    if consumed >= 8:
      echo &"  SS 0x{r.o+d:06X}+{consumed} (run 0x{r.o:06X}+{r.n})"
      total += consumed
      nSpans += 1
      # mark so we don't double
      for j in 0 ..< consumed:
        claimed[r.o + d + j] = true
      break

echo &"# total SS claimable: {total} B in {nSpans} spans"

# also report near-miss walks on top runs
echo "\n# near-miss walks on top residual:"
# rebuild free
runs = @[]
rs = -1; rl = 0
for o in 0 ..< g.len:
  if not claimed[o]:
    if rs < 0: rs = o; rl = 1
    else: rl += 1
  else:
    if rs >= 0: runs.add (rs, rl); rs = -1
if rs >= 0: runs.add (rs, rl)
runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))

for i in 0 ..< min(20, runs.len):
  let r = runs[i]
  let w = walkScriptStream(g, r.o, r.o + r.n)
  echo &"  0x{r.o:06X}+{r.n}: walk len={w.length} glyphs={w.glyphs} ctrl={w.controls} bad={w.badGlyphs} ended={w.ended} good={isGoodScriptStream(w)}"
