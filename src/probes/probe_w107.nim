## Wave107 residual probe: expand known structure gates + CE62EE pure-code reclass.
import
  std/[strformat, tables, algorithm, sequtils],
  ../decompbound/[rom_chunks, baserom_extract]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  var rs = -1
  var rl = 0
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

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
var isCode = newSeq[bool](g.len)
var isMeta = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
  if c.kind == ckImplementedCode:
    for i in c.offset ..< min(c.offset + c.length, isCode.len): isCode[i] = true
  if c.kind == ckImplementedMeta:
    for i in c.offset ..< min(c.offset + c.length, isMeta.len): isMeta[i] = true

proc sandwich(o, n: int): bool =
  (o > 0 and isCode[o - 1]) and (o + n < isCode.len and isCode[o + n])

var free0 = 0
for r in freeRuns(claimed): free0 += r.n
echo &"free start: {free0}"

# --- CE62EE pure code island ---
block:
  let base = 0x0E62EE
  let n = 110 * 5
  var f, c, m = 0
  var ok = true
  for i in 0 ..< n:
    let o = base + i
    let rec = i mod 5
    if rec == 0:
      let lo = g[o].int or (g[o+1].int shl 8)
      let b = g[o+2]
      if b < 0xC0 or b > 0xEF or lo == 0 or g[o+3] != 0: ok = false
    if isMeta[o]: m += 1
    elif isCode[o]: c += 1
    elif not claimed[o]: f += 1
    else: m += 1  # other?
  echo &"CE62EE: ok={ok} free={f} code={c} meta={m} total={n}"

# --- Quality gates inventory (free only) ---
type Cand = object
  o, n: int
  fam, note: string

var cands: seq[Cand]
var covered = newSeq[bool](g.len)

proc take(o, n: int; fam, note: string) =
  if not isFree(claimed, o, n): return
  for i in o ..< o + n:
    if covered[i]: return
  for i in o ..< o + n: covered[i] = true
  cands.add Cand(o: o, n: n, fam: fam, note: note)

# A) u8pair min2 @70% with both-lo preference: count pairs where min(a,b)<=0x50
for r in freeRuns(claimed):
  if r.n < 4 or r.n mod 2 != 0: continue
  let nRec = r.n div 2
  if nRec < 2: continue
  var ok = 0
  var both = 0
  var nz = 0
  for i in 0 ..< nRec:
    let a = g[r.o + i * 2]
    let b = g[r.o + i * 2 + 1]
    if a <= 0x50 or b <= 0x50: ok += 1
    if a <= 0x50 and b <= 0x50: both += 1
    if a != 0 or b != 0: nz += 1
  if nz * 2 < nRec: continue
  # tier1: min2 @70%
  if ok * 100 >= nRec * 70:
    take(r.o, r.n, "u8pair2_70",
      &"u8pair min2@70% lo≤0x50 (ok={ok}/{nRec})")
  # tier2: min2 @55% but both-lo ≥50% of pairs
  elif ok * 100 >= nRec * 55 and both * 100 >= nRec * 50:
    take(r.o, r.n, "u8pair2_both",
      &"u8pair min2@55% both-lo≥50% (ok={ok} both={both}/{nRec})")

# B) term F0-FF clean body: last is unique term, body no term, ≥1 NZ, n>=2, quality
for r in freeRuns(claimed):
  if r.n < 2 or r.n > 32: continue
  let t = g[r.o + r.n - 1]
  if t < 0xF0: continue
  var bodyTerm, bodyNZ, hi, z = 0
  for j in 0 ..< r.n - 1:
    if g[r.o + j] == t: bodyTerm += 1
    elif g[r.o + j] != 0: bodyNZ += 1
    if g[r.o + j] >= 0xE0: hi += 1
    if g[r.o + j] == 0: z += 1
  if bodyTerm != 0: continue
  if bodyNZ < 1: continue
  if hi * 2 > r.n: continue
  if z * 3 > r.n: continue
  # anti-opcode head
  let badHeads: set[uint8] = {0x00, 0x18, 0x20, 0x22, 0x38, 0x40, 0x48, 0x4C,
    0x5C, 0x60, 0x68, 0x6B, 0x78, 0x80, 0xA0, 0xA2, 0xA9, 0xAD, 0xAE, 0xAF,
    0xC2, 0xE2, 0xEA, 0xF0, 0xF4, 0xFA, 0xFB, 0xA5, 0xD0, 0xF0}
  if g[r.o] in badHeads: continue
  take(r.o, r.n, "term_clean",
    &"term 0x{t:02X} clean body n={r.n}")

