## Deep-check plane25 leftovers + promising AbsoluteLong residual targets.
import
  std/[strformat, strutils, tables, sets],
  ../decompbound/[memmap, rom_chunks, baserom_extract]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  result = @[]
  var rs = -1
  var rl = 0
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
  var nameAt = newSeq[string](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset + c.length, isCode.len): isCode[i] = true
  for s in KnownBaseromExtracts:
    for j in 0 ..< s.length:
      if s.offset + j < nameAt.len:
        nameAt[s.offset + j] = s.name

  echo "=== plane25 candidates (full free runs) ==="
  var planeTot = 0
  for r in freeRuns(claimed):
    if r.n < 8: continue
    var eq = 0
    let pairs = r.n div 2
    for i in 0 ..< pairs:
      if g[r.o + i*2] == g[r.o + i*2 + 1]: eq += 1
    if pairs == 0 or eq * 100 < pairs * 25: continue
    var nz = 0
    for j in 0 ..< r.n:
      if g[r.o + j] != 0: nz += 1
    if nz * 2 < r.n: continue
    let L = if r.o > 0: nameAt[r.o - 1] else: "edge"
    let R = if r.o + r.n < nameAt.len: nameAt[r.o + r.n] else: "edge"
    var hx = ""
    for j in 0 ..< r.n: hx.add &"{g[r.o+j]:02X} "
    let pct = eq * 100 div pairs
    # sandwich
    let leftCode = r.o > 0 and isCode[r.o - 1]
    let rightCode = r.o + r.n < isCode.len and isCode[r.o + r.n]
    let sandwich = if leftCode and rightCode: "code|code" elif leftCode: "code|meta" elif rightCode: "meta|code" else: "meta|meta"
    echo &"  0x{r.o:06X}+{r.n} eq={eq}/{pairs} ({pct}%) nz={nz} neigh={sandwich} L={L} R={R}"
    echo &"    {hx}"
    planeTot += r.n
  echo &"plane25 total {planeTot} B"

  # Also try plane35 and plane50
  for thr in [35, 50]:
    var t = 0
    var n = 0
    for r in freeRuns(claimed):
      if r.n < 8: continue
      var eq = 0
      let pairs = r.n div 2
      for i in 0 ..< pairs:
        if g[r.o + i*2] == g[r.o + i*2 + 1]: eq += 1
      if pairs == 0 or eq * 100 < pairs * thr: continue
      var nz = 0
      for j in 0 ..< r.n:
        if g[r.o + j] != 0: nz += 1
      if nz * 2 < r.n: continue
      t += r.n; n += 1
    echo &"plane{thr}: {t} B / {n}"

  echo "\n=== AbsoluteLong target context ==="
  let targets = [
    (0x0F3101, 4), (0x0F30F7, 16), (0x17A595, 4), (0x17A598, 1),
    (0x16F7F7, 9), (0x22AAAB, 1), (0x072D95, 1), (0x15BCB2, 1)
  ]
  for (o, n) in targets:
    let L = if o > 0: nameAt[o - 1] else: "edge"
    let R = if o + n < nameAt.len: nameAt[o + n] else: "edge"
    var free = true
    for j in 0 ..< n:
      if o + j >= claimed.len or claimed[o + j]: free = false
    var hx = ""
    for j in 0 ..< min(24, n + 8):
      if o + j < g.len: hx.add &"{g[o+j]:02X} "
    echo &"  fo=0x{o:06X}+{n} free={free} L={L} R={R}"
    echo &"    ctx={hx}"

  # Disasm context around loaders for interesting hits
  echo "\n=== Loader site context (gold bytes around PC) ==="
  let sites = [0x0E8F10, 0x07AFDA, 0x0E024F, 0x0FF93A, 0x160BDF]
  for at in sites:
    var hx = ""
    let lo = max(0, at - 8)
    for j in lo ..< min(g.len, at + 12):
      if j == at: hx.add "|"
      hx.add &"{g[j]:02X} "
    echo &"  @0x{at:06X}: {hx}"
    echo &"    code={isCode[at]} claimed={claimed[at]}"

  # CF3101: check if part of known 5B table family around CF30F7
  echo "\n=== CF30xx band free runs ==="
  for r in freeRuns(claimed):
    if r.o >= 0x0F3000 and r.o < 0x0F3200:
      var hx = ""
      for j in 0 ..< r.n: hx.add &"{g[r.o+j]:02X} "
      echo &"  free 0x{r.o:06X}+{r.n}: {hx}"

  # 17A595: bit masks? classic 01 02 04 08 10 20 40 80
  echo "\n=== around 0x17A580 ==="
  for j in 0x17A580 .. 0x17A5B0:
    let tag = if claimed[j]: "C" else: "."
    stdout.write &"{tag}{g[j]:02X} "
    if (j and 0xF) == 0xF: echo ""
  echo ""

  # Look for bit-mask tables residual free (classic pattern)
  echo "\n=== residual runs matching bit-mask patterns ==="
  for r in freeRuns(claimed):
    if r.n < 4: continue
    # power-of-two ascending
    var pot = true
    for i in 0 ..< r.n:
      let exp = 1 shl i
      if exp > 0x80: pot = false; break
      if g[r.o + i].int != exp: pot = false; break
    if pot:
      echo &"  pot 0x{r.o:06X}+{r.n}"
    # any subset of {01,02,04,08,10,20,40,80}
    var ok = true
    var seen = initHashSet[uint8]()
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if b notin [0x01u8,0x02u8,0x04u8,0x08u8,0x10u8,0x20u8,0x40u8,0x80u8]:
        ok = false; break
      if b in seen: ok = false; break
      seen.incl b
    if ok and r.n >= 4:
      var hx = ""
      for j in 0 ..< r.n: hx.add &"{g[r.o+j]:02X} "
      echo &"  bitmask-set 0x{r.o:06X}+{r.n}: {hx}"

main()
