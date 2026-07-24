
## Claim remaining C5 / CF program / EF / CC residual free with structure gates.

import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[memmap, rom_chunks, baserom_extract]

const
  C5IdxBase = 0x05A5B6
  C5IdxCount = 253
  C5IdxRec = 14
  EfPtrTable = 0x2F133F
  EfPtrCount = 464
  CfObj12Lo = 0x0F9315
  CfObj12Hi = 0x0F9FF7
  CfProgLo = 0x0F59F1
  CfProgHi = 0x0F6921

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len: return false
  for j in 0 ..< n:
    if claimed[o + j]: return false
  true

proc freeRunsIn(claimed: seq[bool]; lo, hi: int): seq[tuple[o, n: int]] =
  result = @[]
  var rs = -1; var rl = 0
  let lim = min(hi, claimed.len)
  for o in lo ..< lim:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0: result.add (rs, rl); rs = -1
  if rs >= 0: result.add (rs, rl)

proc farFo(g: seq[uint8]; fo: int): int =
  let lo = g[fo].int
  let hi = g[fo+1].int
  let bk = g[fo+2].int
  snesToFile(uint32(lo or (hi shl 8) or (bk shl 16)))

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var total = 0
  var nSpans = 0
  echo "# === C5 / CF / EF residual free expand ==="

  # ---- C5 index free (any free in 14B table, not only full records) ----
  block:
    var t = 0
    for r in freeRunsIn(claimed, C5IdxBase, C5IdxBase + C5IdxCount * C5IdxRec):
      if r.n < 2: continue
      echo &"""  BaseromExtractSpan(
    name: "table_c5Idx14_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekTable,
    note: "C5 14B index residual @$C5A5B6; free only"),"""
      mark(claimed, r.o, r.n)
      t += r.n; nSpans += 1
    echo &"# C5 idx free: {t} B"
    total += t

  # ---- C5 body: all free between min/max ptr targets in bank C5 ----
  block:
    type PE = tuple[id, f: int]
    var ptrs: seq[PE] = @[]
    for i in 0 ..< C5IdxCount:
      let o = C5IdxBase + i * C5IdxRec
      if o + 7 >= g.len: break
      let lo = g[o].int or (g[o+1].int shl 8)
      let id = g[o+6].int
      ptrs.add (id, (0xC5 - 0xC0) * 0x10000 + lo)
    ptrs.sort(proc(a,b: PE): int = cmp(a.f, b.f))
    var uniq: seq[PE] = @[]
    for p in ptrs:
      if uniq.len == 0 or uniq[^1].f != p.f: uniq.add p
    var t = 0
    # free between consecutive ptrs regardless of prefix (structure = ptr-bounded)
    for i in 0 ..< uniq.len - 1:
      let a = uniq[i].f
      let b = uniq[i+1].f
      let ln = b - a
      if ln <= 0 or ln > 400: continue
      for r in freeRunsIn(claimed, a, b):
        if r.n < 2: continue
        echo &"""  BaseromExtractSpan(
    name: "table_c5Body_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekTable,
    note: "C5 body residual id~{uniq[i].id}; ptr-bounded from $C5A5B6; free only"),"""
        mark(claimed, r.o, r.n)
        t += r.n; nSpans += 1
    # also free after last body until bank end of max+200
    if uniq.len > 0:
      let last = uniq[^1].f
      for r in freeRunsIn(claimed, last, min(last + 200, 0x060000)):
        if r.n < 2: continue
        # only if looks like body continuation (any)
        echo &"""  BaseromExtractSpan(
    name: "table_c5Body_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekTable,
    note: "C5 body residual tail after last ptr; free only"),"""
        mark(claimed, r.o, r.n)
        t += r.n; nSpans += 1
    echo &"# C5 body free: {t} B"
    total += t

  # ---- EF mid free any 25/27/41 gap free ----
  block:
    var ptrs: seq[int] = @[]
    for i in 0 ..< EfPtrCount:
      let p = EfPtrTable + i * 4
      if p + 3 >= g.len: break
      let fo = farFo(g, p)
      if fo >= 0: ptrs.add fo
    ptrs.sort(cmp)
    var uniq: seq[int] = @[]
    for p in ptrs:
      if uniq.len == 0 or uniq[^1] != p: uniq.add p
    var t = 0
    for i in 0 ..< uniq.len - 1:
      let a = uniq[i]; let b = uniq[i+1]; let ln = b - a
      if ln notin {25, 27, 41}: continue
      for r in freeRunsIn(claimed, a, b):
        if r.n < 2: continue
        echo &"""  BaseromExtractSpan(
    name: "table_efSpriteMid_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekTable,
    note: "EF sprite-group mid-record residual @ $EF133F (gap {ln}); free only"),"""
        mark(claimed, r.o, r.n)
        t += r.n; nSpans += 1
    # free inside ptr table itself
    for r in freeRunsIn(claimed, EfPtrTable, EfPtrTable + EfPtrCount * 4):
      if r.n < 2: continue
      echo &"""  BaseromExtractSpan(
    name: "table_efSpritePtr_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekTable,
    note: "EF sprite-group ptr residual @ $EF133F; free only"),"""
      mark(claimed, r.o, r.n)
      t += r.n; nSpans += 1
    echo &"# EF free: {t} B"
    total += t

  # ---- CF program 4B words residual ----
  block:
    var t = 0
    for r in freeRunsIn(claimed, CfProgLo, CfProgHi):
      var o = r.o; var n = r.n
      # align to 4 relative to CfProgLo
      let mis = (o - CfProgLo) mod 4
      if mis != 0:
        o += 4 - mis; n -= 4 - mis
      if n mod 4 != 0: n -= n mod 4
      if n < 4: continue
      # soft: high byte often 0
      var good = 0
      var words = n div 4
      for i in 0 ..< words:
        if g[o + i*4 + 3] == 0: good += 1
      if good * 2 < words: continue
      echo &"""  BaseromExtractSpan(
    name: "table_cfProg4_0x{o:06X}",
    offset: 0x{o:06X},
    length: {n},
    kind: ekTable,
    note: "CF program pool 4B-word residual after u16 ptrs @$CF59F1; free only"),"""
      mark(claimed, o, n)
      t += n; nSpans += 1
    echo &"# CF prog4 free: {t} B"
    total += t

  # ---- CF obj12 complete free ----
  block:
    var t = 0
    for r in freeRunsIn(claimed, CfObj12Lo, CfObj12Hi):
      var o = r.o
      let endO = r.o + r.n
      while o + 12 <= endO:
        let typ = g[o].int
        let bk = g[o + 11].int
        if typ in 0..3 and bk in 0xC6..0xC9 and isFree(claimed, o, 12):
          var n = 0; var p = o
          while p + 12 <= endO and isFree(claimed, p, 12):
            let t2 = g[p].int; let b2 = g[p+11].int
            if t2 notin 0..3 or b2 notin 0xC6..0xC9: break
            n += 12; p += 12
          if n >= 12:
            echo &"""  BaseromExtractSpan(
    name: "table_cfObj12_0x{o:06X}",
    offset: 0x{o:06X},
    length: {n},
    kind: ekTable,
    note: "CF 12B object residual; type@+0∈0..3; far ptr banks $C6-$C9 @+9; free only"),"""
            mark(claimed, o, n)
            t += n; nSpans += 1
            o = p; continue
        o += 1
    # also claim free fragments ≥2 inside window as mid-rec
    for r in freeRunsIn(claimed, CfObj12Lo, CfObj12Hi):
      if r.n < 2: continue
      echo &"""  BaseromExtractSpan(
    name: "table_cfObj12_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekTable,
    note: "CF 12B object/config residual mid-hole; free only"),"""
      mark(claimed, r.o, r.n)
      t += r.n; nSpans += 1
    echo &"# CF obj12 free: {t} B"
    total += t

  # ---- APU pack free ----
  block:
    const PackTableFile = 0x04F947
    const PackCount = 170
    const MaxPackSize = 0x2800
    proc walkApu(off: int): tuple[ok: bool, size, blocks: int] =
      if off < 0 or off + 4 > g.len: return (false, 0, 0)
      var pos = off; var blocks = 0
      while pos + 4 <= g.len:
        let ln = g[pos].int or (g[pos+1].int shl 8)
        let tgt = g[pos+2].int or (g[pos+3].int shl 8)
        if ln == 0:
          let size = pos + 4 - off
          if size > MaxPackSize or (blocks == 0 and tgt == 0): return (false, 0, 0)
          return (true, size, blocks)
        if ln > 0xC000 or pos+4+ln > g.len: return (false, 0, 0)
        if pos+4+ln-off > MaxPackSize: return (false, 0, 0)
        blocks += 1; pos += 4 + ln
      (false, 0, 0)
    var t = 0
    for i in 0 ..< PackCount:
      let b = PackTableFile + i * 3
      let bank = g[b].int
      let a = g[b+1].int or (g[b+2].int shl 8)
      if bank < 0xC0 or bank > 0xEF: continue
      let fo = snesToFile(uint32(a or (bank shl 16)))
      if fo < 0: continue
      let (ok, size, blocks) = walkApu(fo)
      if not ok: continue
      for r in freeRunsIn(claimed, fo, fo + size):
        if r.n < 4: continue
        echo &"""  BaseromExtractSpan(
    name: "apuPack_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekApuPackage,
    note: "APU pack {i} residual (pack@0x{fo:06X} size={size}); pack-table discovery; free only"),"""
        mark(claimed, r.o, r.n)
        t += r.n; nSpans += 1
    echo &"# APU free: {t} B"
    total += t

  # ---- solid loader tables ----
  if isFree(claimed, 0x00B0A6, 4):
    echo """  BaseromExtractSpan(
    name: "table_c0BitMask_0x00B0A6",
    offset: 0x00B0A6,
    length: 4,
    kind: ekTable,
    note: "4B bit-nibble masks 00 0F F0 FF; loaders $C0B04F/$C0B065/$C0B07A LDA.L,X; free only"),"""
    mark(claimed, 0x00B0A6, 4); total += 4; nSpans += 1

  # CF 5B at 0x0F30F7
  if isFree(claimed, 0x0F30F7, 10):
    echo """  BaseromExtractSpan(
    name: "table_cfRec5_0x0F30F7",
    offset: 0x0F30F7,
    length: 10,
    kind: ekTable,
    note: "CF 5B residual 0A 01 00 80 xx; AbsoluteLong $CF3100; free only"),"""
    mark(claimed, 0x0F30F7, 10); total += 10; nSpans += 1

  # CC FF-term prefix
  if isFree(claimed, 0x0C7371, 12):
    echo """  BaseromExtractSpan(
    name: "table_ccRec4FF_0x0C7371",
    offset: 0x0C7371,
    length: 12,
    kind: ekTable,
    note: "CC 4B FF-term residual head; free only"),"""
    mark(claimed, 0x0C7371, 12); total += 12; nSpans += 1

  # CC6 6B HDMA-like
  block:
    let lo = 0x0C6ADA; let hi = lo + 355
    var o = lo; var t = 0
    while o + 6 <= hi:
      if isFree(claimed, o, 6) and g[o+1]==0x01 and g[o+2]==0xE6 and g[o+3]==0xE7 and g[o+4]==0x9C:
        var n = 0; var p = o
        while p + 6 <= hi and isFree(claimed, p, 6) and
              g[p+1]==0x01 and g[p+2]==0xE6 and g[p+3]==0xE7 and g[p+4]==0x9C:
          n += 6; p += 6
        if n >= 12:
          echo &"""  BaseromExtractSpan(
    name: "table_ccHdma6_0x{o:06X}",
    offset: 0x{o:06X},
    length: {n},
    kind: ekTable,
    note: "CC 6B residual xx 01 E6 E7 9C yy (HDMA-like); free only"),"""
          mark(claimed, o, n); t += n; total += n; nSpans += 1
          o = p; continue
      o += 1
    echo &"# CC hdma6: {t} B"

  # ---- D9 residual islands APU package probe at every 4B ----
  block:
    var t = 0
    for r in freeRunsIn(claimed, 0x190000, 0x1A0000):
      if r.n < 64: continue
      for d in countup(0, min(r.n - 8, 128), 4):
        let off = r.o + d
        # walk package
        var pos = off; var blocks = 0; var ok = false; var size = 0
        while pos + 4 <= g.len and pos - off < 0x2800:
          let ln = g[pos].int or (g[pos+1].int shl 8)
          let tgt = g[pos+2].int or (g[pos+3].int shl 8)
          if ln == 0:
            size = pos + 4 - off
            ok = blocks >= 1 and size <= 0x2800
            break
          if ln > 0xC000 or pos+4+ln > g.len: break
          blocks += 1; pos += 4 + ln
        if not ok: continue
        # free cover
        var freeB = 0
        for j in 0 ..< size:
          if off + j < claimed.len and not claimed[off + j]: freeB += 1
        if freeB < max(8, size * 3 div 4): continue
        for fr in freeRunsIn(claimed, off, off + size):
          if fr.n < 4: continue
          echo &"""  BaseromExtractSpan(
    name: "apuPack_0x{fr.o:06X}",
    offset: 0x{fr.o:06X},
    length: {fr.n},
    kind: ekApuPackage,
    note: "APU package residual D9 island walk size={size} blocks={blocks}; free only"),"""
          mark(claimed, fr.o, fr.n)
          t += fr.n; total += fr.n; nSpans += 1
        break
    echo &"# D9 island APU: {t} B"

  echo &"\n# WAVE TOTAL: {total} B in {nSpans} spans"

main()
