## How solid are mid-run far3 residual hits?
import
  std/[strformat, algorithm],
  ../decompbound/[rom_chunks, baserom_extract]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0..<n:
    if o+j>=0 and o+j<c.len: c[o+j]=true

proc freeRuns(claimed: seq[bool]): seq[tuple[o,n:int]] =
  result = @[]
  var rs= -1; var rl=0
  for o in 0..<claimed.len:
    if not claimed[o]:
      if rs<0: rs=o; rl=1 else: rl+=1
    else:
      if rs>=0: result.add (rs,rl); rs= -1
  if rs>=0: result.add (rs,rl)

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)

# buckets: pure free-run far3 (start, full consume), align0-2 full consume, mid singles
var pureStart=0; var pureStartN=0
var alignFull=0; var alignFullN=0
var midSingle=0; var midSingleN=0
var midMulti=0; var midMultiN=0
var alphabet=0; var alphabetN=0

for r in freeRuns(claimed):
  # pure start chain
  block:
    var i=0; var cnt=0
    while i+3<=r.n:
      let lo=g[r.o+i].int or (g[r.o+i+1].int shl 8)
      let b=g[r.o+i+2]
      if b>=0xC0 and b<=0xEF and lo!=0: cnt+=1; i+=3
      else: break
    if cnt>=1 and cnt*3==r.n:
      pureStart += r.n; pureStartN += 1

  # align 0..2 full consume with only far3
  for align in 0..2:
    if align >= r.n: continue
    let base=r.o+align
    let rem=r.n-align
    if rem < 3 or rem mod 3 != 0: continue
    var ok=true
    let nRec=rem div 3
    for i in 0..<nRec:
      let lo=g[base+i*3].int or (g[base+i*3+1].int shl 8)
      let b=g[base+i*3+2]
      if not (b>=0xC0 and b<=0xEF and lo!=0): ok=false; break
    if ok and nRec>=1:
      alignFull += rem; alignFullN += 1
      break

  # mid multi/single
  var i=0
  while i+3<=r.n:
    let lo=g[r.o+i].int or (g[r.o+i+1].int shl 8)
    let b=g[r.o+i+2]
    if b>=0xC0 and b<=0xEF and lo!=0:
      var k=i; var cnt=0
      while k+3<=r.n:
        let lo2=g[r.o+k].int or (g[r.o+k+1].int shl 8)
        let b2=g[r.o+k+2]
        if not (b2>=0xC0 and b2<=0xEF and lo2!=0): break
        cnt+=1; k+=3
      if cnt>=2: midMulti+=cnt*3; midMultiN+=1
      elif cnt==1: midSingle+=3; midSingleN+=1
      i=k
    else: i+=1

  # 00/01/80 alphabet ≥4
  if r.n>=4:
    var ok=true
    for j in 0..<r.n:
      if g[r.o+j] notin [0x00u8,0x01u8,0x80u8]: ok=false; break
    if ok: alphabet+=r.n; alphabetN+=1

echo &"pure free-run = exact far3 chain: {pureStart} B / {pureStartN}"
echo &"align 0-2 full rem far3: {alignFull} B / {alignFullN}"
echo &"mid multi≥2 far3: {midMulti} B / {midMultiN}"
echo &"mid single far3: {midSingle} B / {midSingleN}"
echo &"alphabet 00/01/80 ≥4: {alphabet} B / {alphabetN}"

# show pure start examples
echo "pure start examples:"
var n=0
for r in freeRuns(claimed):
  var i=0; var cnt=0
  while i+3<=r.n:
    let lo=g[r.o+i].int or (g[r.o+i+1].int shl 8)
    let b=g[r.o+i+2]
    if b>=0xC0 and b<=0xEF and lo!=0: cnt+=1; i+=3 else: break
  if cnt>=1 and cnt*3==r.n:
    var hx=""
    for j in 0..<min(12,r.n): hx.add &"{g[r.o+j]:02X} "
    echo &"  0x{r.o:06X}+{r.n} {hx}"
    n+=1
    if n>=20: break

# SS loose examples
import ../decompbound/text_decode
echo "ssLoose examples:"
n=0
for r in freeRuns(claimed):
  if r.n < 4: continue
  let w=walkScriptStream(g, r.o, r.o+r.n)
  if w.ended and w.badGlyphs==0 and w.glyphs>=2 and w.length>=4 and w.length<=r.n:
    var hx=""
    for j in 0..<min(16,w.length): hx.add &"{g[r.o+j]:02X} "
    echo &"  0x{r.o:06X}+{w.length} (run {r.n}) g={w.glyphs} c={w.controls} {hx}"
    n+=1
    if n>=15: break
