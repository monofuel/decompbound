
## Probe residual for FF-terminated short records (2..32 B).

import
  std/[algorithm, strformat],
  ../decompbound/[rom_chunks, baserom_extract]

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset..<min(c.offset+c.length, claimed.len): claimed[i]=true

var total = 0
var nSpans = 0
var o = 0
while o < g.len:
  if claimed[o]:
    o += 1
    continue
  # walk FF-term records in free
  let start = o
  var pos = o
  var recs = 0
  while pos < g.len and not claimed[pos]:
    var k = pos
    while k < g.len and not claimed[k] and g[k] != 0xFF:
      k += 1
    if k >= g.len or claimed[k] or g[k] != 0xFF:
      break
    let recLen = k - pos + 1
    if recLen < 2 or recLen > 32:
      break
    recs += 1
    pos = k + 1
  let n = pos - start
  if recs >= 2 and n >= 4:
    # soft quality: not mostly FF
    var ff = 0
    for j in 0..<n:
      if g[start+j] == 0xFF: ff += 1
    if ff * 3 <= n * 2:  # FF ≤ 2/3
      total += n
      nSpans += 1
      if nSpans <= 15:
        echo &"  ffRec 0x{start:06X}+{n} recs={recs}"
      for j in 0..<n: claimed[start+j] = true
      o = pos
      continue
  o += 1

echo &"# ffRec residual: {total} B in {nSpans} spans"
