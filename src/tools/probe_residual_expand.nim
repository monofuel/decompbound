## Expand residual free claims for known table families + rank top gaps.
## EF sprite ($EF133F), C4 hitbox ($C42B0D), CF maps, APU pack interiors,
## plus C5 index/body and BBG layer17 if still free. Emits Nim span text.

import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[baserom_extract, common, memmap, rom_chunks, generated/code_spans]

const
  Gold = "bin/Earthbound (U) [!].smc"
  EfPtrTable = 0x2F133F
  EfPtrCount = 464
  C4HitPtrTable = 0x042B0D
  C4HitPtrCount = 17
  CfMapPtrLo = 0x0F6921
  CfMapPtrHi = 0x0F6BE7
  CfObj12Lo = 0x0F9315
  CfObj12Hi = 0x0F9FF7
  C5IdxBase = 0x05A5B6
  C5IdxCount = 253
  C5IdxRec = 14
  BbgLayerBase = 0x0ADEA1
  BbgLayerCount = 327
  BbgLayerRec = 17

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

proc freeInside(claimed: seq[bool]; lo, hi: int): seq[tuple[o, n: int]] =
  ## Free sub-runs strictly inside [lo, hi).
  freeRunsIn(claimed, lo, hi)

proc farFileOff(g: seq[uint8]; fo: int): int =
  ## 24-bit far ptr at file offset → file offset (bank $C0+ → file bank).
  let lo = g[fo].int
  let hi = g[fo + 1].int
  let bk = g[fo + 2].int
  let snes = uint32(lo or (hi shl 8) or (bk shl 16))
  snesToFile(snes)

proc emitSpan(name: string; o, n: int; note: string) =
  echo &"""  BaseromExtractSpan(
    name: "{name}",
    offset: 0x{o:06X},
    length: {n},
    kind: ekTable,
    note: "{note}"),"""

proc emitApu(name: string; o, n: int; note: string) =
  echo &"""  BaseromExtractSpan(
    name: "{name}",
    offset: 0x{o:06X},
    length: {n},
    kind: ekApuPackage,
    note: "{note}"),"""

