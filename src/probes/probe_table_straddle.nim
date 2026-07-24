## Find free residual incomplete of known fixed-width records completed by
## 1-4 B of adjacent inventory-code (right-extend only).
import
  std/[strformat, strutils, tables, algorithm],
  ../decompbound/[rom_chunks, baserom_extract]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
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
  var isCode = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset + c.length, isCode.len): isCode[i] = true

  var nHits = 0
  var freeGain = 0
  var byFam: CountTable[string]
  for r in freeRuns(claimed):
    if r.n < 1 or r.n > 40: continue
    for right in 1..4:
      let endp = r.o + r.n + right
      if endp > g.len: continue
      var okSide = true
      for i in r.o + r.n ..< endp:
        if not isCode[i]: okSide = false
      if not okSide: continue
      let n = endp - r.o
      # skip if free alone already packs as complete recs of same family
      var fam = ""
      # cfRec5
      if n >= 5 and n mod 5 == 0:
        var ok = true
        var p = r.o
        while p + 5 <= endp:
          if not (g[p]==0x0A and g[p+1]==0x01 and g[p+2]==0x00 and g[p+3]==0x80):
            ok = false; break
          p += 5
        if ok and p == endp and r.n mod 5 != 0:
          fam = "cfRec5"
      # obj12
      if fam.len == 0 and n == 12 and r.n < 12:
        let t = g[r.o]
        let b = g[r.o + 11]
        if t <= 3'u8 and b >= 0xC6 and b <= 0xC9:
          fam = "obj12"
      # far3 free-majority multi or free=2 + bank
      if fam.len == 0 and n >= 3 and n mod 3 == 0 and r.n * 2 >= n and r.n mod 3 != 0:
        var ok = true
        var p = r.o
        while p + 3 <= endp:
          let lo = g[p].int or (g[p+1].int shl 8)
          let b = g[p+2]
          if b < 0xC0 or b > 0xEF or lo == 0: ok = false; break
          p += 3
        if ok and p == endp:
          if g[r.o] notin [0x20'u8, 0x22, 0x5C, 0x4C, 0x60, 0x6B]:
            fam = "far3"
      if fam.len == 0: continue
      nHits += 1
      freeGain += r.n
      byFam.inc fam
      if nHits <= 40:
        var hx = ""
        for i in 0 ..< min(n, 20):
          if i > 0: hx.add " "
          hx.add &"{g[r.o+i]:02X}"
        echo &"  {fam} 0x{r.o:06X}+{r.n}+R{right} n={n}: {hx}"
      break

  echo &"hits={nHits} freeGain={freeGain}"
  for k,v in byFam.pairs:
    echo &"  {k}: {v}"

main()
