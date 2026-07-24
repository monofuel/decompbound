## Tests for baserom extract metadata + gold slice equality.
## Structural checks always run. Live gold checks run when baserom is present.

import
  std/[algorithm, strformat, strutils],
  decompbound/[action_script, baserom_extract, common, gfx_lz, rom_chunks, text_decode]

echo "[test_baserom_extract] begin"

block extractMetaStructural:
  ## Claims are non-empty, in-bounds, non-overlapping, unique names.
  let spans = allBaseromExtractSpans()
  doAssert spans.len == KnownBaseromExtracts.len
  doAssert spans.len > 0
  var ordered = spans
  ordered.sort(proc(a, b: BaseromExtractSpan): int = cmp(a.offset, b.offset))
  var names: seq[string] = @[]
  var endPos = -1
  var total = 0
  for s in ordered:
    doAssert s.name.len > 0
    doAssert s.offset >= 0
    doAssert s.length > 0
    doAssert s.offset + s.length <= EarthboundRomSize
    doAssert s.name notin names, "duplicate extract name " & s.name
    names.add s.name
    doAssert s.offset >= endPos, &"extract overlap at 0x{s.offset:06X}"
    endPos = s.offset + s.length
    total += s.length
  doAssert total == totalBaseromExtractBytes()
  doAssert totalBaseromExtractBytes() > 10_000

block extractInInventoryAsMeta:
  ## collectImplementedSpanMeta includes extracts as ckImplementedMeta.
  let meta = collectImplementedSpanMeta()
  var found = 0
  for s in allBaseromExtractSpans():
    var hit = false
    for m in meta:
      if m.name == s.name and m.offset == s.offset and m.length == s.length:
        doAssert m.kind == ckImplementedMeta, s.name
        hit = true
        break
    doAssert hit, "missing extract in span meta: " & s.name
    found += 1
  doAssert found == allBaseromExtractSpans().len

  ## Full inventory still covers the ROM with no overlap.
  let chunks = allRomChunksMeta()
  doAssert inventoryCoversRom(chunks)
  for s in allBaseromExtractSpans():
    let c = findChunkAt(chunks, s.offset)
    doAssert c.kind == ckImplementedMeta, s.name
    doAssert c.offset == s.offset
    doAssert c.length == s.length

block extractNoOverlapCodeSpans:
  ## Extract claims must not sit inside implemented_code chunks.
  let chunks = allRomChunksMeta()
  for s in allBaseromExtractSpans():
    for off in [s.offset, s.offset + s.length - 1]:
      let c = findChunkAt(chunks, off)
      doAssert c.kind != ckImplementedCode,
        &"{s.name} overlaps code at 0x{off:06X} ({c.id})"

block liveGoldSliceMatch:
  ## extractGoldSlice equals gold[offset..offset+len) for every claim.
  if not goldBaseromAvailable():
    echo "[test_baserom_extract] skip live gold (no baserom)"
  else:
    let gold = readGoldBaseromBytes()
    for s in allBaseromExtractSpans():
      let got = extractGoldSlice(s.offset, s.length)
      doAssert got.len == s.length
      for i in 0..<s.length:
        doAssert got[i] == gold[s.offset + i],
          &"{s.name} mismatch at +{i}"
    echo "[test_baserom_extract] live gold: ",
      allBaseromExtractSpans().len, " extracts match baserom slices"

block liveGfxLzStreamLengths:
  ## Claimed gfx_lz lengths must match decodeWithConsumed.clean + consumed.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var n = 0
    for s in allBaseromExtractSpans():
      if s.kind != ekGfxLz:
        continue
      let hi = min(s.offset + 0x10000, gold.len)
      let (decoded, consumed, clean) = decodeWithConsumed(gold[s.offset ..< hi])
      doAssert clean, s.name & " gfx_lz did not terminate cleanly"
      doAssert consumed == s.length,
        &"{s.name}: claimed {s.length} but consumed {consumed}"
      doAssert decoded.len >= 64, s.name
      n += 1
    doAssert n > 0
    echo "[test_baserom_extract] gfx_lz stream lengths verified: ", n

