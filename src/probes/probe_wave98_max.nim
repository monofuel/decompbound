## Max honest residual estimate for 98%.
import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, memmap, action_script, text_decode]

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
  var inv = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)
      mark(inv, c.offset, c.length)
  var cm = claimed
  var tot = 0
  var parts: Table[string, int]
  proc add(k: string; n: int) =
    if k notin parts: parts[k] = 0
    parts[k] = parts[k] + n
    tot += n

  # 1 fe multi+single
  block:
    var o = 0
    while o < g.len:
      if cm[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not cm[pos]:
        var k = pos
        while k < g.len and not cm[k] and g[k] != 0xFE and (k-pos) < 32: k += 1
        if k >= g.len or cm[k] or g[k] != 0xFE: break
        if k-pos+1 < 2: break
        recs += 1; pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var fe=0
        for j in 0..<n:
          if g[start+j]==0xFE: fe+=1
        if fe==recs and fe*3<=n*2 and fe < n:
          mark(cm, start, n); add("fe", n); o = pos; continue
      o += 1
    o = 0
    while o < g.len:
      if cm[o]: o += 1; continue
      var k = o
      while k < g.len and not cm[k] and g[k] != 0xFE and (k-o) < 32: k += 1
      if k < g.len and not cm[k] and g[k] == 0xFE:
        let n = k - o + 1
        if n >= 3:
          var fe,hi,z=0
          for j in 0..<n:
            if g[o+j]==0xFE: fe+=1
            if g[o+j]>=0xE0: hi+=1
            if g[o+j]==0: z+=1
          if fe==1 and hi*2<=n and z*3<=n:
            mark(cm, o, n); add("fe", n); o = k+1; continue
      o += 1

  # 2 fd multi
  block:
    var o = 0
    while o < g.len:
      if cm[o]: o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not cm[pos]:
        var k = pos
        while k < g.len and not cm[k] and g[k] != 0xFD and (k-pos) < 32: k += 1
        if k >= g.len or cm[k] or g[k] != 0xFD: break
        if k-pos+1 < 2: break
        recs += 1; pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4:
        var fd=0
        for j in 0..<n:
          if g[start+j]==0xFD: fd+=1
        if fd==recs and fd*3<=n*2 and fd < n:
          mark(cm, start, n); add("fd", n); o = pos; continue
      o += 1

  # 3 loose sequence (E0 instrument signal)
  for r in freeRuns(cm):
    if r.n < 12: continue
    var e0, notes, z, e0xx = 0
    for j in 0..<r.n:
      let b = g[r.o+j].int
      if b == 0: z += 1
      elif b >= 0x80 and b <= 0xC7: notes += 1
      elif b >= 0xE0:
        e0 += 1
        if b == 0xE0 and j+1 < r.n and g[r.o+j+1] < 0x40: e0xx += 1
    if e0xx >= 1 and notes >= 4 and e0 >= 2 and z*8 <= r.n and (notes+e0)*4 >= r.n:
      mark(cm, r.o, r.n); add("seq", r.n)

  # 4 plane 50%
  for r in freeRuns(cm):
    if r.n < 24: continue
    let np = r.n div 2
    var p = 0
    for i in 0..<np:
      if g[r.o+i*2]==g[r.o+i*2+1]: p += 1
    if p.float/np.float >= 0.50:
      var any,ff=0
      for j in 0..<r.n:
        if g[r.o+j]!=0: any+=1
        if g[r.o+j]==0xFF: ff+=1
      if any>0 and ff*4 < r.n:
        mark(cm, r.o, np*2); add("plane", np*2)

  # 5 far3/far4
  for r in freeRuns(cm):
    var p = r.o
    while p+9 <= r.o+r.n:
      var q=p; var good=0
      while q+3 <= r.o+r.n:
        let bk=g[q+2].int
        if bk < 0xC0 or bk > 0xEF: break
        good += 1; q += 3
      if good >= 3:
        mark(cm, p, good*3); add("far3", good*3); p = q
      else: p += 1
  for r in freeRuns(cm):
    var p = r.o
    while p+12 <= r.o+r.n:
      var q=p; var good=0
      while q+4 <= r.o+r.n:
        let bk=g[q+2].int
        if bk < 0xC0 or bk > 0xEF or g[q+3]!=0: break
        good += 1; q += 4
      if good >= 3:
        mark(cm, p, good*4); add("far4", good*4); p = q
      else: p += 1

  # 6 u16mono ≥4 (looser)
  for r in freeRuns(cm):
    var i=0
    while i+8 <= r.n:
      let base=r.o+i
      var cnt=1
      var prev=g[base].int or (g[base+1].int shl 8)
      var j=2
      while i+j+2 <= r.n:
        let v=g[base+j].int or (g[base+j+1].int shl 8)
        if v < prev: break
        if v==0 and prev==0: break
        prev=v; cnt+=1; j+=2
      if cnt>=4 and prev>=0x80:
        mark(cm, base, cnt*2); add("u16", cnt*2); i += cnt*2
      else: i += 2

  # 7 cmd pair looser: top3 cover ≥35%, min 16, top c≥3
  for r in freeRuns(cm):
    if r.n < 16 or r.n mod 2 != 0: continue
    let np = r.n div 2
    var u: CountTable[int]
    for i in 0..<np: u.inc(g[r.o+i*2].int)
    var top: seq[tuple[b,c:int]] = @[]
    for b,c in u.pairs: top.add (b,c)
    top.sort(proc(a,b: auto): int = cmp(b.c, a.c))
    if top.len < 2: continue
    var cover = top[0].c
    if top.len > 1: cover += top[1].c
    if top.len > 2: cover += top[2].c
    if cover * 100 < np * 35: continue
    if top[0].c < 3: continue
    if u.len > np: continue  # very loose unique
    var pr=0
    for j in 0..<r.n:
      if g[r.o+j]>=0x20 and g[r.o+j]<0x7F: pr+=1
    if pr*2 > r.n: continue
    mark(cm, r.o, r.n); add("cmd", r.n)

  # 8 AS minLen=4 minSig=0, sig density for long
  for r in freeRuns(cm):
    if r.n < 4: continue
    var pos = r.o
    var taken = 0
    while pos < r.o + r.n:
      let w = walkActionScript(g, pos, r.o + r.n)
      if w.ended and w.length >= 4 and w.ops >= 1 and pos + w.length <= r.o + r.n:
        taken += w.length
        pos += w.length
      else: break
    if taken >= 4:
      if taken >= 10 and countSignatureBytes(g, r.o, taken) < 1: continue
      mark(cm, r.o, taken); add("as", taken)

  # 9 asPrefix cross-boundary as table (not AS kind)
  for r in freeRuns(cm):
    if r.n < 4: continue
    if r.o + r.n >= g.len or not inv[r.o + r.n]: continue
    let wFree = walkActionScript(g, r.o, r.o + r.n)
    if wFree.ended or wFree.length != r.n or wFree.ops < 1: continue
    let wFull = walkActionScript(g, r.o, min(r.o + r.n + 64, g.len))
    if not wFull.ended or wFull.length <= r.n or wFull.sig < 1: continue
    mark(cm, r.o, r.n); add("asPref", r.n)

  # 10 ss + ssPrefix
  for r in freeRuns(cm):
    if r.n < ScriptStreamMinLen: continue
    let c = consumeScriptStreamRun(g, r.o, r.n)
    if c >= ScriptStreamMinLen:
      mark(cm, r.o, c); add("ss", c)
  for r in freeRuns(cm):
    if r.n < ScriptStreamMinLen: continue
    let wFree = walkScriptStream(g, r.o, r.o + r.n)
    if wFree.badGlyphs != 0 or wFree.ended or wFree.length != r.n: continue
    if wFree.glyphs < ScriptStreamMinGlyphs: continue
    let totTok = wFree.glyphs + wFree.controls
    if totTok == 0 or wFree.glyphs.float/totTok.float < ScriptStreamMinGlyphRatio: continue
    if r.o + r.n >= g.len or not inv[r.o + r.n]: continue
    let wFull = walkScriptStream(g, r.o, min(r.o + ScriptStreamMaxLen, g.len))
    if not isGoodScriptStream(wFull) or wFull.length <= r.n: continue
    mark(cm, r.o, r.n); add("ssPref", r.n)

  # 11 zRec ≥2
  block:
    var o = 0
    while o < g.len:
      if cm[o]: o += 1; continue
      let start=o
      var pos=o
      var recs=0
      while pos < g.len and not cm[pos]:
        var k=pos
        while k < g.len and not cm[k] and g[k]!=0 and (k-pos)<16: k+=1
        if k>=g.len or cm[k] or g[k]!=0: break
        if k-pos+1 < 2: break
        recs+=1; pos=k+1
      let n=pos-start
      if recs>=2 and n>=4:
        var zeros,hi,pr=0
        for j in 0..<n:
          if g[start+j]==0: zeros+=1
          if g[start+j]>=0x80: hi+=1
          if g[start+j]>=0x20 and g[start+j]<0x7F: pr+=1
        if zeros==recs and hi*3<=n and pr*2>=n:
          mark(cm, start, n); add("zRec", n); o=pos; continue
      o+=1

  # 12 w4hi0 ≥2
  for r in freeRuns(cm):
    if r.n < 8 or r.n mod 4 != 0: continue
    let words = r.n div 4
    if words < 2: continue
    var zhi=0
    for i in 0..<words:
      if g[r.o+i*4+3]==0: zhi+=1
    if zhi==words:
      var any=false
      for j in 0..<r.n:
        if g[r.o+j]!=0: any=true
      if any: mark(cm, r.o, r.n); add("w4", r.n)

  # 13 const fill ≥4
  for r in freeRuns(cm):
    if r.n < 4: continue
    let v = g[r.o]
    if v == 0: continue
    var all=true
    for j in 1..<r.n:
      if g[r.o+j]!=v: all=false
    if all: mark(cm, r.o, r.n); add("const", r.n)

  # 14 zero ≥2
  for r in freeRuns(cm):
    if r.n < 2: continue
    var allZ=true
    for j in 0..<r.n:
      if g[r.o+j]!=0: allZ=false
    if allZ: mark(cm, r.o, r.n); add("zero", r.n)

  # 15 fixed rec with bankish/zeroish high field ≥70%
  for r in freeRuns(cm):
    if r.n < 40: continue
    var best = 0
    for sz in [5, 6, 7, 8, 9, 10, 12, 14, 16, 17]:
      if r.n < sz * 4: continue
      let nRec = r.n div sz
      var bankish, zeroish = 0
      for i in 0..<nRec:
        let b = g[r.o + i*sz + sz - 1]
        if b >= 0xC0 and b <= 0xEF: bankish += 1
        if b == 0: zeroish += 1
      if max(bankish, zeroish) * 10 >= nRec * 7:
        best = max(best, nRec * sz)
    if best >= 40:
      mark(cm, r.o, best); add("fix", best)

  # 16 residual runs that are mostly (≥70%) bytes in 0x00-0x1F and 0x80-0x9F
  # (control+note density without requiring E0)
  for r in freeRuns(cm):
    if r.n < 20: continue
    var hit = 0
    for j in 0..<r.n:
      let b = g[r.o+j]
      if b <= 0x1F or (b >= 0x80 and b <= 0x9F): hit += 1
    if hit * 10 >= r.n * 7:
      mark(cm, r.o, r.n); add("ctrlNote", r.n)

  echo &"MAX: {tot} B (~+{tot.float*100/3145728:.2f}% → {97.0+tot.float*100/3145728:.2f}%)"
  var rem = 0
  for r in freeRuns(cm): rem += r.n
  echo &"left: {rem}"
  var keys = newSeq[string]()
  for k in parts.keys: keys.add k
  keys.sort()
  for k in keys:
    echo &"  {k}: {parts[k]}"

main()
