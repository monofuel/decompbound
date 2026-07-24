## Validate sequence-like residual gates; tune for quality vs bulk.
import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, memmap, action_script]

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

  type Gate = object
    name: string
    needE0xx, needNotes, needE0, densNum, densDen, minN: int
  let gates = @[
    Gate(name: "loose", needE0xx: 1, needNotes: 4, needE0: 2, densNum: 1, densDen: 4, minN: 12),
    Gate(name: "mid", needE0xx: 2, needNotes: 6, needE0: 3, densNum: 1, densDen: 3, minN: 16),
    Gate(name: "tight", needE0xx: 3, needNotes: 8, needE0: 4, densNum: 1, densDen: 2, minN: 20),
    Gate(name: "e0strong", needE0xx: 2, needNotes: 4, needE0: 2, densNum: 1, densDen: 5, minN: 12),
    Gate(name: "e0mid", needE0xx: 2, needNotes: 5, needE0: 3, densNum: 1, densDen: 4, minN: 16),
  ]
  for gate in gates:
    var cm = claimed
    var tot = 0
    var nsp = 0
    for r in freeRuns(cm):
      if r.n < gate.minN: continue
      var e0, notes, z, e0xx = 0
      for j in 0..<r.n:
        let b = g[r.o+j].int
        if b == 0: z += 1
        elif b >= 0x80 and b <= 0xC7: notes += 1
        elif b >= 0xE0:
          e0 += 1
          if b == 0xE0 and j + 1 < r.n and g[r.o+j+1] < 0x40: e0xx += 1
      let dens = notes + e0
      if e0xx >= gate.needE0xx and notes >= gate.needNotes and e0 >= gate.needE0 and
          z * 8 <= r.n and dens * gate.densDen >= r.n * gate.densNum:
        mark(cm, r.o, r.n)
        tot += r.n
        nsp += 1
    echo &"{gate.name}: {tot} B in {nsp} spans"

  # combined wave
  block:
    var cm = claimed
    var tot = 0
    var parts: Table[string, int]
    proc add(k: string; n: int) =
      if k notin parts: parts[k] = 0
      parts[k] = parts[k] + n
      tot += n

    # FE multi+single
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
          if fe==recs and fe*3<=n*2:
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

    # mid sequence residual
    for r in freeRuns(cm):
      if r.n < 16: continue
      var e0, notes, z, e0xx = 0
      for j in 0..<r.n:
        let b = g[r.o+j].int
        if b == 0: z += 1
        elif b >= 0x80 and b <= 0xC7: notes += 1
        elif b >= 0xE0:
          e0 += 1
          if b == 0xE0 and j+1 < r.n and g[r.o+j+1] < 0x40: e0xx += 1
      if e0xx >= 2 and notes >= 6 and e0 >= 3 and z*8 <= r.n and (notes+e0)*3 >= r.n:
        mark(cm, r.o, r.n); add("seqMid", r.n)

    # plane 50%
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
          mark(cm, r.o, np*2); add("plane50", np*2)

    # far3≥3
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

    # far4
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

    # u16mono≥6
    for r in freeRuns(cm):
      var i=0
      while i+12 <= r.n:
        let base=r.o+i
        var cnt=1
        var prev=g[base].int or (g[base+1].int shl 8)
        var j=2
        while i+j+2 <= r.n:
          let v=g[base+j].int or (g[base+j+1].int shl 8)
          if v < prev: break
          prev=v; cnt+=1; j+=2
        if cnt>=6 and prev>=0x100:
          mark(cm, base, cnt*2); add("u16", cnt*2); i += cnt*2
        else: i += 2

    # cmd pair
    for r in freeRuns(cm):
      if r.n < 24 or r.n mod 2 != 0: continue
      let np = r.n div 2
      var u: CountTable[int]
      for i in 0..<np: u.inc(g[r.o+i*2].int)
      var top: seq[tuple[b,c:int]] = @[]
      for b,c in u.pairs: top.add (b,c)
      top.sort(proc(a,b: auto): int = cmp(b.c, a.c))
      if top.len < 3: continue
      if top[0].c+top[1].c+top[2].c < np div 2: continue
      if top[0].c < 4: continue
      if u.len * 2 > np: continue
      mark(cm, r.o, r.n); add("cmd", r.n)

    # AS minLen=4 minSig=0 with ended walks, require overall sig≥1 for spans ≥8
    for r in freeRuns(cm):
      if r.n < 4: continue
      var pos = r.o
      var taken = 0
      while pos < r.o + r.n:
        let w = walkActionScript(g, pos, r.o + r.n)
        if w.ended and w.length >= 4 and w.ops >= 1 and pos + w.length <= r.o + r.n:
          taken += w.length
          pos += w.length
        else:
          break
      if taken >= 4:
        let sig = countSignatureBytes(g, r.o, taken)
        if taken >= 8 and sig < 1: continue
        mark(cm, r.o, taken); add("as4", taken)

    # zRec≥2, fd multi, w4, const, zero - quick
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

    for r in freeRuns(cm):
      if r.n < 2: continue
      var allZ=true
      for j in 0..<r.n:
        if g[r.o+j]!=0: allZ=false
      if allZ: mark(cm, r.o, r.n); add("zero", r.n)

    echo &"COMBINED: {tot} B (~+{tot.float*100/3145728:.2f}% → {97.0+tot.float*100/3145728:.2f}%)"
    var keys = newSeq[string]()
    for k in parts.keys: keys.add k
    keys.sort()
    for k in keys:
      echo &"  {k}: {parts[k]}"

main()