block liveApuPackageGap:
  ## APU pack gap is package-container bytes (pack 21 tail + pack 5 head).
  if not goldBaseromAvailable():
    discard
  else:
    const
      GapOff = 0x2B51D5
      GapLen = 269
      Pack5 = 0x2B520C
    doAssert isBaseromExtractOffset(GapOff)
    let slice = extractGoldSlice(GapOff, GapLen)
    # Pack 5 header at relative +0x37: len=112 (0x0070), tgt=0x6C00
    let rel = Pack5 - GapOff
    doAssert rel == 0x37
    let ln = int(slice[rel]) or (int(slice[rel + 1]) shl 8)
    let tgt = int(slice[rel + 2]) or (int(slice[rel + 3]) shl 8)
    doAssert ln == 112, &"pack5 len got {ln}"
    doAssert tgt == 0x6C00, &"pack5 tgt got 0x{tgt:04X}"
    # Terminator of pack 21 immediately before pack 5: 00 00 at 0x2B520A
    let termRel = 0x2B520A - GapOff
    doAssert slice[termRel] == 0 and slice[termRel + 1] == 0
    echo "[test_baserom_extract] APU package gap container checks OK"

block liveEnemyArrangementTable:
  ## Overworld enemy-arrangement: 203×4 far ptrs @0x10B880 → records @0x10BBAC.
  ## Record = u16 meta0 + u16 meta1 + n×(u8 weight, u16 group); body len % 3 == 0;
  ## weight sums are 0, 8, or 16. Table ends where formation ptrs begin (0x10C60D).
  if not goldBaseromAvailable():
    discard
  else:
    const
      PtrOff = 0x10B880
      PtrCount = 203
      PtrEntry = 4
      DataOff = 0x10BBAC
      DataEnd = 0x10C60D
    let gold = readGoldBaseromBytes()
    doAssert PtrOff + PtrCount * PtrEntry == DataOff
    var targets: seq[int] = @[]
    for i in 0..<PtrCount:
      let o = PtrOff + i * PtrEntry
      let lo = int(gold[o]) or (int(gold[o + 1]) shl 8)
      let bank = int(gold[o + 2])
      doAssert bank == 0xD0, &"arr ptr[{i}] bank ${bank:02X}"
      doAssert gold[o + 3] == 0
      let fo = 0x100000 + lo
      targets.add fo
      doAssert fo >= DataOff and fo < DataEnd, &"arr ptr[{i}] fo=0x{fo:06X}"
    for i in 1..<targets.len:
      doAssert targets[i] >= targets[i - 1]
    var sumOk = 0
    for i in 0..<targets.len:
      let fo = targets[i]
      let hi = if i + 1 < targets.len: targets[i + 1] else: DataEnd
      let recLen = hi - fo
      doAssert recLen >= 4, &"arr rec[{i}] short"
      doAssert (recLen - 4) mod 3 == 0, &"arr rec[{i}] body not ×3"
      var wsum = 0
      let n = (recLen - 4) div 3
      for j in 0..<n:
        wsum += int(gold[fo + 4 + 3 * j])
      doAssert wsum in [0, 8, 16], &"arr rec[{i}] weight sum {wsum}"
      sumOk += 1
    doAssert sumOk == PtrCount
    # Focus gaps claimed as ekTable
    doAssert isBaseromExtractOffset(0x10BEC5)
    doAssert isBaseromExtractOffset(0x10C2DF)
    var tableBytes = 0
    for s in allBaseromExtractSpans():
      if s.kind == ekTable and s.offset >= PtrOff and s.offset < DataEnd:
        tableBytes += s.length
    doAssert tableBytes >= 1000, &"expected enemy-arr table claims, got {tableBytes}"
    echo "[test_baserom_extract] enemy arrangement table OK: ",
      PtrCount, " ptrs, ", sumOk, " records, claimed≥", tableBytes

