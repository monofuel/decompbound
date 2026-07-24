import
  std/[algorithm, strformat, strutils, tables, sets, sequtils],
  ../decompbound/[rom_chunks, baserom_extract, action_script, text_decode, gfx_lz, memmap]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len: return false
  for j in 0 ..< n:
    if claimed[o + j]: return false
  true

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

  var total = 0
  var totals = initTable[string, int]()
  var counts = initTable[string, int]()
  proc bump(k: string; n: int) =
    if k notin totals: totals[k]=0; counts[k]=0
    totals[k]+=n; counts[k]+=1
    total += n

  # zero
  for r in freeRuns(claimed):
    var ok = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0: ok = false; break
    if ok and r.n >= 1:
      mark(claimed, r.o, r.n); bump("zero", r.n)

  # const >=2
  for r in freeRuns(claimed):
    if r.n < 2: continue
    let v = g[r.o]
    if v == 0: continue
    var same = true
    for j in 1 ..< r.n:
      if g[r.o + j] != v: same = false; break
    if same:
      mark(claimed, r.o, r.n); bump("const", r.n)

  # far3 mid singles C0-EF lo!=0 (pure chain >=1)
  for r in freeRuns(claimed):
    if r.n < 3: continue
    var i = 0
    while i + 3 <= r.n:
      if isFar3(g, r.o + i):
        var k = i
        while k + 3 <= r.n and isFar3(g, r.o + k): k += 3
        let n = k - i
        if n >= 3 and isFree(claimed, r.o + i, n):
          mark(claimed, r.o + i, n); bump("far3", n)
        i = max(k, i + 1)
      else:
        i += 1

  # pure far3 rem align 0-2 of whole free run
  for r in freeRuns(claimed):
    if r.n < 3: continue
    for align in 0..2:
      let nRec = (r.n - align) div 3
      if nRec < 1: continue
      let n = nRec * 3
      let base = r.o + align
      if n != r.n - align and n != r.n: discard
      # pure rem: remainder after align is pure far3 covering all leftover
      if align + n != r.n: continue
      var ok = true
      for i in 0 ..< nRec:
        if not isFar3(g, base + i*3): ok = false; break
      if ok and isFree(claimed, base, n):
        mark(claimed, base, n); bump("far3pure", n)
        break

  # term F0-FF singles min2 (was min3)
  for termByte in 0xF0 .. 0xFF:
    var o = 0
    while o < g.len:
      if claimed[o]:
        o += 1; continue
      var k = o
      while k < g.len and not claimed[k] and g[k] != termByte.uint8 and (k - o) < 32:
        k += 1
      if k < g.len and not claimed[k] and g[k] == termByte.uint8:
        let n = k - o + 1
        if n >= 2 and n <= 32 and isFree(claimed, o, n):
          var tc, hi, z = 0
          for j in 0 ..< n:
            if g[o + j] == termByte.uint8: tc += 1
            if g[o + j] >= 0xE0: hi += 1
            if g[o + j] == 0: z += 1
          if tc == 1 and hi * 2 <= n and z * 3 <= n:
            mark(claimed, o, n); bump("term1min2", n)
            o = k + 1; continue
      o += 1

  # term multi recs min1 of 2-32
  for termByte in 0xF0 .. 0xFF:
    var o = 0
    while o < g.len:
      if claimed[o]:
        o += 1; continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not claimed[pos]:
        var k = pos
        while k < g.len and not claimed[k] and g[k] != termByte.uint8 and (k-pos) < 48:
          k += 1
        if k >= g.len or claimed[k] or g[k] != termByte.uint8: break
        let rl = k - pos + 1
        if rl < 2 or rl > 48: break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 1 and n >= 2 and n <= 48 and isFree(claimed, start, n):
        var tc = 0
        for j in 0 ..< n:
          if g[start + j] == termByte.uint8: tc += 1
        if tc == recs:
          mark(claimed, start, n); bump("termAny", n)
          o = pos; continue
      o += 1

  # u8pair >=4 @55% even free
  for r in freeRuns(claimed):
    if r.n < 8 or r.n mod 2 != 0: continue
    let nRec = r.n div 2
    if nRec < 4: continue
    var ok, nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o + i*2]; let b = g[r.o + i*2 + 1]
      if a <= 0x50 or b <= 0x50: ok += 1
      if a != 0 or b != 0: nz += 1
    if ok * 100 < nRec * 55: continue
    if nz * 2 < nRec: continue
    mark(claimed, r.o, r.n); bump("u8pair", r.n)

  # bitFlag min2
  for r in freeRuns(claimed):
    if r.n < 2: continue
    var ok = true
    var nz = 0
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if b notin [0x00u8, 0x01u8, 0x80u8]: ok = false; break
      if b != 0: nz += 1
    if ok and nz >= 1:
      mark(claimed, r.o, r.n); bump("bitFlag2", r.n)

  # AS good remaining
  for r in freeRuns(claimed):
    if r.n < ActionScriptMinLen: continue
    if isGoodActionScriptSpan(g, r.o, r.n):
      mark(claimed, r.o, r.n); bump("as", r.n)

  # gfx_lz clean
  for r in freeRuns(claimed):
    if r.n < 4: continue
    let slice = g[r.o ..< r.o + r.n]
    let (data, consumed, clean) = decodeWithConsumed(slice)
    if not clean or consumed < 4 or consumed > r.n or data.len < 16: continue
    if isFree(claimed, r.o, consumed):
      mark(claimed, r.o, consumed); bump("gfx", consumed)

  # skip code|code sandwich for extract (code seed path)
  var sandwichLeft = 0
  for r in freeRuns(claimed):
    let leftCode = r.o > 0 and isCode[r.o - 1]
    let rightCode = r.o + r.n < isCode.len and isCode[r.o + r.n]
    if leftCode and rightCode: sandwichLeft += r.n

  var rem = 0
  for r in freeRuns(claimed): rem += r.n
  echo &"WAVE104 scout total claimable: {total} B"
  var keys = toSeq(totals.keys); keys.sort()
  for k in keys:
    echo &"  {k}: {totals[k]} B / {counts[k]} spans"
  echo &"residual left: {rem} B (of which sandwich ~{sandwichLeft})"
  let exact = (3145728 - rem).float * 100.0 / 3145728.0
  echo &"expected coverage ~{exact:.4f}%"

main()
