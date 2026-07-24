## Probe residual claimable under slightly relaxed but still structured gates.
import
  std/[strformat, tables, algorithm],
  ../decompbound/[rom_chunks, baserom_extract]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

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

proc sandwich(o, n: int): bool =
  (o > 0 and isCode[o - 1]) and (o + n < isCode.len and isCode[o + n])

# Gate A: far3 min1 (3B) free only lo!=0 C0-EF — wave already did min1?
var far1, far1sw = 0
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
        if sandwich(r.o + i, n): far1sw += n
        else: far1 += n
        mark(claimed, r.o + i, n)
      i = max(k, i + 1)
    else:
      i += 1
echo &"far3 streams remaining: non-sw {far1} sw {far1sw}"

# reload
claimed = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)

# Gate B: u8pair min2 @50%
var u8 = 0
for r in freeRuns(claimed):
  if r.n < 4 or r.n mod 2 != 0: continue
  let nrec = r.n div 2
  if nrec < 2: continue
  var low = 0
  for i in 0 ..< nrec:
    if g[r.o + i * 2] <= 0x50: low += 1
  if low.float / nrec.float >= 0.50:
    u8 += r.n
echo &"u8pair min2@50%: {u8}"

# Gate C: term single byte F0-FF whole free run n>=2, quality: last is term, body has >=1 non-term non-zero
var term = 0
for r in freeRuns(claimed):
  if r.n < 2: continue
  let t = g[r.o + r.n - 1]
  if t < 0xF0: continue
  var bodyNZ = 0
  var bodyTerm = 0
  for j in 0 ..< r.n - 1:
    if g[r.o + j] == t: bodyTerm += 1
    elif g[r.o + j] != 0: bodyNZ += 1
  if bodyNZ >= 1 and bodyTerm == 0:
    term += r.n
echo &"term F0-FF clean body n>=2: {term}"

# Gate D: aligned 4-byte words with hi byte 0 (CF program style) min 2 words
var w4 = 0
for r in freeRuns(claimed):
  if r.n < 8 or r.n mod 4 != 0: continue
  var ok = true
  for i in 0 ..< (r.n div 4):
    if g[r.o + i * 4 + 3] != 0: ok = false
  if ok:
    w4 += r.n
echo &"u32 hi0 words min2: {w4}"

# Gate E: 2-byte FF-terminated (xx FF) streams covering full free
var ff2 = 0
for r in freeRuns(claimed):
  if r.n < 2 or r.n mod 2 != 0: continue
  var ok = true
  for i in 0 ..< (r.n div 2):
    if g[r.o + i * 2 + 1] != 0xFF: ok = false
  if ok:
    ff2 += r.n
echo &"xxFF pairs full cover: {ff2}"

# Gate F: monotonic u16 bank-local (hi=0 or hi matches bank) min 4
var mono = 0
for r in freeRuns(claimed):
  if r.n < 8 or r.n mod 2 != 0: continue
  var ok = true
  var prev = -1
  for i in 0 ..< (r.n div 2):
    let v = g[r.o + i * 2].int or (g[r.o + i * 2 + 1].int shl 8)
    if prev >= 0 and v < prev: ok = false
    if v == 0 and i + 1 < r.n div 2: discard # holes ok?
    prev = v
  # require increasing mostly
  if ok:
    mono += r.n
echo &"u16 mono full free (loose): {mono}"

# Gate G: bytes only in 0x00-0x1F (control-plane / low data) n>=4
var loplane = 0
for r in freeRuns(claimed):
  if r.n < 4: continue
  var ok = true
  for j in 0 ..< r.n:
    if g[r.o + j] > 0x1F: ok = false
  if ok:
    loplane += r.n
echo &"loplane 00-1F n>=4: {loplane}"

# Gate H: alternating pattern ab ab ab
var alt = 0
for r in freeRuns(claimed):
  if r.n < 6 or r.n mod 2 != 0: continue
  let a = g[r.o]
  let b = g[r.o + 1]
  if a == b: continue
  var ok = true
  for i in 0 ..< (r.n div 2):
    if g[r.o + i * 2] != a or g[r.o + i * 2 + 1] != b: ok = false
  if ok:
    alt += r.n
echo &"strict ab-ab pairs: {alt}"

# residual free after marking far3/zero/const that wave105 already claimed — just report left
var left = 0
for r in freeRuns(claimed): left += r.n
echo &"free still {left}"
