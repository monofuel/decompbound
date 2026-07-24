## Free residual 1-19 B that completes into adjacent code (1-4 B) matching
## the fixed width of a neighboring meta extract of the same family pattern.
import
  std/[strformat, strutils, tables, algorithm],
  ../decompbound/[rom_chunks, baserom_extract]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len:
      c[o + j] = true

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
  var isMeta = newSeq[bool](g.len)
  # map offset -> extract span for meta neighbors
  var metaAt = newSeq[int](g.len)  # index+1 into extracts or 0
  let extracts = allBaseromExtractSpans()
  for i, s in extracts:
    for j in 0 ..< s.length:
      if s.offset + j < metaAt.len:
        metaAt[s.offset + j] = i + 1
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset + c.length, isCode.len): isCode[i] = true
    if c.kind == ckImplementedMeta:
      for i in c.offset ..< min(c.offset + c.length, isMeta.len): isMeta[i] = true

  # Known fixed record sizes from family name prefixes
  proc recSize(name: string): int =
    if name.contains("cfRec5") or name.contains("ceRec5") or name.contains("ce5"): return 5
    if name.contains("far3"): return 3
    if name.contains("far4") or name.contains("fix4") or name.contains("w4hi0"): return 4
    if name.contains("u8pair"): return 2
    if name.contains("bitFlag"): return 1
    if name.contains("obj12"): return 12
    if name.contains("prog4"): return 4
    if name.contains("Hdma6") or name.contains("hdma6"): return 6
    if name.contains("Rec4FF") or name.contains("rec4"): return 4
    0

  var hits = 0
  var freeGain = 0
  for r in freeRuns(claimed):
    if r.n > 19: continue
    # right code extension 1-4
    for right in 1..4:
      let endp = r.o + r.n + right
      if endp > g.len: break
      var ok = true
      for i in r.o + r.n ..< endp:
        if not isCode[i]: ok = false
      if not ok: break
      # neighbor meta just before free?
      if r.o > 0 and isMeta[r.o - 1]:
        let idx = metaAt[r.o - 1] - 1
        if idx >= 0:
          let s = extracts[idx]
          let rs = recSize(s.name)
          if rs > 0:
            let n = r.n + right
            if n mod rs == 0 and n >= rs:
              # for cfRec5 check pattern
              var good = true
              if rs == 5 and s.name.contains("cfRec5"):
                var p = r.o
                # may need align - try start at free or back into... only free start
                # actually free may start mid-table aligned to neighbor end
                if (r.o - s.offset) mod rs != 0:
                  # try if free itself packs
                  p = r.o
                if (endp - r.o) mod rs != 0: good = false
                else:
                  p = r.o
                  while p + rs <= endp and good:
                    if not (g[p]==0x0A and g[p+1]==0x01 and g[p+2]==0x00 and g[p+3]==0x80):
                      good = false
                    p += rs
              if good:
                hits += 1
                freeGain += r.n
                if hits <= 40:
                  echo &"  neigh {s.name} free 0x{r.o:06X}+{r.n} +R{right} => claim +{n} rs={rs}"
    # also free that is incomplete of pattern without neighbor (cfRec5 only)
  echo &"neighbor-complete hits={hits} freeGain={freeGain}"

  # Global: free runs where free+R packs as exact cfRec5 and neighbors are cfRec5 meta or code
  hits = 0; freeGain = 0
  for r in freeRuns(claimed):
    for right in 1..4:
      let endp = r.o + r.n + right
      if endp > g.len: continue
      var ok = true
      for i in r.o+r.n ..< endp:
        if not isCode[i]: ok = false
      if not ok: continue
      if (endp - r.o) mod 5 != 0 or endp - r.o < 5: continue
      var p = r.o
      var good = true
      while p + 5 <= endp:
        if not (g[p]==0x0A and g[p+1]==0x01 and g[p+2]==0x00 and g[p+3]==0x80):
          good = false; break
        p += 5
      if good and p == endp:
        hits += 1; freeGain += r.n
        echo &"  cfRec5 free 0x{r.o:06X}+{r.n}+R{right}"
  echo &"cfRec5 right-complete={hits} free={freeGain}"

main()
