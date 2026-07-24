import std/[strformat, tables, algorithm],
  ../decompbound/[rom_chunks, baserom_extract, action_script, text_decode]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len: return false
  for j in 0 ..< n:
    if claimed[o + j]: return false
  true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  var rs = -1
  var rl = 0
  for o in 0 ..< claimed.len:
    if not claimed[o]:
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

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
var isCode = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
  if c.kind == ckImplementedCode:
    for i in c.offset ..< min(c.offset + c.length, isCode.len):
      isCode[i] = true

var free = 0
var bankFree: CountTable[int]
for r in freeRuns(claimed):
  free += r.n
  bankFree.inc(r.o shr 16, r.n)
echo &"free total {free}"
echo "by bank:"
var bk: seq[int]
for k in bankFree.keys: bk.add k
bk.sort()
for k in bk:
  echo &"  file@0x{k:02X} SNES ${k + 0xC0:02X}: {bankFree[k]} B"

# FF-terminated complete free runs L2..16
var ff = 0
var ffN = 0
for r in freeRuns(claimed):
  if r.n < 2: continue
  var i = 0
  var good = 0
  while i < r.n:
    var j = i
    while j < r.n and g[r.o + j] != 0xFF: j += 1
    if j >= r.n: break
    let L = j - i + 1
    if L >= 2 and L <= 16:
      good += L
      i = j + 1
    else:
      break
  if good >= 4 and good == r.n:
    ff += r.n
    ffN += 1
echo &"full FF-rec free runs: {ff} B / {ffN}"

# far3 remaining (min 1 ptr = 3B) with lo!=0 bank C0-EF
var farB = 0
var farN = 0
for r in freeRuns(claimed):
  var i = 0
  while i + 3 <= r.n:
    let lo = g[r.o + i].int or (g[r.o + i + 1].int shl 8)
    let b = g[r.o + i + 2]
    if b >= 0xC0 and b <= 0xEF and lo != 0:
      var k = i
      while k + 3 <= r.n:
        let lo2 = g[r.o + k].int or (g[r.o + k + 1].int shl 8)
        let b2 = g[r.o + k + 2]
        if not (b2 >= 0xC0 and b2 <= 0xEF and lo2 != 0): break
        k += 3
      let n = k - i
      if n >= 3:
        farB += n
        farN += 1
      i = max(k, i + 1)
    else:
      i += 1
echo &"far3 residual streams: {farB} B / {farN} streams"

# term F0-FF singles quality
var termB = 0
for r in freeRuns(claimed):
  if r.n < 2: continue
  let t = g[r.o + r.n - 1]
  if t < 0xF0: continue
  # majority not equal terminator, has non-zero
  var nz = 0
  var same = 0
  for j in 0 ..< r.n:
    if g[r.o + j] != 0: nz += 1
    if g[r.o + j] == t: same += 1
  if nz >= 2 and same <= r.n div 2 + 1:
    termB += r.n
echo &"term F0-FF free runs (loose): {termB} B"

# u8 pairs 55% lo<=0x50 min3
var u8b = 0
for r in freeRuns(claimed):
  if r.n < 6 or r.n mod 2 != 0: continue
  let nrec = r.n div 2
  if nrec < 3: continue
  var low = 0
  for i in 0 ..< nrec:
    if g[r.o + i * 2] <= 0x50: low += 1
  if low.float / nrec.float >= 0.55:
    u8b += r.n
echo &"u8pair min3@55% free: {u8b} B"

# bit-mask-like: only 0/1/2/4/8/10/20/40/80
var bitB = 0
for r in freeRuns(claimed):
  if r.n < 4: continue
  var ok = true
  for j in 0 ..< r.n:
    let v = g[r.o + j]
    if v notin [0u8, 1, 2, 4, 8, 16, 32, 64, 128]:
      ok = false
      break
  if ok:
    bitB += r.n
echo &"bitmask power-of-2 free n>=4: {bitB} B"

# const fill free n>=1 already drained for zero; const other
var constB = 0
for r in freeRuns(claimed):
  if r.n < 2: continue
  let v = g[r.o]
  var ok = true
  for j in 1 ..< r.n:
    if g[r.o + j] != v: ok = false
  if ok:
    constB += r.n
echo &"const fill n>=2: {constB} B"

# zero n>=1
var zB = 0
for r in freeRuns(claimed):
  var ok = true
  for j in 0 ..< r.n:
    if g[r.o + j] != 0: ok = false
  if ok:
    zB += r.n
echo &"zero free: {zB} B"

# script / AS
var ssB = 0
var asB = 0
for r in freeRuns(claimed):
  if r.n >= 6:
    let w = walkScriptStream(g, r.o, r.n)
    if w.len > 0 and isClaimableScriptStream(w) and isFree(claimed, r.o, w.len):
      ssB += w.len
    let a = walkActionScript(g, r.o, r.n)
    if a.len >= 6 and isClaimableActionScript(a) and isFree(claimed, r.o, a.len):
      asB += a.len
echo &"SS claimable: {ssB}; AS claimable: {asB}"

# 12-byte rec with far at +9 bank C6-C9
var r12 = 0
for r in freeRuns(claimed):
  if r.n < 12: continue
  var i = 0
  while i + 12 <= r.n:
    let b = g[r.o + i + 11]
    let lo = g[r.o + i + 9].int or (g[r.o + i + 10].int shl 8)
    let t0 = g[r.o + i]
    if b >= 0xC6 and b <= 0xC9 and lo != 0 and t0 <= 3:
      r12 += 12
      i += 12
    else:
      i += 1
echo &"cfObj12-like residual: {r12} B"

# tiny free
var s1, s2, s3, s4 = 0
for r in freeRuns(claimed):
  case r.n
  of 1: s1 += 1
  of 2: s2 += 1
  of 3: s3 += 1
  of 4: s4 += 1
  else: discard
echo &"tiny runs: 1={s1} 2={s2} 3={s3} 4={s4}"

# Look at largest free non-sandwich
type Run = tuple[n, o: int]
var tops: seq[Run]
for r in freeRuns(claimed):
  tops.add (r.n, r.o)
tops.sort(proc(a, b: Run): int = cmp(b.n, a.n))
echo "top free runs:"
for i, t in tops:
  if i >= 25: break
  let sandwich = t.o > 0 and isCode[t.o - 1] and t.o + t.n < isCode.len and isCode[t.o + t.n]
  var hx = ""
  for j in 0 ..< min(16, t.n):
    hx.add &"{g[t.o + j]:02X} "
  echo &"  0x{t.o:06X}+{t.n} sw={sandwich} {hx}"
