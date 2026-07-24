
import std/[strformat, algorithm],
  ../decompbound/[rom_chunks, baserom_extract]

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset ..< min(c.offset+c.length, claimed.len):
      claimed[i] = true

var zeros = 0
var runs: seq[tuple[o,n:int]] = @[]
var rs = -1; var rl = 0
for o in 0..<g.len:
  if not claimed[o]:
    if g[o] == 0: zeros += 1
    if rs < 0: rs = o; rl = 1
    else: rl += 1
  else:
    if rs >= 0: runs.add (rs, rl); rs = -1
if rs >= 0: runs.add (rs, rl)
runs.sort(proc(a,b:auto):int = cmp(b.n,a.n))
var hist = [0,0,0,0,0,0]
for r in runs:
  if r.n < 4: hist[0]+=r.n
  elif r.n < 8: hist[1]+=r.n
  elif r.n < 16: hist[2]+=r.n
  elif r.n < 64: hist[3]+=r.n
  elif r.n < 256: hist[4]+=r.n
  else: hist[5]+=r.n
echo &"zero residual: {zeros}"
echo &"hist: <4={hist[0]} <8={hist[1]} <16={hist[2]} <64={hist[3]} <256={hist[4]} 256+={hist[5]}"
echo "top 15 runs:"
for i in 0..<min(15, runs.len):
  let r = runs[i]
  var z = 0
  for j in 0..<r.n:
    if g[r.o+j]==0: z+=1
  var hx=""
  for j in 0..<min(12,r.n): hx.add &"{g[r.o+j]:02X} "
  echo &"  0x{r.o:06X}+{r.n} zeros={z} head={hx}"