proc main() =
  ## Probe remaining residual for known families; print claimable spans.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for s in allBaseromExtractSpans():
    mark(claimed, s.offset, s.length)
  for s in GeneratedCodeSpans:
    mark(claimed, s.offset, s.length)
  # also mark header/vectors via chunk inventory non-unclaimed
  for ch in allRomChunksMeta():
    if ch.kind != ckUnclaimed:
      mark(claimed, ch.offset, ch.length)

  var total = 0
  var nSpans = 0

  echo "# --- residual expand wave ---"

  # ---- EF sprite-group mid-record free ----
  block:
    var ptrs: seq[int] = @[]
    for i in 0 ..< EfPtrCount:
      let p = EfPtrTable + i * 4
      if p + 3 >= g.len:
        break
      let fo = farFileOff(g, p)
      if fo >= 0:
        ptrs.add fo
    ptrs.sort(cmp)
    # unique monotonic
    var uniq: seq[int] = @[]
    for p in ptrs:
      if uniq.len == 0 or uniq[^1] != p:
        uniq.add p
    var etot = 0
    var spans = 0
    for i in 0 ..< uniq.len - 1:
      let a = uniq[i]
      let b = uniq[i + 1]
      let ln = b - a
      if ln notin {25, 27, 41}:
        continue
      for r in freeInside(claimed, a, b):
        if r.n < 2:
          continue
        emitSpan(&"table_efSpriteMid_0x{r.o:06X}", r.o, r.n,
          "EF sprite-group mid-record residual @ $EF133F (gap 25/27/41); loaders $C01DF9/$C01E79/$C01FE0/$C07A8B/$C4B1D0; free only")
        mark(claimed, r.o, r.n)
        etot += r.n
        spans += 1
    echo &"  # EF mid residual new: {etot} B in {spans} spans"
    total += etot
    nSpans += spans

  # ---- C4 hitbox free ----
  block:
    var ptrs: seq[int] = @[]
    for i in 0 ..< C4HitPtrCount:
      let p = C4HitPtrTable + i * 4
      let fo = farFileOff(g, p)
      if fo >= 0:
        ptrs.add fo
    ptrs.sort(cmp)
    var uniq: seq[int] = @[]
    for p in ptrs:
      if uniq.len == 0 or uniq[^1] != p:
        uniq.add p
    var ctot = 0
    var spans = 0
    # also free runs inside the ptr table itself if any
    for r in freeInside(claimed, C4HitPtrTable, C4HitPtrTable + C4HitPtrCount * 4):
      if r.n < 2:
        continue
      emitSpan(&"table_c4Hitbox_0x{r.o:06X}", r.o, r.n,
        "C4 hitbox residual @ $C42B0D; loader $C01EBF LDA #$2B0D STA $06 / LDA #$00C4 STA $08; rec=u8 count + u8 + count*10; free only")
      mark(claimed, r.o, r.n)
      ctot += r.n
      spans += 1
    for i in 0 ..< uniq.len - 1:
      let a = uniq[i]
      let b = uniq[i + 1]
      let ln = b - a
      if ln < 2:
        continue
      # validate layout when fully readable
      let cnt = g[a].int
      let expect = 2 + cnt * 10
      let layoutOk = expect == ln or (cnt >= 0 and cnt <= 30 and expect <= ln + 5)
      if not layoutOk and ln > 200:
        continue
      for r in freeInside(claimed, a, b):
        if r.n < 2:
          continue
        emitSpan(&"table_c4Hitbox_0x{r.o:06X}", r.o, r.n,
          "C4 hitbox residual @ $C42B0D; loader $C01EBF LDA #$2B0D STA $06 / LDA #$00C4 STA $08; rec=u8 count + u8 + count*10; free only")
        mark(claimed, r.o, r.n)
        ctot += r.n
        spans += 1
    # trailing after last ptr if inside known body window (~0x042B0D..0x043000)
    if uniq.len > 0:
      let last = uniq[^1]
      let bodyEnd = min(last + 200, 0x043200)
      if last + 2 < bodyEnd:
        let cnt = g[last].int
        let endRec = min(last + 2 + cnt * 10, bodyEnd)
        for r in freeInside(claimed, last, endRec):
          if r.n < 2:
            continue
          emitSpan(&"table_c4Hitbox_0x{r.o:06X}", r.o, r.n,
            "C4 hitbox residual @ $C42B0D; loader $C01EBF; free only (tail rec)")
          mark(claimed, r.o, r.n)
          ctot += r.n
          spans += 1
    echo &"  # C4 hitbox residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  # ---- CF map holey u16 ptrs residual ----
  block:
    var ctot = 0
    var spans = 0
    for r in freeRunsIn(claimed, CfMapPtrLo, CfMapPtrHi):
      # only even-aligned u16 runs
      var o = r.o
      var n = r.n
      if (o and 1) != 0:
        o += 1
        n -= 1
      if n mod 2 != 0:
        n -= 1
      if n < 2:
        continue
      # soft check: most non-zero entries look like bank-local $80xx+
      var good = 0
      var words = 0
      var j = 0
      while j + 1 < n:
        let v = g[o + j].int or (g[o + j + 1].int shl 8)
        words += 1
        if v == 0 or (v >= 0x8000 and v < 0xA000):
          good += 1
        j += 2
      if words > 0 and good * 2 < words:
        continue
      emitSpan(&"table_cfMapPtr_0x{o:06X}", o, n,
        "bank $CF holey u16 map ptr residual; bank-local → count+4n placement; free only")
      mark(claimed, o, n)
      ctot += n
      spans += 1
    echo &"  # CF map ptr residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  # ---- CF 12B obj residual ----
  block:
    var ctot = 0
    var spans = 0
    # scan free runs for complete 12B aligned records with far ptr banks C6-C9
    for r in freeRunsIn(claimed, CfObj12Lo, CfObj12Hi):
      var o = r.o
      let endO = r.o + r.n
      # try each alignment
      while o + 12 <= endO:
        let typ = g[o].int
        let bk = g[o + 11].int
        if typ in 0..3 and bk in 0xC6..0xC9:
          # claim maximal contiguous 12B recs from here
          var n = 0
          var p = o
          while p + 12 <= endO and isFree(claimed, p, 12):
            let t2 = g[p].int
            let b2 = g[p + 11].int
            if t2 notin 0..3 or b2 notin 0xC6..0xC9:
              break
            n += 12
            p += 12
          if n >= 12:
            emitSpan(&"table_cfObj12_0x{o:06X}", o, n,
              "CF 12B object/config residual; type@+0 ∈0..3; far ptr banks $C6-$C9 @+9; free only")
            mark(claimed, o, n)
            ctot += n
            spans += 1
            o = p
            continue
        o += 1
    echo &"  # CF obj12 residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  # ---- C5 14B index residual ----
  block:
    var ctot = 0
    var spans = 0
    var runS = -1
    var runL = 0
    for i in 0 ..< C5IdxCount:
      let o = C5IdxBase + i * C5IdxRec
      if isFree(claimed, o, C5IdxRec):
        if runS < 0:
          runS = o
        runL += C5IdxRec
      else:
        if runL > 0:
          emitSpan(&"table_c5Idx14_0x{runS:06X}", runS, runL,
            "C5 14B index residual @$C5A5B6; far ptr bank $C5 + fixed tail; free only")
          mark(claimed, runS, runL)
          ctot += runL
          spans += 1
        runS = -1
        runL = 0
    if runL > 0:
      emitSpan(&"table_c5Idx14_0x{runS:06X}", runS, runL,
        "C5 14B index residual @$C5A5B6; far ptr bank $C5 + fixed tail; free only")
      mark(claimed, runS, runL)
      ctot += runL
      spans += 1
    echo &"  # C5 idx14 residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  # ---- C5 body residual (ptr-bounded, prefix) ----
  block:
    type PE = tuple[id, f: int]
    var ptrs: seq[PE] = @[]
    for i in 0 ..< C5IdxCount:
      let o = C5IdxBase + i * C5IdxRec
      let lo = g[o].int or (g[o + 1].int shl 8)
      let id = g[o + 6].int
      ptrs.add (id, (0xC5 - 0xC0) * 0x10000 + lo)
    ptrs.sort(proc(a, b: PE): int = cmp(a.f, b.f))
    var uniq: seq[PE] = @[]
    for p in ptrs:
      if uniq.len == 0 or uniq[^1].f != p.f:
        uniq.add p
    var ctot = 0
    var spans = 0
    for i in 0 ..< uniq.len - 1:
      let f = uniq[i].f
      let ln = uniq[i + 1].f - f
      if ln <= 0 or ln > 200:
        continue
      if f + 4 >= g.len:
        continue
      let prefixOk = g[f] == 0x01 and g[f + 1] == 0x50 and g[f + 2] == 0x6C and
          g[f + 3] == 0x1C and g[f + 4] == 0x05
      if not prefixOk:
        continue
      for r in freeInside(claimed, f, f + ln):
        if r.n < 2:
          continue
        emitSpan(&"table_c5Body_0x{r.o:06X}", r.o, r.n,
          &"C5 body residual id~{uniq[i].id}; ptr-bounded from $C5A5B6; prefix 01 50 6C 1C 05; free only")
        mark(claimed, r.o, r.n)
        ctot += r.n
        spans += 1
    echo &"  # C5 body residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  # ---- BBG layer 17B residual ----
  block:
    var ctot = 0
    var spans = 0
    var runS = -1
    var runL = 0
    for i in 0 ..< BbgLayerCount:
      let o = BbgLayerBase + i * BbgLayerRec
      if isFree(claimed, o, BbgLayerRec):
        if runS < 0:
          runS = o
        runL += BbgLayerRec
      else:
        if runL > 0:
          emitSpan(&"table_bbgLayer17_0x{runS:06X}", runS, runL,
            "battle-BG layer table residual 17B/entry @$CADEA1; free only")
          mark(claimed, runS, runL)
          ctot += runL
          spans += 1
        runS = -1
        runL = 0
    if runL > 0:
      emitSpan(&"table_bbgLayer17_0x{runS:06X}", runS, runL,
        "battle-BG layer table residual 17B/entry @$CADEA1; free only")
      mark(claimed, runS, runL)
      ctot += runL
      spans += 1
    # also free mid-record holes (not full 17B aligned) inside table window
    let winEnd = BbgLayerBase + BbgLayerCount * BbgLayerRec
    for r in freeRunsIn(claimed, BbgLayerBase, winEnd):
      if r.n < 2:
        continue
      emitSpan(&"table_bbgLayer17_0x{r.o:06X}", r.o, r.n,
        "battle-BG layer table residual mid-rec hole @$CADEA1 17B; free only")
      mark(claimed, r.o, r.n)
      ctot += r.n
      spans += 1
    echo &"  # BBG layer17 residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  # ---- CADCA1 17B residual (again) ----
  block:
    const
      CaBase = 0x0ADCA1
      CaRec = 17
      CaCount = 280
    var ctot = 0
    var spans = 0
    let winEnd = CaBase + CaCount * CaRec
    for r in freeRunsIn(claimed, CaBase, winEnd):
      if r.n < 2:
        continue
      emitSpan(&"table_caRec17_0x{r.o:06X}", r.o, r.n,
        "CA 17B rec residual @ $CADCA1; loader $C2D1CF X=id*17 LDA.L,X; free only")
      mark(claimed, r.o, r.n)
      ctot += r.n
      spans += 1
    echo &"  # CADCA1 residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  # ---- D7A800 map attr residual ----
  block:
    const
      D7Base = 0x17A800
      D7End = 0x17B200
    var ctot = 0
    var spans = 0
    for r in freeRunsIn(claimed, D7Base, D7End):
      if r.n < 2:
        continue
      emitSpan(&"table_d7MapAttr_0x{r.o:06X}", r.o, r.n,
        "map-attr u8 residual @ $D7A800..$D7B200; loaders $C008F7/…/$C4DFF5 LDA.L,X; free only")
      mark(claimed, r.o, r.n)
      ctot += r.n
      spans += 1
    echo &"  # D7 map-attr residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  # ---- APU pack interiors: free runs inside known pack containers ----
  block:
    # Discover pack containers already claimed as ekApuPackage by grouping notes
    # or re-scan known pack bases from notes in extract list.
    # Pattern: packs are length-prefixed sequences used by APU uploader.
    # We re-read existing apuPack claims and expand free interior within
    # the same pack@ base ranges found in notes.
    var packRanges: seq[tuple[base, size: int]] = @[]
    for s in allBaseromExtractSpans():
      if s.kind != ekApuPackage:
        continue
      # parse "pack@0xXXXXXX size=NNNN"
      let n = s.note
      let a = n.find("pack@0x")
      if a < 0:
        continue
      let hexStart = a + 7
      var hexEnd = hexStart
      while hexEnd < n.len and n[hexEnd] in {'0'..'9', 'A'..'F', 'a'..'f'}:
        hexEnd += 1
      let b = n.find("size=", hexEnd)
      if b < 0:
        continue
      var numEnd = b + 5
      while numEnd < n.len and n[numEnd] in {'0'..'9'}:
        numEnd += 1
      let base = parseHexInt(n[hexStart ..< hexEnd])
      let size = parseInt(n[b + 5 ..< numEnd])
      var found = false
      for p in packRanges:
        if p.base == base:
          found = true
          break
      if not found:
        packRanges.add (base, size)
    var atot = 0
    var spans = 0
    for p in packRanges:
      let lo = p.base
      let hi = p.base + p.size
      if lo < 0 or hi > g.len:
        continue
      for r in freeRunsIn(claimed, lo, hi):
        if r.n < 4:
          continue
        emitApu(&"apuPack_0x{r.o:06X}", r.o, r.n,
          &"APU pack interior residual (pack@0x{p.base:06X} size={p.size}); container-bounded")
        mark(claimed, r.o, r.n)
        atot += r.n
        spans += 1
    echo &"  # APU pack interior residual new: {atot} B in {spans} spans ({packRanges.len} known packs)"
    total += atot
    nSpans += spans

  # ---- formPtr 8B residual mid-table ----
  block:
    const
      FormPtr = 0x10C60D
      FormCount = 484
      FormRec = 8
    var ctot = 0
    var spans = 0
    let winEnd = FormPtr + FormCount * FormRec
    for r in freeRunsIn(claimed, FormPtr, winEnd):
      if r.n < 2:
        continue
      emitSpan(&"table_formPtr_0x{r.o:06X}", r.o, r.n,
        "battle-formation ptr residual 8B (far $D0 + 4B assoc) @$D0C60D; free only")
      mark(claimed, r.o, r.n)
      ctot += r.n
      spans += 1
    echo &"  # formPtr residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  # ---- enemy arrange mid residual ----
  block:
    const
      ArrPtr = 0x10B880
      ArrCount = 203
      ArrRec = 4
      ArrBodyEnd = 0x10C60D
    var ctot = 0
    var spans = 0
    # pointer table free
    for r in freeRunsIn(claimed, ArrPtr, ArrPtr + ArrCount * ArrRec):
      if r.n < 2:
        continue
      emitSpan(&"table_owEnemyArr_0x{r.o:06X}", r.o, r.n,
        "overworld enemy-arrangement residual @$D0B880; free only")
      mark(claimed, r.o, r.n)
      ctot += r.n
      spans += 1
    # body free between first target and form ptr table
    for r in freeRunsIn(claimed, 0x10BBAC, ArrBodyEnd):
      if r.n < 2:
        continue
      emitSpan(&"table_owEnemyArr_0x{r.o:06X}", r.o, r.n,
        "overworld enemy-arrangement body residual; free only")
      mark(claimed, r.o, r.n)
      ctot += r.n
      spans += 1
    echo &"  # owEnemyArr residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  # ---- item / shop / exp residual ----
  block:
    var ctot = 0
    var spans = 0
    # item 254 * 0x27 @ 0x155000
    for r in freeRunsIn(claimed, 0x155000, 0x155000 + 254 * 0x27):
      if r.n < 2: continue
      emitSpan(&"table_item_0x{r.o:06X}", r.o, r.n,
        "item table residual 0x27B/rec @$D55000; free only")
      mark(claimed, r.o, r.n)
      ctot += r.n
      spans += 1
    for r in freeRunsIn(claimed, 0x1578B2, 0x1578B2 + 66 * 7):
      if r.n < 2: continue
      emitSpan(&"table_shop_0x{r.o:06X}", r.o, r.n,
        "shop table residual 7B/rec @$D578B2; free only")
      mark(claimed, r.o, r.n)
      ctot += r.n
      spans += 1
    for r in freeRunsIn(claimed, 0x158F51, 0x158F51 + 4 * 0x190):
      if r.n < 2: continue
      emitSpan(&"table_exp_0x{r.o:06X}", r.o, r.n,
        "EXP-per-level residual u32 LE @$D58F51; free only")
      mark(claimed, r.o, r.n)
      ctot += r.n
      spans += 1
    echo &"  # item/shop/exp residual new: {ctot} B in {spans} spans"
    total += ctot
    nSpans += spans

  echo &"\n# WAVE TOTAL residual claimable: {total} B in {nSpans} spans"

  # ---- Top residual free runs still unclaimed ----
  echo "\n# === top 20 residual free runs (post-claim mask) ==="
  var runs: seq[tuple[o, n: int]] = @[]
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
        runs.add (rs, rl)
        rs = -1
  if rs >= 0:
    runs.add (rs, rl)
  runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))
  var unc = 0
  for r in runs:
    unc += r.n
  echo &"# total unclaimed after this wave's proposed claims: {unc} B ({runs.len} runs)"
  for i in 0 ..< min(20, runs.len):
    let r = runs[i]
    var hx = ""
    for j in 0 ..< min(16, r.n):
      hx.add &"{g[r.o + j]:02X} "
    let bank = 0xC0 + (r.o div 0x10000)
    echo &"#  {i+1:2}. 0x{r.o:06X}+{r.n:5}  ${bank:02X}:{r.o and 0xFFFF:04X}  head {hx}"

main()
