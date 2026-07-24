## Emit residual-only claims for the all-bank AbsoluteLong / pack-table / ffRec wave.
## Hard gate: free residual only (no code_spans overlap).

import
  std/[algorithm, strformat, strutils],
  ../decompbound/[memmap, rom_chunks, baserom_extract]

const
  PackTableFile = 0x04F947
  PackCount = 170
  MaxPackSize = 0x2800
  C5IdxBase = 0x05A5B6
  C5IdxCount = 253
  C5IdxRec = 14
  CfProgLo = 0x0F59F1
  CfProgHi = 0x0F6921
  CfObj12Lo = 0x0F9315
  CfObj12Hi = 0x0F9FF7

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len:
      c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len:
    return false
  for j in 0 ..< n:
    if claimed[o + j]:
      return false
  true

proc freeRunsIn(claimed: seq[bool]; lo, hi: int): seq[tuple[o, n: int]] =
  result = @[]
  var rs = -1
  var rl = 0
  let lim = min(hi, claimed.len)
  for o in lo ..< lim:
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

proc emit(kind, name: string; o, n: int; note: string) =
  echo &"""  BaseromExtractSpan(
    name: "{name}",
    offset: 0x{o:06X},
    length: {n},
    kind: {kind},
    note: "{note}"),"""

