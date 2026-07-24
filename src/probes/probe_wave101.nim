## Scout wave101 honest residual claims.
import
  std/[strformat, tables, algorithm],
  ../decompbound/[rom_chunks, baserom_extract, action_script, text_decode]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0..<n:
    if o+j >= 0 and o+j < c.len: c[o+j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o+n > claimed.len: return false
  for j in 0..<n:
    if claimed[o+j]: return false
  true

proc freeRuns(claimed: seq[bool]): seq[tuple[o,n:int]] =
  result = @[]
  var rs = -1; var rl = 0
  for o in 0..<claimed.len:
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

  var totals: Table[string, int]
  proc add(k: string; n: int) =
    if k notin totals: totals[k] = 0
    totals[k] = totals[k] + n

  # 1 zero any
  for r in freeRuns(claimed):
    var ok=true
    for j in 0..<r.n:
      if g[r.o+j] != 0: ok=false; break
    if ok:
      mark(claimed, r.o, r.n); add("zero", r.n)

  # 2 AS full cover minLen4
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen: continue
    if consumeActionScriptRun(g, r.o, r.n) == r.n:
      mark(claimed, r.o, r.n); add("as", r.n)

  # 3 AS partial good heads (claim walk only)
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen: continue
    let w = walkActionScript(g, r.o, r.o+r.n)
    if isGoodActionScriptWalk(w) and w.length <= r.n and isFree(claimed, r.o, w.length):
      mark(claimed, r.o, w.length); add("asHead", w.length)

  # 4 FAR CALL complete 4B with valid bank even if not full walk? FAR alone not terminal
  # idle-like FAR+WAIT+GOTO fragments shorter than min - skip

  # 5 term F0-FF multi/single quality
  for termByte in 0xF0..0xFF:
    var o=0
    while o < g.len:
      if claimed[o]: o+=1; continue
      let start=o
      var pos=o; var recs=0
      while pos < g.len and not claimed[pos]:
        var k=pos
        while k < g.len and not claimed[k] and g[k] != termByte.uint8 and (k-pos)<48: k+=1
        if k>=g.len or claimed[k] or g[k] != termByte.uint8: break
        let rl=k-pos+1
        if rl<2 or rl>48: break
        recs+=1; pos=k+1
      let n=pos-start
      if recs>=2 and n>=4:
        var tc=0
        for j in 0..<n:
          if g[start+j]==termByte.uint8: tc+=1
        if tc==recs and isFree(claimed, start, n):
          mark(claimed, start, n); add("term", n); o=pos; continue
      if recs==1 and n>=4 and n<=32:
        var tc=0
        for j in 0..<n:
          if g[start+j]==termByte.uint8: tc+=1
        if tc==1 and g[start+n-1]==termByte.uint8 and isFree(claimed, start, n):
          mark(claimed, start, n); add("term1", n); o=pos; continue
      o+=1

  # 6 u8pair ≥4
  for r in freeRuns(claimed):
    if r.n < 8 or r.n mod 2 != 0: continue
    let nRec=r.n div 2
    if nRec < 4: continue
    var ok=0; var nz=0
    for i in 0..<nRec:
      let a=g[r.o+i*2]; let b=g[r.o+i*2+1]
      if a<=0x50 or b<=0x50: ok+=1
      if a!=0 or b!=0: nz+=1
    if ok*100 < nRec*55: continue
    if nz*2 < nRec: continue
    mark(claimed, r.o, r.n); add("u8pair", r.n)

  # 7 const fill ≥2 (non-zero)
  for r in freeRuns(claimed):
    if r.n < 2: continue
    let v=g[r.o]
    if v==0: continue
    var ok=true
    for j in 1..<r.n:
      if g[r.o+j]!=v: ok=false; break
    if ok:
      mark(claimed, r.o, r.n); add("const", r.n)

  # 8 far3 from start only ≥1 bank C0-EF lo!=0 (should be 0 if wave100b complete)
  for r in freeRuns(claimed):
    if r.n < 3: continue
    var i=0; var cnt=0
    while i+3 <= r.n:
      let lo=g[r.o+i].int or (g[r.o+i+1].int shl 8)
      let b=g[r.o+i+2]
      if b>=0xC0 and b<=0xEF and lo!=0: cnt+=1; i+=3
      else: break
    if cnt>=1:
      mark(claimed, r.o, cnt*3); add("far3start", cnt*3)

  # 9 mid-run far3 ≥1 (scan all offsets)
  for r in freeRuns(claimed):
    if r.n < 3: continue
    var i=0
    while i+3 <= r.n:
      let lo=g[r.o+i].int or (g[r.o+i+1].int shl 8)
      let b=g[r.o+i+2]
      if b>=0xC0 and b<=0xEF and lo!=0:
        var k=i; var cnt=0
        while k+3<=r.n:
          let lo2=g[r.o+k].int or (g[r.o+k+1].int shl 8)
          let b2=g[r.o+k+2]
          if not (b2>=0xC0 and b2<=0xEF and lo2!=0): break
          cnt+=1; k+=3
        if cnt>=1 and isFree(claimed, r.o+i, cnt*3):
          mark(claimed, r.o+i, cnt*3); add("far3mid", cnt*3)
          i=k
        else: i+=1
      else: i+=1

  # 10 SS good with current gates
  for r in freeRuns(claimed):
    if r.n < ScriptStreamMinLen: continue
    let w=walkScriptStream(g, r.o, r.o+r.n)
    if isGoodScriptStream(w) and isFree(claimed, r.o, w.length):
      mark(claimed, r.o, w.length); add("ss", w.length)

  # 11 SS ended, glyphs>=2, bad=0, len>=4 (relaxed residual prefix style)
  for r in freeRuns(claimed):
    if r.n < 4: continue
    let w=walkScriptStream(g, r.o, r.o+r.n)
    if w.ended and w.badGlyphs==0 and w.glyphs>=2 and w.length>=4 and w.length<=r.n and isFree(claimed, r.o, w.length):
      mark(claimed, r.o, w.length); add("ssLoose", w.length)

  # 12 fix3 single rec (min 1) bank C0-EF - too loose? count only
  var fix3s=0
  for r in freeRuns(claimed):
    if r.n < 3: continue
    # only full free runs that are exact multiples
    if r.n mod 3 != 0: continue
    let nRec=r.n div 3
    if nRec < 1: continue
    var banks=0
    for i in 0..<nRec:
      let b=g[r.o+i*3+2].int
      if b>=0xC0 and b<=0xEF: banks+=1
    if banks*2 >= nRec:  # ≥50% bank
      fix3s += r.n
  echo &"fix3 exact mult ≥50% bank (not claimed yet): {fix3s}"

  # 13 bank18 bit patterns: runs of only 00/01/80
  var b18=0; var b18n=0
  for r in freeRuns(claimed):
    if r.n < 4: continue
    var ok=true
    for j in 0..<r.n:
      if g[r.o+j] notin [0x00u8, 0x01u8, 0x80u8]: ok=false; break
    if ok:
      b18+=r.n; b18n+=1
  echo &"only-00/01/80 free ≥4: {b18} B / {b18n}"

  # remaining
  var rem=0; var rn=0
  for r in freeRuns(claimed):
    rem+=r.n; rn+=1

  echo "wave101 scout totals:"
  var keys: seq[string] = @[]
  for k in totals.keys: keys.add k
  keys.sort()
  var tot=0
  for k in keys:
    echo &"  {k}: {totals[k]}"
    tot += totals[k]
  echo &"  CLAIMABLE: {tot}"
  echo &"  residual after: {rem} B in {rn} runs"
  let exact = (3145728 - rem).float * 100.0 / 3145728.0
  echo &"  projected exact: {exact:.4f}%"

main()