# C) xxFF pairs full cover
for r in freeRuns(claimed):
  if r.n < 2 or r.n mod 2 != 0: continue
  var ok = true
  var nz = 0
  for i in 0 ..< (r.n div 2):
    if g[r.o + i * 2 + 1] != 0xFF: ok = false
    if g[r.o + i * 2] != 0: nz += 1
  if ok and nz >= 1:
    take(r.o, r.n, "xxFF", &"xxFF pair stream n={r.n}")

# D) loplane 00-1F n>=4, not pure zero, at least 2 distinct values
for r in freeRuns(claimed):
  if r.n < 4: continue
  var ok = true
  var distSet: set[uint8]
  for j in 0 ..< r.n:
    if g[r.o + j] > 0x1F: ok = false
    distSet.incl g[r.o + j]
  if not ok: continue
  if 0 in distSet and distSet.len == 1: continue  # pure zero
  if distSet.len < 2: continue
  take(r.o, r.n, "loplane", &"loplane 00-1F n={r.n} dist={distSet.len}")

# E) bitMask powers-of-two distinct >=3 (wave103 used >=4)
for r in freeRuns(claimed):
  if r.n < 3: continue
  var s: set[uint8]
  var ok = true
  for j in 0 ..< r.n:
    let b = g[r.o + j]
    if b notin [0x01u8, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80]:
      ok = false
      break
    s.incl b
  if ok and s.len >= 3:
    take(r.o, r.n, "bitMask3", &"bitMask distinct≥3 n={r.n}")

# F) plane even-prefix: even prefix >=6 @50% equal pairs (wave103 used >=8)
for r in freeRuns(claimed):
  let evenN = r.n and not 1
  if evenN < 6: continue
  let pairs = evenN div 2
  var eq = 0
  for i in 0 ..< pairs:
    if g[r.o + i * 2] == g[r.o + i * 2 + 1]: eq += 1
  if eq * 100 >= pairs * 50:
    take(r.o, evenN, "plane50_6",
      &"plane50 even-prefix≥6 eq={eq}/{pairs}")

# G) bitFlag min1 with non-zero? too weak. Skip.

# H) const >=2 already drained; zero drained.

# Summarize free-only
var byFam: CountTable[string]
var byBytes: CountTable[string]
var freeTot = 0
for c in cands:
  byFam.inc c.fam
  byBytes.inc c.fam, c.n
  freeTot += c.n

echo &"=== free-only structure claims: {freeTot} B in {cands.len} spans ==="
var keys = toSeq(byFam.keys)
keys.sort()
for k in keys:
  echo &"  {k}: {byBytes[k]} B / {byFam[k]} spans"

# mark claimed for residual after
var claimed2 = claimed
for c in cands:
  mark(claimed2, c.o, c.n)

# CE62EE as pure-code carve (not free)
let ceBase = 0x0E62EE
let ceN = 550
var ceOk = true
var ceCode = 0
for i in 0 ..< ceN:
  let o = ceBase + i
  let rec = i mod 5
  if rec == 0:
    let lo = g[o].int or (g[o+1].int shl 8)
    let b = g[o+2]
    if b < 0xC0 or b > 0xEF or lo == 0 or g[o+3] != 0: ceOk = false
  if isCode[o]: ceCode += 1
  elif isMeta[o]: ceOk = false
  elif not claimed[o]: ceOk = false  # unexpected free
echo &"CE62EE carve candidate: ok={ceOk} code={ceCode}/{ceN}"

# remaining free
var rem = 0
var rn = 0
var sandwichB = 0
for r in freeRuns(claimed2):
  rem += r.n
  rn += 1
  if sandwich(r.o, r.n): sandwichB += r.n
echo &"free after free-claims: {rem} B in {rn} runs (sandwich ~{sandwichB})"
let exact = (3145728 - rem).float * 100.0 / 3145728.0
echo &"expected coverage ~{exact:.4f}% (from free residual only)"

# dump claim spans for generator (free only first 30)
echo "--- sample free claims ---"
for i, c in cands:
  if i >= 20: break
  echo &"  0x{c.o:06X}+{c.n} {c.fam} {c.note}"

# count sandwich vs non for each family
for k in keys:
  var sw, nsw = 0
  for c in cands:
    if c.fam != k: continue
    if sandwich(c.o, c.n): sw += c.n
    else: nsw += c.n
  echo &"  {k} sandwich={sw} non-sw={nsw}"