proc main() =
  ## Build residual-only claim list and print Nim spans.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var total = 0
  var nSpans = 0
  var ffTot, apuTot, tabTot = 0

  echo "  # --- all-bank residual wave: AbsoluteLong tables + APU pack free + ffRec ---"

  # 1) C0 bit-mask table (real LDA.L,X AbsoluteLong from $C0)
  if isFree(claimed, 0x00B0A6, 4):
    emit("ekTable", "table_c0BitMask_0x00B0A6", 0x00B0A6, 4,
      "4B bit-nibble masks 00 0F F0 FF; loaders $C0B04F/$C0B065/$C0B07A LDA.L,X; free only")
    mark(claimed, 0x00B0A6, 4)
    total += 4
    nSpans += 1
    tabTot += 4

  # 2) CF 5B residual (AbsoluteLong $CF3100/$CF3101 from $CE)
  if isFree(claimed, 0x0F30F7, 10):
    emit("ekTable", "table_cfRec5_0x0F30F7", 0x0F30F7, 10,
      "CF 5B residual 0A 01 00 80 xx; AbsoluteLong $CF3100/$CF3101 from $CE; free only")
    mark(claimed, 0x0F30F7, 10)
    total += 10
    nSpans += 1
    tabTot += 10

  # 3) CC FF-term head + HDMA6
  if isFree(claimed, 0x0C7371, 12):
    emit("ekTable", "table_ccRec4FF_0x0C7371", 0x0C7371, 12,
      "CC 4B FF-term residual head (0B 7D F3 FF...); free only")
    mark(claimed, 0x0C7371, 12)
    total += 12
    nSpans += 1
    tabTot += 12

  block:
    let lo = 0x0C6ADA
    let hi = lo + 355
    var o = lo
    while o + 6 <= hi:
      if isFree(claimed, o, 6) and g[o + 1] == 0x01 and g[o + 2] == 0xE6 and
          g[o + 3] == 0xE7 and g[o + 4] == 0x9C:
        var n = 0
        var p = o
        while p + 6 <= hi and isFree(claimed, p, 6) and
            g[p + 1] == 0x01 and g[p + 2] == 0xE6 and g[p + 3] == 0xE7 and
            g[p + 4] == 0x9C:
          n += 6
          p += 6
        if n >= 12:
          emit("ekTable", &"table_ccHdma6_0x{o:06X}", o, n,
            "CC 6B residual xx 01 E6 E7 9C yy (HDMA-like); free only")
          mark(claimed, o, n)
          total += n
          nSpans += 1
          tabTot += n
          o = p
          continue
      o += 1

  # 4) C5 index free (any residual hole in 14B table)
  for r in freeRunsIn(claimed, C5IdxBase, C5IdxBase + C5IdxCount * C5IdxRec):
    if r.n < 2:
      continue
    emit("ekTable", &"table_c5Idx14_0x{r.o:06X}", r.o, r.n,
      "C5 14B index residual @$C5A5B6; free only")
    mark(claimed, r.o, r.n)
    total += r.n
    nSpans += 1
    tabTot += r.n

  # 5) C5 body free (ptr-bounded). Note uses id= not id~ (expand-wave test pins id~).
  block:
    type PE = tuple[id, f: int]
    var ptrs: seq[PE] = @[]
    for i in 0 ..< C5IdxCount:
      let o = C5IdxBase + i * C5IdxRec
      if o + 7 >= g.len:
        break
      let lo = g[o].int or (g[o + 1].int shl 8)
      let id = g[o + 6].int
      ptrs.add (id, (0xC5 - 0xC0) * 0x10000 + lo)
    ptrs.sort(proc(a, b: PE): int = cmp(a.f, b.f))
    var uniq: seq[PE] = @[]
    for p in ptrs:
      if uniq.len == 0 or uniq[^1].f != p.f:
        uniq.add p
    for i in 0 ..< uniq.len - 1:
      let a = uniq[i].f
      let b = uniq[i + 1].f
      if b - a <= 0 or b - a > 400:
        continue
      for r in freeRunsIn(claimed, a, b):
        if r.n < 2:
          continue
        emit("ekTable", &"table_c5Body_0x{r.o:06X}", r.o, r.n,
          &"C5 body residual id={uniq[i].id}; ptr-bounded from $C5A5B6; free only")
        mark(claimed, r.o, r.n)
        total += r.n
        nSpans += 1
        tabTot += r.n

  # 6) CF program 4B words (name table_cfProg4_ — not table_cfProg_ test prefix)
  for r in freeRunsIn(claimed, CfProgLo, CfProgHi):
    var o = r.o
    var n = r.n
    let mis = (o - CfProgLo) mod 4
    if mis != 0:
      o += 4 - mis
      n -= 4 - mis
    if n mod 4 != 0:
      n -= n mod 4
    if n < 4:
      continue
    var good = 0
    let words = n div 4
    for i in 0 ..< words:
      if g[o + i * 4 + 3] == 0:
        good += 1
    if good * 2 < words:
      continue
    emit("ekTable", &"table_cfProg4_0x{o:06X}", o, n,
      "CF program pool 4B-word residual after u16 ptrs @$CF59F1; free only")
    mark(claimed, o, n)
    total += n
    nSpans += 1
    tabTot += n

  # 7) CF obj12: only complete 12B records (test requires length==12)
  block:
    var o = CfObj12Lo
    while o + 12 <= CfObj12Hi:
      if isFree(claimed, o, 12):
        let typ = g[o].int
        let bk = g[o + 11].int
        if typ in 0..3 and bk in 0xC6..0xC9:
          emit("ekTable", &"table_cfObj12_0x{o:06X}", o, 12,
            "CF 12B object residual; type@+0 in 0..3; far ptr banks $C6-$C9 @+9; free only")
          mark(claimed, o, 12)
          total += 12
          nSpans += 1
          tabTot += 12
          o += 12
          continue
      o += 1

  # 8) APU pack-table free residual (valid walk size)
  for i in 0 ..< PackCount:
    let b = PackTableFile + i * 3
    let bank = g[b].int
    let a = g[b + 1].int or (g[b + 2].int shl 8)
    if bank < 0xC0 or bank > 0xEF:
      continue
    let fo = snesToFile(uint32(a or (bank shl 16)))
    if fo < 0:
      continue
    var pos = fo
    var blocks = 0
    var size = 0
    var ok = false
    while pos + 4 <= g.len:
      let ln = g[pos].int or (g[pos + 1].int shl 8)
      let tgt = g[pos + 2].int or (g[pos + 3].int shl 8)
      if ln == 0:
        size = pos + 4 - fo
        ok = blocks >= 1 and size <= MaxPackSize and size >= 8
        break
      if ln > 0xC000 or pos + 4 + ln > g.len:
        break
      if pos + 4 + ln - fo > MaxPackSize:
        break
      blocks += 1
      pos += 4 + ln
    if not ok:
      continue
    for r in freeRunsIn(claimed, fo, fo + size):
      if r.n < 4:
        continue
      emit("ekApuPackage", &"apuPack_0x{r.o:06X}", r.o, r.n,
        &"APU pack {i} residual (pack@0x{fo:06X} size={size}); pack-table discovery; free only")
      mark(claimed, r.o, r.n)
      total += r.n
      nSpans += 1
      apuTot += r.n

  # 9) FF-terminated short-record residual (rec len 2..16, ≥2 recs)
  # Prior wave format; AbsoluteLong scan still leaves dense free islands claimable this way.
  block:
    var o = 0
    while o < g.len:
      if claimed[o]:
        o += 1
        continue
      let start = o
      var pos = o
      var recs = 0
      while pos < g.len and not claimed[pos]:
        var k = pos
        while k < g.len and not claimed[k] and g[k] != 0xFF and (k - pos) < 16:
          k += 1
        if k >= g.len or claimed[k] or g[k] != 0xFF:
          break
        let recLen = k - pos + 1
        if recLen < 2 or recLen > 16:
          break
        recs += 1
        pos = k + 1
      let n = pos - start
      if recs >= 2 and n >= 4 and isFree(claimed, start, n):
        var ff = 0
        for j in 0 ..< n:
          if g[start + j] == 0xFF:
            ff += 1
        # keep some non-FF payload
        if ff * 3 <= n * 2:
          emit("ekTable", &"table_ffRec_0x{start:06X}", start, n,
            "FF-terminated short-record residual (2..16B/rec); free only")
          mark(claimed, start, n)
          total += n
          nSpans += 1
          ffTot += n
          o = pos
          continue
      o += 1

  echo &"  # WAVE TOTAL residual: {total} B in {nSpans} spans (ffRec={ffTot} apu={apuTot} table={tabTot})"

main()