block liveFormationPointerTable:
  ## Battle formation index: 484×8 entries @0x10C60D → FF-terminated data @0x10D52D.
  if not goldBaseromAvailable():
    discard
  else:
    const
      PtrOff = 0x10C60D
      PtrEntry = 8
      DataOff = 0x10D52D
    let gold = readGoldBaseromBytes()
    let ptrCount = (DataOff - PtrOff) div PtrEntry
    doAssert PtrOff + ptrCount * PtrEntry == DataOff
    doAssert ptrCount == 484
    var targets: seq[int] = @[]
    for i in 0..<ptrCount:
      let o = PtrOff + i * PtrEntry
      let lo = int(gold[o]) or (int(gold[o + 1]) shl 8)
      doAssert gold[o + 2] == 0xD0
      doAssert gold[o + 3] == 0
      targets.add(0x100000 + lo)
    for i in 1..<targets.len:
      doAssert targets[i] >= targets[i - 1]
    doAssert targets[0] == DataOff
    var ffOk = 0
    for i in 0..<targets.len - 1:
      let fo = targets[i]
      let hi = targets[i + 1]
      var sawFf = false
      for j in fo..<hi:
        if gold[j] == 0xFF:
          sawFf = true
          break
      doAssert sawFf, &"formation[{i}] @0x{fo:06X} missing 0xFF"
      ffOk += 1
    # last record has FF within a short window
    block:
      var saw = false
      for j in targets[^1] ..< targets[^1] + 32:
        if gold[j] == 0xFF:
          saw = true
          break
      doAssert saw
    doAssert isBaseromExtractOffset(0x10CBF4) or isBaseromExtractOffset(0x10C615)
    echo "[test_baserom_extract] formation pointer table OK: ",
      ptrCount, " entries, ", ffOk, " FF-terminated spans"


block liveScriptStreamClaims:
  ## Every ekScriptStream claim is fully covered by consecutive good CC walks.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var n = 0
    var total = 0
    for s in allBaseromExtractSpans():
      if s.kind != ekScriptStream:
        continue
      let consumed = consumeScriptStreamRun(gold, s.offset, s.length)
      doAssert consumed == s.length,
        &"{s.name}: script run covered {consumed}/{s.length}"
      doAssert gold[s.offset + s.length - 1] == 0,
        &"{s.name}: must end on 0x00 terminator"
      n += 1
      total += s.length
    doAssert n > 0
    doAssert total > 10_000
    echo "[test_baserom_extract] script_stream claims verified: ", n,
      " spans, ", total, " bytes"


block liveActionScriptClaims:
  ## Every ekActionScript claim is fully covered by good action-script walks.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var n = 0
    var total = 0
    for s in allBaseromExtractSpans():
      if s.kind != ekActionScript:
        continue
      doAssert isGoodActionScriptSpan(gold, s.offset, s.length),
        &"{s.name}: action-script span failed structural gates"
      n += 1
      total += s.length
    doAssert n > 0
    doAssert total > 1000
    # Documented idle block at file 0x3A076 (may sit in implemented_code).
    doAssert isIdleActionBlock(gold, 0x3A076)
    let idle = walkActionScript(gold, 0x3A076, 0x3A076 + 9)
    doAssert isGoodActionScriptWalk(idle)
    doAssert idle.length == 9
    echo "[test_baserom_extract] action_script claims verified: ", n,
      " spans, ", total, " bytes"

block liveResidualFixedTables:
  ## Residual unclaimed ekTable claims for item/shop/EXP/formPtr (2026-07-24 wave).
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    # Item table: Cookie id=88 price $7, Bread roll id=103 price $12, Hamburger id=90 $14
    const
      ItemBase = 0x155000
      ItemRec = 0x27
    doAssert (int(gold[ItemBase + 88 * ItemRec + 0x1A]) or
      (int(gold[ItemBase + 88 * ItemRec + 0x1B]) shl 8)) == 7
    doAssert (int(gold[ItemBase + 103 * ItemRec + 0x1A]) or
      (int(gold[ItemBase + 103 * ItemRec + 0x1B]) shl 8)) == 12
    doAssert (int(gold[ItemBase + 90 * ItemRec + 0x1A]) or
      (int(gold[ItemBase + 90 * ItemRec + 0x1B]) shl 8)) == 14
    doAssert isBaseromExtractOffset(0x155C55)
    # Shops: residual gaps claimed
    doAssert isBaseromExtractOffset(0x1578B8)
    doAssert isBaseromExtractOffset(0x1578D7)
    const ShopBase = 0x1578B2
    doAssert gold[ShopBase + 6] == 0xD1  # shop0 last slot
    # EXP tables: 4×0x190 blocks; levels 0..97 non-decreasing (tail is padding).
    const ExpBase = 0x158F51
    for ch in 0..2:
      var prev = 0'u32
      let b = ExpBase + ch * 0x190
      for lv in 0..97:
        let o = b + lv * 4
        let v = uint32(gold[o]) or (uint32(gold[o + 1]) shl 8) or
          (uint32(gold[o + 2]) shl 16) or (uint32(gold[o + 3]) shl 24)
        doAssert lv == 0 or v >= prev, &"exp char{ch} lv{lv}"
        prev = v
    doAssert isBaseromExtractOffset(0x1591F8)
    # formPtr residual assoc halves
    doAssert isBaseromExtractOffset(0x10C634)
    var formResidual = 0
    for s in allBaseromExtractSpans():
      if s.kind == ekTable and s.name.startsWith("table_formPtr_") and
          s.offset >= 0x10C60D and s.offset < 0x10D52D:
        formResidual += s.length
    doAssert formResidual >= 900, &"formPtr residual claims {formResidual}"
    echo "[test_baserom_extract] residual fixed tables OK: formPtr residual≥",
      formResidual

