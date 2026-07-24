## How much residual AS if MinLen/MinSig lowered; other bulk packs.
import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, action_script, text_decode, memmap]

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

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len: return false
  for j in 0 ..< n:
    if claimed[o + j]: return false
  true

proc goodAs(w: ActionScriptWalk; minLen, minSig, minOps: int): bool =
  w.ended and w.length >= minLen and w.ops >= minOps and w.sig >= minSig

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)

  for minLen in [6, 4, 3]:
    for minSig in [1, 0]:
      var cm = claimed
      var tot = 0
      var n = 0
      for r in freeRuns(cm):
        if r.n < minLen: continue
        var pos = r.o
        var taken = 0
        while pos < r.o + r.n:
          let w = walkActionScript(g, pos, r.o + r.n)
          if goodAs(w, minLen, minSig, 1) and pos + w.length <= r.o + r.n:
            taken += w.length
            pos += w.length
          else:
            break
        if taken >= minLen and isFree(cm, r.o, taken):
          # also require sig density for minSig=0 spans
          if minSig == 0 and countSignatureBytes(g, r.o, taken) < 1 and taken >= 8:
            # allow short no-sig only if tiny
            if taken > 12: continue
          mark(cm, r.o, taken)
          tot += taken
          n += 1
      echo &"AS minLen={minLen} minSig={minSig}: {tot} B in {n} spans"

  # plane pair ratios
  for ratio in [0.50, 0.55, 0.60, 0.70]:
    var cm = claimed
    var tot = 0
    for r in freeRuns(cm):
      if r.n < 24: continue
      let np = r.n div 2
      var p = 0
      for i in 0..<np:
        if g[r.o+i*2] == g[r.o+i*2+1]: p += 1
      if p.float / np.float >= ratio:
        var any, ff = 0
        for j in 0..<r.n:
          if g[r.o+j] != 0: any += 1
          if g[r.o+j] == 0xFF: ff += 1
        if any > 0 and ff * 4 < r.n:
          let n = np * 2
          mark(cm, r.o, n)
          tot += n
    echo &"planePair ratio>={ratio:.2f}: {tot} B"

  # cmd streams: free runs where ≥35% of even-index bytes are in a small opcode set
  # derived from top residual DB island common ops
  var cm = claimed
  var cmdTot = 0
  for r in freeRuns(cm):
    if r.n < 20 or r.n mod 2 != 0: continue
    let np = r.n div 2
    var u: CountTable[int]
    for i in 0..<np: u.inc(g[r.o + i*2].int)
    var modes: seq[int] = @[]
    for b, c in u.pairs:
      if c >= 2: modes.add c
    modes.sort(proc(a,b: int): int = cmp(b,a))
    var cover = 0
    for i in 0 ..< min(5, modes.len): cover += modes[i]
    # rebuild top ops
    var topOps: seq[tuple[b,c:int]] = @[]
    for b, c in u.pairs: topOps.add (b,c)
    topOps.sort(proc(a,b: auto): int = cmp(b.c, a.c))
    if topOps.len < 3: continue
    let top3 = topOps[0].c + topOps[1].c + topOps[2].c
    if top3 * 100 < np * 40: continue  # top3 cover ≥40%
    if topOps[0].c < 3: continue
    # reject high printable ASCII
    var pr = 0
    for j in 0..<r.n:
      if g[r.o+j] >= 0x20 and g[r.o+j] < 0x7F: pr += 1
    if pr * 2 > r.n: continue
    # reject if looks like pure far ptrs
    mark(cm, r.o, r.n)
    cmdTot += r.n
  echo &"cmdPair40: {cmdTot} B"

  # N-SPC-ish: free runs with many E0-FF control ops interleaved with notes
  cm = claimed
  var spc = 0
  for r in freeRuns(cm):
    if r.n < 16: continue
    var e0, notes, z = 0
    for j in 0..<r.n:
      let b = g[r.o+j]
      if b >= 0xE0: e0 += 1
      if b >= 0x80 and b < 0xC8: notes += 1
      if b == 0: z += 1
    if e0 >= 3 and notes >= 4 and e0 + notes >= r.n div 4 and z * 8 <= r.n:
      mark(cm, r.o, r.n)
      spc += r.n
  echo &"spcish: {spc} B"

  # fixed rec size with stable high byte field (bank or zero)
  cm = claimed
  var fix = 0
  for r in freeRuns(cm):
    if r.n < 40: continue
    var best = 0
    for sz in [5, 6, 7, 8, 9, 10, 12, 14, 16, 17, 20, 25, 27]:
      if r.n < sz * 4: continue
      let nRec = r.n div sz
      var bankish, zeroish = 0
      for i in 0..<nRec:
        let b = g[r.o + i*sz + sz - 1]
        if b >= 0xC0 and b <= 0xEF: bankish += 1
        if b == 0: zeroish += 1
        let b2 = g[r.o + i*sz + sz - 2]
        if b2 == 0: zeroish += 1
      let score = max(bankish, zeroish)
      if score * 5 >= nRec * 4 and nRec * sz > best:
        best = nRec * sz
    if best >= 40:
      mark(cm, r.o, best)
      fix += best
  echo &"fixedRec: {fix} B"

main()
