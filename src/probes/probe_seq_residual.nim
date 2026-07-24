## Scout residual for EB-like music sequence bytecode and other dense packs.
import
  std/[algorithm, strformat, strutils, tables, sets],
  ../decompbound/[rom_chunks, baserom_extract, memmap]

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

# Hypothesized EB sequence operand widths (from audio.md + common N-SPC)
# Note values 0x01-0x7F = duration/rest payload alone? or note+duration?
# Conservative walker: high ops E0-FF with known arity; notes 80-C7 note-only;
# duration 00-7F as single-byte duration tokens between notes.

proc seqOpWidth(op: int): int =
  ## Operand bytes after op (not including op). -1 = unknown/stop.
  case op
  of 0xE0: 1   # instrument
  of 0xE1: 1   # volume
  of 0xE2: 2   # pan / portamento?
  of 0xE3: 1
  of 0xE4: 1
  of 0xE5: 2
  of 0xE6: 1
  of 0xE7: 1
  of 0xE8: 1   # tempo?
  of 0xE9: 2
  of 0xEA: 1
  of 0xEB: 2
  of 0xEC: 1
  of 0xED: 1
  of 0xEE: 2
  of 0xEF: 3   # call?
  of 0xF0: 0   # loop start?
  of 0xF1: 1
  of 0xF2: 1
  of 0xF3: 0
  of 0xF4: 1
  of 0xF5: 3
  of 0xF6: 0
  of 0xF7: 0
  of 0xF8: 1
  of 0xF9: 3
  of 0xFA: 1
  of 0xFB: 1
  of 0xFC: 0
  of 0xFD: 0
  of 0xFE: 0
  of 0xFF: 0   # end?
  else: -1

proc walkSeq(g: openArray[uint8]; start, limit: int): tuple[len, ops, notes, ends: int, ok: bool] =
  var pos = start
  var ops, notes = 0
  var ends = 0
  while pos < limit and ops < 500:
    let b = g[pos].int
    if b == 0x00:
      # track end
      pos += 1
      ends = 1
      break
    if b <= 0x7F:
      # duration / rest token
      pos += 1
      ops += 1
      continue
    if b >= 0x80 and b <= 0xC7:
      # note; optional following duration byte if next is low
      pos += 1
      notes += 1
      ops += 1
      if pos < limit and g[pos] <= 0x7F:
        pos += 1
      continue
    if b >= 0xC8 and b <= 0xDF:
      # tie/rest-ish single
      pos += 1
      ops += 1
      continue
    if b >= 0xE0:
      let w = seqOpWidth(b)
      if w < 0: break
      if pos + 1 + w > limit: break
      pos += 1 + w
      ops += 1
      if b == 0xFF:
        ends = 1
        break
      continue
    break
  let n = pos - start
  let ok = ends == 1 and ops >= 4 and notes >= 2 and n >= 8
  (n, ops, notes, ends, ok)

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
  var cm = claimed
  var seqTot = 0
  var seqN = 0
  for r in freeRuns(cm):
    if r.n < 8: continue
    for d in 0 ..< min(4, r.n):
      let w = walkSeq(g, r.o + d, r.o + r.n)
      if w.ok and w.len <= r.n - d:
        # quality: not too many high ops without notes
        if w.notes * 3 >= w.ops:  # notes majority-ish of tokens? looser: any
          discard
        echo &"  seq 0x{r.o+d:06X}+{w.len} ops={w.ops} notes={w.notes}"
        mark(cm, r.o + d, w.len)
        seqTot += w.len
        seqN += 1
        break
  echo &"# music-seq residual: {seqTot} B in {seqN} spans"

  # Also: residual "command+arg" pairs where first byte in small set
  # Pattern seen at 0x1B714F: 0C xx, 14 xx, 15 xx, 41 xx etc.
  var pairTot = 0
  var pairN = 0
  for r in freeRuns(cm):
    if r.n < 16 or r.n mod 2 != 0: continue
    # if even length and first-of-pair has low unique count
    let nPairs = r.n div 2
    var u: CountTable[int]
    for i in 0 ..< nPairs:
      u.inc(g[r.o + i*2].int)
    # require top opcodes cover ≥50% and top op count ≥3 distinct ops used ≥2
    var modes: seq[tuple[b,c: int]] = @[]
    for b, c in u:
      modes.add (b, c)
    modes.sort(proc(a,b: auto): int = cmp(b.c, a.c))
    if modes.len < 2: continue
    let topCover = modes[0].c + (if modes.len > 1: modes[1].c else: 0) +
      (if modes.len > 2: modes[2].c else: 0)
    if topCover * 2 < nPairs: continue
    if modes[0].c < 3: continue
    # reject if looks like text (many printable)
    var print = 0
    for j in 0..<r.n:
      if g[r.o+j] >= 0x20 and g[r.o+j] < 0x7F: print += 1
    if print * 2 > r.n: continue
    echo &"  cmdPair 0x{r.o:06X}+{r.n} top={modes[0].b:02X}:{modes[0].c}"
    mark(cm, r.o, r.n)
    pairTot += r.n
    pairN += 1
  echo &"# cmdPair residual: {pairTot} B in {pairN} spans"

  # HDMA-like: repeating  N-byte lines with first byte small (line count) or
  # pattern XX YY ZZ where XX is channel-ish
  var hdmaTot = 0
  for r in freeRuns(cm):
    if r.n < 24: continue
    for stride in [4, 5, 6]:
      if r.n < stride * 4: continue
      let nRec = r.n div stride
      # first byte often 0x00-0x80 and somewhat repeating
      var small0 = 0
      for i in 0 ..< nRec:
        if g[r.o + i*stride] <= 0x80: small0 += 1
      if small0 * 5 < nRec * 4: continue
      # last bytes bank-ish or mid-range
      let n = nRec * stride
      mark(cm, r.o, n)
      hdmaTot += n
      echo &"  hdma{stride} 0x{r.o:06X}+{n}"
      break
  echo &"# hdma-like: {hdmaTot} B"

  var rem = 0
  for r in freeRuns(cm): rem += r.n
  echo &"claimed seq+pair+hdma; left {rem}"

main()