block liveU16PtrTableF59:
  ## 36 bank-local u16 ptrs @0x0F59F1 → records @0x0F6075 with prefix 49 80 5d 00.
  if not goldBaseromAvailable():
    discard
  else:
    const
      PtrOff = 0x0F59F1
      BankBase = 0x0F0000
      N = 36
    let gold = readGoldBaseromBytes()
    var targets: seq[int] = @[]
    for i in 0..<N:
      let lo = int(gold[PtrOff + i * 2]) or (int(gold[PtrOff + i * 2 + 1]) shl 8)
      targets.add(BankBase + lo)
    for i in 1..<targets.len:
      doAssert targets[i] >= targets[i - 1]
    doAssert targets[0] == 0x0F6075
    for i in 0..<min(8, targets.len):
      doAssert gold[targets[i]] == 0x49
      doAssert gold[targets[i] + 1] == 0x80
      doAssert gold[targets[i] + 2] == 0x5d
      doAssert gold[targets[i] + 3] == 0x00
    doAssert isBaseromExtractOffset(PtrOff)
    echo "[test_baserom_extract] u16 ptr table @0x0F59F1 OK: ", N, " entries"

block liveFfShortRecordStreams:
  ## FF-terminated short-record residual claims in bank $CE.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var n = 0
    var total = 0
    for s in allBaseromExtractSpans():
      if s.kind != ekTable or not s.name.startsWith("table_ffRec_"):
        continue
      var i = s.offset
      let hi = s.offset + s.length
      var recs = 0
      while i < hi:
        let rs = i
        var found = false
        while i < hi and i - rs < 24:
          if gold[i] == 0xFF:
            found = true
            i += 1
            break
          i += 1
        doAssert found, &"{s.name}: missing FF in record @0x{rs:06X}"
        let L = i - rs
        doAssert L >= 2 and L <= 16, &"{s.name}: bad rec len {L}"
        recs += 1
      doAssert recs >= 1
      n += 1
      total += s.length
    doAssert n >= 6, &"expected ≥6 ffRec claims, got {n}"
    doAssert total >= 400, &"expected ≥400 ffRec bytes, got {total}"
    echo "[test_baserom_extract] FF short-record streams OK: ", n,
      " spans, ", total, " bytes"

block liveCfProgramPool:
  ## Residual 4-byte-word program pool for u16 ptr table @0x0F59F1.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var n = 0
    var total = 0
    for s in allBaseromExtractSpans():
      if s.kind != ekTable or not s.name.startsWith("table_cfProg_"):
        continue
      doAssert s.length mod 4 == 0, &"{s.name}: not 4-byte aligned length"
      var zeroHi = 0
      var words = s.length div 4
      for i in 0..<words:
        if gold[s.offset + i * 4 + 3] == 0:
          zeroHi += 1
      doAssert zeroHi * 4 >= words * 3, &"{s.name}: low zero-high density"
      n += 1
      total += s.length
    doAssert n >= 1, &"expected ≥1 cfProg claims, got {n}"
    doAssert total >= 400, &"expected ≥400 cfProg bytes, got {total}"
    echo "[test_baserom_extract] CF program pool residual OK: ", n,
      " spans, ", total, " bytes"
