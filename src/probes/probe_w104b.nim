import
  std/[algorithm, strformat, strutils, tables, sequtils],
  ../decompbound/[rom_chunks, baserom_extract, action_script, text_decode, gfx_lz]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o+j>=0 and o+j<c.len: c[o+j]=true
proc isFree(c: seq[bool]; o,n: int): bool =
  if o<0 or n<=0 or o+n>c.len: return false
  for j in 0..<n:
    if c[o+j]: return false
  true
proc freeRuns(c: seq[bool]): seq[tuple[o, n: int]] =
  var rs = -1
  var rl = 0
  for o in 0 ..< c.len:
    if not c[o]:
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
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset+c.length, isCode.len): isCode[i]=true

  var totals = initTable[string,int]()
  var counts = initTable[string,int]()
  proc bump(k: string; n: int) =
    if k notin totals: totals[k]=0; counts[k]=0
    totals[k]+=n; counts[k]+=1

  # u8pair min3 @55%
  for r in freeRuns(claimed):
    if r.n < 6 or r.n mod 2 != 0: continue
    let nRec = r.n div 2
    if nRec < 3: continue
    var ok,nz=0
    for i in 0..<nRec:
      let a=g[r.o+i*2]; let b=g[r.o+i*2+1]
      if a<=0x50 or b<=0x50: ok+=1
      if a!=0 or b!=0: nz+=1
    if ok*100 < nRec*55: continue
    if nz*2 < nRec: continue
    let lc=r.o>0 and isCode[r.o-1]; let rc=r.o+r.n<isCode.len and isCode[r.o+r.n]
    if lc and rc: continue
    mark(claimed,r.o,r.n); bump("u8pair3", r.n)

  # fix3 min2 ≥40% bank@+2
  for r in freeRuns(claimed):
    let nRec = r.n div 3
    if nRec < 2: continue
    let n = nRec*3
    var banks=0
    for i in 0..<nRec:
      let b=g[r.o+i*3+2].int
      if b>=0xC0 and b<=0xEF: banks+=1
    if banks*100 >= nRec*40 and isFree(claimed,r.o,n):
      mark(claimed,r.o,n); bump("fix3", n)

  # fix4 min2 ≥40% bank@+3 (any leftover)
  for r in freeRuns(claimed):
    let nRec = r.n div 4
    if nRec < 2: continue
    let n = nRec*4
    var banks=0
    for i in 0..<nRec:
      let b=g[r.o+i*4+3].int
      if b>=0xC0 and b<=0xEF: banks+=1
    if banks*100 >= nRec*40 and isFree(claimed,r.o,n):
      mark(claimed,r.o,n); bump("fix4", n)

  # plane50 even prefix leftover
  for r in freeRuns(claimed):
    let evenN = (r.n div 2) * 2
    if evenN < 8: continue
    let lc=r.o>0 and isCode[r.o-1]; let rc=r.o+evenN<isCode.len and isCode[r.o+evenN]
    if lc and rc: continue
    var eq=0
    let pairs=evenN div 2
    for i in 0..<pairs:
      if g[r.o+i*2]==g[r.o+i*2+1]: eq+=1
    if eq*100 < pairs*50: continue
    var nz=0
    for j in 0..<evenN:
      if g[r.o+j]!=0: nz+=1
    if nz*2 < evenN: continue
    mark(claimed,r.o,evenN); bump("plane50", evenN)

  # AS good remaining
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen: continue
    if isGoodActionScriptSpan(g,r.o,r.n):
      mark(claimed,r.o,r.n); bump("as", r.n)

  # gfx_lz clean
  for r in freeRuns(claimed):
    if r.n < 4: continue
    let slice = g[r.o ..< r.o+r.n]
    let (data, consumed, clean) = decodeWithConsumed(slice)
    if clean and consumed>=4 and consumed<=r.n and data.len>=16 and isFree(claimed,r.o,consumed):
      mark(claimed,r.o,consumed); bump("gfx", consumed)

  # SS good full free
  for r in freeRuns(claimed):
    if r.n < 2: continue
    let w = walkScriptStream(g, r.o, r.o+r.n)
    if isGoodScriptStream(w) and w.length == r.n:
      mark(claimed,r.o,r.n); bump("ssGood", r.n)

  # term multi >=2 recs leftover
  for termByte in 0xF0..0xFF:
    var o=0
    while o<g.len:
      if claimed[o]: o+=1; continue
      let start=o
      var pos=o; var recs=0
      while pos<g.len and not claimed[pos]:
        var k=pos
        while k<g.len and not claimed[k] and g[k]!=termByte.uint8 and (k-pos)<48: k+=1
        if k>=g.len or claimed[k] or g[k]!=termByte.uint8: break
        let rl=k-pos+1
        if rl<2 or rl>48: break
        recs+=1; pos=k+1
      let n=pos-start
      if recs>=2 and n>=4 and isFree(claimed,start,n):
        var tc=0
        for j in 0..<n:
          if g[start+j]==termByte.uint8: tc+=1
        if tc==recs:
          mark(claimed,start,n); bump("termMulti", n)
          o=pos; continue
      o+=1

  # zero/const leftover
  for r in freeRuns(claimed):
    var ok=true
    for j in 0..<r.n:
      if g[r.o+j]!=0: ok=false; break
    if ok: mark(claimed,r.o,r.n); bump("zero", r.n)
  for r in freeRuns(claimed):
    if r.n<2: continue
    let v=g[r.o]
    if v==0: continue
    var same=true
    for j in 1..<r.n:
      if g[r.o+j]!=v: same=false; break
    if same: mark(claimed,r.o,r.n); bump("const", r.n)

  var rem=0
  for r in freeRuns(claimed): rem+=r.n
  echo "w104b extras claimable:"
  for k in totals.keys.toSeq.sorted:
    echo &"  {k}: {totals[k]}/{counts[k]}"
  var tot=0
  for v in totals.values: tot+=v
  echo &"total extra {tot} B; residual after {rem}"

main()
