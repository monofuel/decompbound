## Inspect CE62EE 5B table structure + free holes.
import
  std/[strformat, strutils],
  ../decompbound/[rom_chunks, baserom_extract]

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
var isCode = newSeq[bool](g.len)
var isMeta = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset ..< min(c.offset + c.length, claimed.len):
      claimed[i] = true
  if c.kind == ckImplementedCode:
    for i in c.offset ..< min(c.offset + c.length, isCode.len):
      isCode[i] = true
  if c.kind == ckImplementedMeta:
    for i in c.offset ..< min(c.offset + c.length, isMeta.len):
      isMeta[i] = true

const base = 0x0E62EE
const nRec = 110
var freeRuns: seq[tuple[o, n: int]]
var rs = -1
var rl = 0
for i in 0 ..< nRec * 5:
  let o = base + i
  if not claimed[o]:
    if rs < 0:
      rs = o
      rl = 1
    else:
      rl += 1
  else:
    if rs >= 0:
      freeRuns.add (rs, rl)
      rs = -1
if rs >= 0:
  freeRuns.add (rs, rl)

echo &"free runs inside CE62EE window ({freeRuns.len}):"
for r in freeRuns:
  var hs = ""
  for i in 0 ..< r.n:
    hs.add &"{g[r.o + i]:02X} "
  let leftC = r.o > 0 and isCode[r.o - 1]
  let rightC = r.o + r.n < isCode.len and isCode[r.o + r.n]
  echo &"  0x{r.o:06X}+{r.n} Lcode={leftC} Rcode={rightC} hex={hs}"

var good = 0
var breakAt = -1
var types: array[256, int]
for r in 0 ..< nRec:
  let o = base + r * 5
  let lo = g[o].int or (g[o + 1].int shl 8)
  let b = g[o + 2]
  let z = g[o + 3]
  let t = g[o + 4]
  types[t.int] += 1
  let ok = b >= 0xC0 and b <= 0xEF and lo != 0 and z == 0
  if not ok:
    if breakAt < 0:
      breakAt = r
    echo &"  BAD rec {r} @0x{o:06X}: {g[o]:02X} {g[o+1]:02X} {g[o+2]:02X} {g[o+3]:02X} {g[o+4]:02X} lo={lo:04X} bank={b:02X} z={z:02X}"
  else:
    good += 1
echo &"good recs: {good}/{nRec} firstBad={breakAt}"

echo "type hist:"
for t in 0 .. 255:
  if types[t] > 0:
    echo &"  type={t:02X}: {types[t]}"

var cont = 0
for r in 0 ..< nRec:
  let o = base + r * 5
  let lo = g[o].int or (g[o + 1].int shl 8)
  let b = g[o + 2]
  let z = g[o + 3]
  if b >= 0xC0 and b <= 0xEF and lo != 0 and z == 0:
    cont += 1
  else:
    break
echo &"contiguous good from base: {cont} ({cont * 5} B)"

# islands of valid 5B
var o = base
let endp = base + nRec * 5
while o + 5 <= endp:
  let lo = g[o].int or (g[o + 1].int shl 8)
  let b = g[o + 2]
  if not (b >= 0xC0 and b <= 0xEF and lo != 0 and g[o + 3] == 0):
    o += 1
    continue
  let start = o
  while o + 5 <= endp:
    let lo2 = g[o].int or (g[o + 1].int shl 8)
    let b2 = g[o + 2]
    if not (b2 >= 0xC0 and b2 <= 0xEF and lo2 != 0 and g[o + 3] == 0):
      break
    o += 5
  let n = o - start
  var f, c, m = 0
  for i in start ..< start + n:
    if isMeta[i]:
      m += 1
    elif isCode[i]:
      c += 1
    elif not claimed[i]:
      f += 1
  if n >= 10:
    echo &"island 0x{start:06X}+{n} free={f} code={c} meta={m} recs={n div 5}"

# also try bank C0-FF lo!=0 z==0 type 1..6 (docs say type1..6)
echo "--- with type 1..6 filter ---"
cont = 0
for r in 0 ..< nRec:
  let o = base + r * 5
  let lo = g[o].int or (g[o + 1].int shl 8)
  let b = g[o + 2]
  let z = g[o + 3]
  let t = g[o + 4]
  if b >= 0xC0 and b <= 0xEF and lo != 0 and z == 0 and t >= 1 and t <= 6:
    cont += 1
  else:
    echo &"  stop at rec {r} @0x{o:06X} t={t:02X} bank={b:02X} z={z:02X}"
    break
echo &"type1-6 contiguous: {cont}"

# dump first 5 and any free-adjacent recs
echo "first 5 recs:"
for r in 0 .. 4:
  let o = base + r * 5
  echo &"  [{r}] {g[o]:02X}{g[o+1]:02X}{g[o+2]:02X}{g[o+3]:02X}{g[o+4]:02X}"
