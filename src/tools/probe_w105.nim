## Probe residual claimable for wave105 (structure gates, incl sandwich free).
import
  std/[algorithm, strformat, strutils, tables, sequtils],
  ../decompbound/[rom_chunks, baserom_extract, action_script, text_decode, gfx_lz]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len: return false
  for j in 0 ..< n:
    if claimed[o + j]: return false
  true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  var rs = -1; var rl = 0
  for o in 0 ..< claimed.len:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0: result.add (rs, rl); rs = -1
  if rs >= 0: result.add (rs, rl)

proc isFar3(g: seq[uint8]; o: int): bool =
  let lo = g[o].int or (g[o + 1].int shl 8)
  let b = g[o + 2]
  result = b >= 0xC0 and b <= 0xEF and lo != 0

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset+c.length, isCode.len): isCode[i] = true

  var totals = initTable[string, int]()
  var counts = initTable[string, int]()
  var total = 0
  proc bump(k: string; n: int) =
    if k notin totals: totals[k]=0; counts[k]=0
    totals[k]+=n; counts[k]+=1; total += n

  proc sandwich(o, n: int): bool =
    (o > 0 and isCode[o - 1]) and (o + n < isCode.len and isCode[o + n])

  for r in freeRuns(claimed):
    var ok = true
    for j in 0..<r.n:
      if g[r.o+j] != 0: ok=false; break
    if ok and r.n >= 1:
      mark(claimed, r.o, r.n); bump("zero", r.n)

  for r in freeRuns(claimed):
    if r.n < 2: continue
    let v = g[r.o]
    if v == 0: continue
    var same = true
    for j in 1..<r.n:
      if g[r.o+j] != v: same=false; break
    if same:
      mark(claimed, r.o, r.n); bump("const", r.n)

  for r in freeRuns(claimed):
    if r.n < 3: continue
    var i = 0
    while i + 3 <= r.n:
      if isFar3(g, r.o + i):
        var k = i
        while k + 3 <= r.n and isFar3(g, r.o + k): k += 3
        let n = k - i
        if n >= 3 and isFree(claimed, r.o+i, n):
          mark(claimed, r.o+i, n); bump(if sandwich(r.o+i,n): "far3_sw" else: "far3", n)
        i = max(k, i+1)
      else: i += 1

  for termByte in 0xF0..0xFF:
    var o = 0
    while o < g.len:
      if claimed[o]: o += 1; continue
      var k = o
      while k < g.len and not claimed[k] and g[k] != termByte.uint8 and (k-o) < 32:
        k += 1
      if k < g.len and not claimed[k] and g[k] == termByte.uint8:
        let n = k - o + 1
        if n >= 2 and n <= 32 and isFree(claimed, o, n):
          var tc, hi, z = 0
          for j in 0..<n:
            if g[o+j] == termByte.uint8: tc += 1
            if g[o+j] >= 0xE0: hi += 1
            if g[o+j] == 0: z += 1
          if tc == 1 and hi*2 <= n and z*3 <= n:
            mark(claimed, o, n)
            bump(if sandwich(o,n): "term_sw" else: "term", n)
            o = k+1; continue
      o += 1

  for r in freeRuns(claimed):
    if r.n < 2: continue
    var ok = true; var nz = 0
    for j in 0..<r.n:
      let b = g[r.o+j]
      if b notin [0x00u8, 0x01u8, 0x80u8]: ok=false; break
      if b != 0: nz += 1
    if ok and nz >= 1:
      mark(claimed, r.o, r.n); bump(if sandwich(r.o,r.n): "bit_sw" else: "bit", r.n)

  for r in freeRuns(claimed):
    if r.n < 8 or r.n mod 2 != 0: continue
    let pairs = r.n div 2
    var eq = 0
    for i in 0..<pairs:
      if g[r.o + i*2] == g[r.o + i*2 + 1]: eq += 1
    if eq * 100 < pairs * 25: continue
    mark(claimed, r.o, r.n); bump(if sandwich(r.o,r.n): "plane_sw" else: "plane", r.n)

  for r in freeRuns(claimed):
    if r.n < 6 or r.n mod 2 != 0: continue
    let nRec = r.n div 2
    if nRec < 3: continue
    var ok=0; var nz=0
    for i in 0..<nRec:
      let a=g[r.o+i*2]; let b=g[r.o+i*2+1]
      if a <= 0x50 or b <= 0x50: ok += 1
      if a != 0 or b != 0: nz += 1
    if ok*100 < nRec*55: continue
    if nz*2 < nRec: continue
    mark(claimed, r.o, r.n); bump(if sandwich(r.o,r.n): "u8_sw" else: "u8", r.n)

  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen: continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      mark(claimed, r.o, r.n); bump(if sandwich(r.o,r.n): "as_sw" else: "as", r.n)

  for r in freeRuns(claimed):
    if r.n < 2: continue
    let w = walkScriptStream(g, r.o, r.o + r.n)
    if isGoodScriptStream(w) and w.length == r.n:
      mark(claimed, r.o, r.n); bump(if sandwich(r.o,r.n): "ss_sw" else: "ss", r.n)

  var rem=0; var sw=0
  for r in freeRuns(claimed):
    rem += r.n
    if sandwich(r.o, r.n): sw += r.n

  echo &"WAVE105 structure claimable: {total} B"
  var keys = toSeq(totals.keys); keys.sort()
  for k in keys:
    echo &"  {k}: {totals[k]} B / {counts[k]}"
  echo &"residual left: {rem} (sandwich left ~{sw})"
  echo &"expected ~{(3145728 - rem).float * 100.0 / 3145728.0:.4f}%"

main()
