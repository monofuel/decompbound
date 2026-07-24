## Emit BaseromExtractSpan entries for D7A800 map-attr residual + CADCA1 17B residual.

import
  std/[algorithm, strformat],
  ../decompbound/[rom_chunks]

const
  Gold = "bin/Earthbound (U) [!].smc"
  D7Base = 0x17A800
  D7End = 0x17B200  # abuts D7B200 tile-prop table
  CaBase = 0x0ADCA1
  CaRec = 17
  CaCount = 280  # structure-stable ids 0..159 (loader X = id*17)

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0..<n:
    if o + j < c.len: c[o + j] = true

proc freeRuns(claimed: seq[bool]; lo, hi: int): seq[tuple[o, n: int]] =
  result = @[]
  var rs = -1
  var rl = 0
  for o in lo ..< hi:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0:
        result.add (rs, rl)
        rs = -1
  if rs >= 0: result.add (rs, rl)

proc main() =
  let g = readFile(Gold)
  var claimed = newSeq[bool](g.len)
  for ch in allRomChunksMeta():
    if ch.kind != ckUnclaimed:
      mark(claimed, ch.offset, ch.length)

  var total = 0
  echo "  # --- dense-bank loader residual wave ---"

  # D7A800 map attr
  let d7 = freeRuns(claimed, D7Base, D7End)
  var d7tot = 0
  for r in d7:
    d7tot += r.n
    echo &"""  BaseromExtractSpan(
    name: "table_d7MapAttr_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekTable,
    note: "map-attr u8 residual @ $D7A800..$D7B200; loaders $C008F7/$C00B24/…/$C4DFF5 LDA.L,X; AND #$00FF"),"""
  total += d7tot
  echo &"  # D7 map-attr residual total: {d7tot} B in {d7.len} runs"

  # CADCA1 17B
  let caEnd = CaBase + CaCount * CaRec
  let ca = freeRuns(claimed, CaBase, caEnd)
  var catot = 0
  for r in ca:
    catot += r.n
    echo &"""  BaseromExtractSpan(
    name: "table_caRec17_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekTable,
    note: "CA 17B rec residual @ $CADCA1; loader $C2D1CF X=id*17 LDA.L,X; mid-table free only"),"""
  total += catot
  echo &"  # CADCA1 residual total: {catot} B in {ca.len} runs (table ids 0..{CaCount-1})"

  # CEDC45 ptr table residual (9B) if free
  let ptrBase = 0x0EDC45
  let ptrEnd = ptrBase + 126 * 2
  let pr = freeRuns(claimed, ptrBase, ptrEnd)
  var ptot = 0
  for r in pr:
    if r.n < 2: continue
    # only even-aligned complete u16s
    var o = r.o
    var n = r.n
    if (o - ptrBase) mod 2 != 0:
      o += 1; n -= 1
    if n mod 2 != 0: n -= 1
    if n < 2: continue
    ptot += n
    echo &"""  BaseromExtractSpan(
    name: "table_cePtr_0x{o:06X}",
    offset: 0x{o:06X},
    length: {n},
    kind: ekTable,
    note: "CE u16 bank-local ptr residual @ $CEDC45; loader $C4AA97 LDA.L,X id*2"),"""
  total += ptot
  echo &"  # CEDC45 ptr residual total: {ptot} B"

  # Also claim residual free runs that are COMPLETE 17B-aligned inside CA table
  # (already included in freeRuns)

  echo &"\n# WAVE TOTAL residual claimable: {total} B"

  # Overlap check vs code spans
  echo "\n# Overlap verification: all claim offsets must be unclaimed"
  var bad = 0
  for r in d7:
    for j in 0..<r.n:
      if claimed[r.o + j]: bad += 1
  for r in ca:
    for j in 0..<r.n:
      if claimed[r.o + j]: bad += 1
  echo &"# bad overlapping bytes: {bad}"

main()
