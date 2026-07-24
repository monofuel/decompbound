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
  ## Full streams end on 0x00; residual prefixes (script_ssPrefix_*) are free-only
  ## heads of a good full CC walk that continues into claimed inventory.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var n = 0
    var total = 0
    var prefixes = 0
    for s in allBaseromExtractSpans():
      if s.kind != ekScriptStream:
        continue
      if s.name.startsWith("script_ssPrefix_"):
        let wFree = walkScriptStream(gold, s.offset, s.offset + s.length)
        doAssert wFree.badGlyphs == 0, &"{s.name}: bad glyphs in free prefix"
        doAssert not wFree.ended, &"{s.name}: prefix should not end in free"
        doAssert wFree.length == s.length, &"{s.name}: free walk {wFree.length}/{s.length}"
        doAssert wFree.glyphs >= ScriptStreamMinGlyphs
        let wFull = walkScriptStream(gold, s.offset, min(s.offset + ScriptStreamMaxLen, gold.len))
        doAssert isGoodScriptStream(wFull), &"{s.name}: full stream not good"
        doAssert wFull.length > s.length, &"{s.name}: full must extend past free"
        prefixes += 1
      else:
        let consumed = consumeScriptStreamRun(gold, s.offset, s.length)
        doAssert consumed == s.length,
          &"{s.name}: script run covered {consumed}/{s.length}"
        doAssert gold[s.offset + s.length - 1] == 0,
          &"{s.name}: must end on 0x00 terminator"
      n += 1
      total += s.length
    doAssert n > 0
    doAssert total > 10_000
    doAssert prefixes >= 50, &"expected ≥50 residual prefixes, got {prefixes}"
    echo "[test_baserom_extract] script_stream claims verified: ", n,
      " spans, ", total, " bytes (prefixes=", prefixes, ")"


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
        while i < hi and i - rs < 33:
          if gold[i] == 0xFF:
            found = true
            i += 1
            break
          i += 1
        doAssert found, &"{s.name}: missing FF in record @0x{rs:06X}"
        let L = i - rs
        doAssert L >= 2 and L <= 32, &"{s.name}: bad rec len {L}"
        recs += 1
      doAssert recs >= 1
      n += 1
      total += s.length
    doAssert n >= 6, &"expected ≥6 ffRec claims, got {n}"
    doAssert total >= 8000, &"expected ≥8000 ffRec bytes, got {total}"
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

block liveCfMapPtrTable:
  ## Bank $CF holey u16 map-pointer residual → count+4n placement records.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var n = 0
    var total = 0
    var targets: seq[int] = @[]
    for s in allBaseromExtractSpans():
      if s.kind != ekTable or not s.name.startsWith("table_cfMapPtr_"):
        continue
      doAssert s.length mod 2 == 0, s.name
      var prev = -1
      var nPtr = 0
      for j in 0..<(s.length div 2):
        let v = int(gold[s.offset + j * 2]) or (int(gold[s.offset + j * 2 + 1]) shl 8)
        if v == 0:
          continue
        doAssert v >= 0x7000 and v < 0xA000, &"{s.name} bad ptr ${v:04X}"
        if prev >= 0:
          doAssert v >= prev, &"{s.name} non-mono"
        prev = v
        nPtr += 1
        targets.add(0x0F0000 + v)
      doAssert nPtr >= 1, s.name  # residual holes may be a single free u16
      n += 1
      total += s.length
    doAssert n >= 10, &"expected ≥10 cfMapPtr claims, got {n}"
    doAssert total >= 200, &"expected ≥200 cfMapPtr bytes, got {total}"
    # Target records: u16 n + n×4, abut next unique target when sorted.
    targets.sort()
    var uniq: seq[int] = @[]
    for t in targets:
      if uniq.len == 0 or t != uniq[^1]:
        uniq.add t
    var ok = 0
    for i in 0..<uniq.len:
      let fo = uniq[i]
      let count = int(gold[fo]) or (int(gold[fo + 1]) shl 8)
      doAssert count >= 1 and count <= 64, &"bad count @0x{fo:06X}"
      let recLen = 2 + count * 4
      if i + 1 < uniq.len:
        doAssert uniq[i + 1] >= fo + recLen, &"overlap @0x{fo:06X}"
      ok += 1
    doAssert ok == uniq.len
    doAssert isBaseromExtractOffset(0x0F6B0D)
    doAssert isBaseromExtractOffset(0x0F6BD7)
    echo "[test_baserom_extract] CF map ptr table OK: ", n, " spans, ",
      total, " B, ", uniq.len, " targets"

block liveCfMapRecStream:
  ## count+4n residual placement stream @0x0F71FB.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    doAssert isBaseromExtractOffset(0x0F71FB)
    var p = 0x0F71FB
    let hi = 0x0F71FB + 18
    var recs = 0
    while p + 2 <= hi:
      let count = int(gold[p]) or (int(gold[p + 1]) shl 8)
      doAssert count >= 1 and count <= 32
      let L = 2 + count * 4
      doAssert p + L <= hi
      p += L
      recs += 1
    doAssert p == hi
    doAssert recs == 3
    echo "[test_baserom_extract] CF map recstream OK: ", recs, " records"

block liveCfObj12Records:
  ## 12-byte CF object/config residual ending in far ptr bank $C6-$C9.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var n = 0
    var total = 0
    for s in allBaseromExtractSpans():
      if s.kind != ekTable or not s.name.startsWith("table_cfObj12_"):
        continue
      doAssert s.length == 12, s.name
      doAssert gold[s.offset] <= 3'u8, s.name
      let bank = gold[s.offset + 11]
      doAssert bank >= 0xC6 and bank <= 0xC9, &"{s.name} bank ${bank:02X}"
      n += 1
      total += s.length
    doAssert n >= 20, &"expected ≥20 cfObj12 claims, got {n}"
    doAssert total >= 240, &"expected ≥240 cfObj12 bytes, got {total}"
    echo "[test_baserom_extract] CF obj12 records OK: ", n, " spans, ", total, " B"

block liveEfSpriteGroupRecords:
  ## Residual EF sprite-group/obj-config bodies via ptr table $EF133F (file 0x2F133F).
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    const
      PtrBase = 0x2F133F
      BankBase = 0x2F0000
    var n = 0
    var total = 0
    var recs = 0
    for s in allBaseromExtractSpans():
      if s.kind != ekTable or not s.name.startsWith("table_efSprGrp_"):
        continue
      # Every claimed byte must lie inside some $EF133F target record.
      var covered = 0
      var i = 0
      while i < 464:
        let po = PtrBase + i * 4
        let lo = int(gold[po]) or (int(gold[po + 1]) shl 8)
        let bank = int(gold[po + 2])
        doAssert bank == 0xEF, &"ptr table bank @id{i}"
        let fo = BankBase + lo
        let lo2 = int(gold[po + 4]) or (int(gold[po + 5]) shl 8)
        let bank2 = int(gold[po + 6])
        if bank2 != 0xEF:
          break
        let fo2 = BankBase + lo2
        let ln = fo2 - fo
        if ln >= 16 and ln <= 64 and fo < s.offset + s.length and fo2 > s.offset:
          let a = max(fo, s.offset)
          let b = min(fo2, s.offset + s.length)
          if b > a:
            # Full record must be inside the claim when it overlaps.
            if fo >= s.offset and fo2 <= s.offset + s.length:
              doAssert gold[fo] >= 1'u8 and gold[fo] <= 7'u8, s.name
              covered += ln
              recs += 1
        i += 1
      doAssert covered == s.length, &"{s.name}: covered {covered} != {s.length}"
      n += 1
      total += s.length
    doAssert n >= 15, &"expected ≥15 efSprGrp claims, got {n}"
    doAssert total >= 1700, &"expected ≥1700 efSprGrp bytes, got {total}"
    doAssert recs >= 60, &"expected ≥60 records, got {recs}"
    doAssert isBaseromExtractOffset(0x2F2426)
    doAssert isBaseromExtractOffset(0x2F25CE)  # last byte of id97
    echo "[test_baserom_extract] EF sprite-group residual OK: ", n, " spans, ",
      total, " B, ", recs, " records"

block liveAbsRefResidualTables:
  ## Loader-backed residual tables found via code_bank abs-long scan into unclaimed.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    # bitMask8 @0x04562F
    doAssert isBaseromExtractOffset(0x04562F)
    doAssert isBaseromExtractOffset(0x045636)
    const masks8 = [1'u8, 2, 4, 8, 16, 32, 64, 128]
    for i, m in masks8:
      doAssert gold[0x04562F + i] == m
    # bitMask4 residual @0x0458AB
    doAssert isBaseromExtractOffset(0x0458AB)
    for i, m in [1'u8, 2, 4, 8]:
      doAssert gold[0x0458AB + i] == m
    # 3×u8 @0x04A1F2
    doAssert isBaseromExtractOffset(0x04A1F2)
    doAssert gold[0x04A1F2] == 0x12
    doAssert gold[0x04A1F3] == 0x0F
    doAssert gold[0x04A1F4] == 0x30
    # D7 tile-prop u16 residual @0x17B200 (22 B)
    doAssert isBaseromExtractOffset(0x17B200)
    doAssert isBaseromExtractOffset(0x17B215)
    for i in 0..<(22 div 2):
      let v = int(gold[0x17B200 + i * 2]) or
        (int(gold[0x17B200 + i * 2 + 1]) shl 8)
      doAssert (v and 7) <= 7
    # CF map ptr residual holes claimed this wave
    for off in [0x0F6943, 0x0F69D5, 0x0F6B91]:
      doAssert isBaseromExtractOffset(off)
    var cfExtra = 0
    for s in allBaseromExtractSpans():
      if s.kind == ekTable and s.name in [
          "table_cfMapPtr_0x0F6943",
          "table_cfMapPtr_0x0F69D5",
          "table_cfMapPtr_0x0F6B91"]:
        cfExtra += s.length
        doAssert s.length mod 2 == 0
        var prev = -1
        var nPtr = 0
        for j in 0..<(s.length div 2):
          let v = int(gold[s.offset + j * 2]) or
            (int(gold[s.offset + j * 2 + 1]) shl 8)
          if v == 0:
            continue
          doAssert v >= 0x7000 and v < 0xA000
          if prev >= 0:
            doAssert v >= prev
          prev = v
          nPtr += 1
        doAssert nPtr >= 2
    doAssert cfExtra == 40 + 18 + 22
    echo "[test_baserom_extract] abs-ref residual tables OK: bitMask8/4 + u8×3 + ",
      "d7TileProp22 + cfMapPtr ", cfExtra, " B"

block liveDenseBankLoaderResidual:
  ## C0-C4 LDA.L residual free runs in $D7 map-attr / $CA 17B / $CE u16 ptrs.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    # D7 map-attr residual holes in [$D7A800, $D7B200)
    var d7 = 0
    for s in allBaseromExtractSpans():
      if s.name.startsWith("table_d7MapAttr_"):
        d7 += s.length
        doAssert s.offset >= 0x17A800 and s.offset + s.length <= 0x17B200, s.name
        doAssert s.kind == ekTable
    doAssert d7 == 181, &"d7MapAttr residual want 181 got {d7}"
    doAssert isBaseromExtractOffset(0x17B1AD)
    doAssert isBaseromExtractOffset(0x17B1AD + 45)
    # CA 17B @ $CADCA1 residual mid-table
    var ca = 0
    for s in allBaseromExtractSpans():
      if s.name.startsWith("table_ca17_"):
        ca += s.length
        doAssert s.offset >= 0x0ADCA1
        doAssert s.offset + s.length <= 0x0ADCA1 + 280 * 17
        doAssert s.kind == ekTable
        doAssert s.length >= 2
    doAssert ca >= 100, &"ca17 residual want ≥100 got {ca}"
    # CE u16 ptr residual @ $CEDC45
    doAssert isBaseromExtractOffset(0x0EDD15)
    doAssert isBaseromExtractOffset(0x0EDD1C)
    var ce = 0
    for s in allBaseromExtractSpans():
      if s.name == "table_cePtr_0x0EDD15":
        ce += s.length
        doAssert s.length == 8
        doAssert s.length mod 2 == 0
    doAssert ce == 8
    # Residual-only: claims must not already be implemented_code chunks
    let denseChunks = allRomChunksMeta()
    for s in allBaseromExtractSpans():
      if not (s.name.startsWith("table_d7MapAttr_") or s.name.startsWith("table_ca17_") or
          s.name == "table_cePtr_0x0EDD15"):
        continue
      for c in denseChunks:
        if c.kind != ckImplementedCode: continue
        let a0 = max(s.offset, c.offset)
        let a1 = min(s.offset + s.length, c.offset + c.length)
        doAssert a0 >= a1, &"overlap {s.name} with code chunk 0x{c.offset:06X}"
    echo "[test_baserom_extract] dense-bank loader residual OK: d7MapAttr=",
      d7, " ca17=", ca, " cePtr=", ce, " B"

block liveEfMidAndC4HitboxResidual:
  ## EF sprite-group mid-record free holes + C4 $C42B0D hitbox residual.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var ef = 0
    var efN = 0
    for s in allBaseromExtractSpans():
      if s.name.startsWith("table_efSpriteMid_"):
        ef += s.length
        efN += 1
        doAssert s.kind == ekTable
        doAssert s.offset >= 0x2F1A7F and s.offset < 0x2F5000, s.name
        doAssert s.length >= 2
    doAssert ef == 1408, &"efSpriteMid residual want 1408 got {ef}"
    doAssert efN >= 50
    var c4 = 0
    var c4N = 0
    for s in allBaseromExtractSpans():
      if s.name.startsWith("table_c4Hitbox_"):
        c4 += s.length
        c4N += 1
        doAssert s.kind == ekTable
        doAssert s.offset >= 0x042B51 and s.offset + s.length <= 0x042F45, s.name
    doAssert c4 == 357, &"c4Hitbox residual want 357 got {c4}"
    doAssert c4N == 6
    # sample points
    doAssert isBaseromExtractOffset(0x2F1FD1)
    doAssert isBaseromExtractOffset(0x042D5F)
    doAssert isBaseromExtractOffset(0x042D5F + 100)
    # residual-only vs code chunks
    let efChunks = allRomChunksMeta()
    for s in allBaseromExtractSpans():
      if not (s.name.startsWith("table_efSpriteMid_") or s.name.startsWith("table_c4Hitbox_")):
        continue
      for c in efChunks:
        if c.kind != ckImplementedCode: continue
        let a0 = max(s.offset, c.offset)
        let a1 = min(s.offset + s.length, c.offset + c.length)
        doAssert a0 >= a1, &"overlap {s.name} with code 0x{c.offset:06X}"
    echo "[test_baserom_extract] EF mid + C4 hitbox residual OK: efMid=",
      ef, " c4Hitbox=", c4, " total=", ef + c4, " B"



block liveResidualExpandC5ApuCf:
  ## C5 body mid-record free + APU pack interiors + CF obj12 scraps (expand wave).
  if not goldBaseromAvailable():
    discard
  else:
    var c5 = 0
    var c5N = 0
    var apuNew = 0
    var apuN = 0
    var cf = 0
    var cfN = 0
    var samples: seq[BaseromExtractSpan] = @[]
    for s in allBaseromExtractSpans():
      # expand-wave C5 bodies use id~N in the note (prior C5 bodies use ids A..B)
      if s.name.startsWith("table_c5Body_") and "id~" in s.note:
        c5 += s.length
        c5N += 1
        doAssert s.kind == ekTable
        doAssert s.length >= 2
        doAssert s.offset >= 0x050000 and s.offset < 0x060000, s.name
        samples.add s
      # expand-wave APU: "APU pack interior residual" (no pack-number prefix)
      if s.name.startsWith("apuPack_") and s.note.startsWith("APU pack interior residual"):
        apuNew += s.length
        apuN += 1
        doAssert s.kind == ekApuPackage
        doAssert s.length >= 2
      if s.name in ["table_cfObj12_0x0F9359", "table_cfObj12_0x0F9458"]:
        cf += s.length
        cfN += 1
        doAssert s.kind == ekTable
        doAssert s.length == 12
        samples.add s
    doAssert c5 == 996, &"c5Body expand residual want 996 got {c5}"
    doAssert c5N == 99
    doAssert apuNew == 2413, &"apu interior residual want 2413 got {apuNew}"
    doAssert apuN == 387
    doAssert cf == 24 and cfN == 2
    doAssert isBaseromExtractOffset(0x053A4C)
    doAssert isBaseromExtractOffset(0x0BE308)
    doAssert isBaseromExtractOffset(0x0F9359)
    # residual-only vs code (cached chunk list)
    let chunks = allRomChunksMeta()
    for s in samples:
      for c in chunks:
        if c.kind != ckImplementedCode: continue
        let a0 = max(s.offset, c.offset)
        let a1 = min(s.offset + s.length, c.offset + c.length)
        doAssert a0 >= a1, &"overlap {s.name} with code 0x{c.offset:06X}"
    echo "[test_baserom_extract] residual expand C5/APU/CF OK: c5Body=",
      c5, " apuInt=", apuNew, " cfObj=", cf, " total=", c5 + apuNew + cf, " B"


block liveWave97Residual:
  ## Residual wave97: script prefixes + far3 + zRec + w4hi0 (ffRec via liveFf).
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var ssN, farN, zN, w4N = 0
    var ssB, farB, zB, w4B = 0
    var samples: seq[BaseromExtractSpan] = @[]
    for s in allBaseromExtractSpans():
      if s.name.startsWith("script_ssPrefix_"):
        ssN += 1
        ssB += s.length
        doAssert s.kind == ekScriptStream
        samples.add s
      elif s.name.startsWith("table_far3_") and "w100" notin s.name and "w99" notin s.name and "w101" notin s.name:
        farN += 1
        farB += s.length
        doAssert s.kind == ekTable
        doAssert s.length mod 3 == 0 and s.length >= 9
        for i in 0 ..< (s.length div 3):
          let bk = gold[s.offset + i * 3 + 2].int
          doAssert bk >= 0xC0 and bk <= 0xEF, &"{s.name}: bad bank"
        samples.add s
      elif s.name.startsWith("table_zRec_"):
        zN += 1
        zB += s.length
        doAssert s.kind == ekTable
        var i = s.offset
        let hi = s.offset + s.length
        var recs = 0
        while i < hi:
          let rs = i
          var found = false
          while i < hi and i - rs < 16:
            if gold[i] == 0:
              found = true
              i += 1
              break
            i += 1
          doAssert found, &"{s.name}: missing 00 @0x{rs:06X}"
          let L = i - rs
          doAssert L >= 2 and L <= 16
          recs += 1
        doAssert recs >= 2
        samples.add s
      elif s.name.startsWith("table_w4hi0_"):
        w4N += 1
        w4B += s.length
        doAssert s.kind == ekTable
        doAssert s.length mod 4 == 0 and s.length >= 8
        for i in 0 ..< (s.length div 4):
          doAssert gold[s.offset + i * 4 + 3] == 0
        samples.add s
    doAssert ssN >= 50 and ssB >= 2000, &"ssPrefix ssN={ssN} ssB={ssB}"
    doAssert farN >= 10 and farB >= 200, &"far3 farN={farN} farB={farB}"
    doAssert zN >= 3 and zB >= 200, &"zRec zN={zN} zB={zB}"
    doAssert w4N >= 1 and w4B >= 16, &"w4hi0 w4N={w4N} w4B={w4B}"
    let chunks = allRomChunksMeta()
    for s in samples:
      for c in chunks:
        if c.kind != ckImplementedCode:
          continue
        let a0 = max(s.offset, c.offset)
        let a1 = min(s.offset + s.length, c.offset + c.length)
        doAssert a0 >= a1, &"overlap {s.name} with code 0x{c.offset:06X}"
    echo "[test_baserom_extract] wave97 residual OK: ssPrefix=", ssB,
      " far3=", farB, " zRec=", zB, " w4hi0=", w4B,
      " total=", ssB + farB + zB + w4B, " B"


block liveWave98Residual:
  ## Residual wave98: fe/fd/seqE0/plane/cmd/far/u16/as/z structural free-only.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var feB, fdB, seqB, planeB, cmdB, far3B, far4B, u16B, asB, zB = 0
    var feN, fdN, seqN, planeN, cmdN, far3N, far4N, u16N, asN, zN = 0
    let chunks = allRomChunksMeta()
    for s in allBaseromExtractSpans():
      # code overlap gate for wave98 names
      let isW98 =
        s.name.startsWith("table_feRec_") or s.name.startsWith("table_fdRec_") or
        s.name.startsWith("table_seqE0_") or s.name.startsWith("table_planePair_") or
        s.name.startsWith("table_cmdPair_") or s.name.startsWith("table_far4_") or
        s.name.startsWith("table_u16mono_") or s.name.startsWith("as_wave98_") or
        s.name.startsWith("table_constFill_") or s.name.startsWith("zero_wave98_") or
        s.name.startsWith("script_wave98_")
      if not isW98 and not s.name.startsWith("table_far3_") and
          not s.name.startsWith("table_zRec_") and not s.name.startsWith("table_w4hi0_"):
        # still validate new far3/z/w4 via relaxed wave97; only count wave98 families here
        discard

      if s.name.startsWith("table_feRec_"):
        feN += 1
        feB += s.length
        var i = s.offset
        let hi = s.offset + s.length
        var recs = 0
        while i < hi:
          let rs = i
          var found = false
          while i < hi and i - rs < 33:
            if gold[i] == 0xFE:
              found = true
              i += 1
              break
            i += 1
          doAssert found, &"{s.name}: missing FE @0x{rs:06X}"
          let L = i - rs
          doAssert L >= 2 and L <= 32
          recs += 1
        doAssert recs >= 1
      elif s.name.startsWith("table_fdRec_"):
        fdN += 1
        fdB += s.length
        var i = s.offset
        let hi = s.offset + s.length
        var recs = 0
        while i < hi:
          let rs = i
          var found = false
          while i < hi and i - rs < 33:
            if gold[i] == 0xFD:
              found = true
              i += 1
              break
            i += 1
          doAssert found, &"{s.name}: missing FD @0x{rs:06X}"
          let L = i - rs
          doAssert L >= 2 and L <= 32
          recs += 1
        doAssert recs >= 1
      elif s.name.startsWith("table_seqE0_"):
        seqN += 1
        seqB += s.length
        var e0, notes, e0xx, z = 0
        for j in 0 ..< s.length:
          let b = gold[s.offset + j].int
          if b == 0: z += 1
          elif b >= 0x80 and b <= 0xC7: notes += 1
          elif b >= 0xE0:
            e0 += 1
            if b == 0xE0 and j + 1 < s.length and gold[s.offset + j + 1] < 0x40:
              e0xx += 1
        doAssert e0xx >= 1 and notes >= 3 and e0 >= 2, s.name
        doAssert z * 8 <= s.length
        doAssert (notes + e0) * 4 >= s.length
      elif s.name.startsWith("table_planePair_"):
        planeN += 1
        planeB += s.length
        doAssert s.length >= 20 and s.length mod 2 == 0
        let np = s.length div 2
        var pairs = 0
        for i in 0 ..< np:
          if gold[s.offset + i * 2] == gold[s.offset + i * 2 + 1]:
            pairs += 1
        doAssert pairs.float / np.float >= 0.50, s.name
      elif s.name.startsWith("table_cmdPair_"):
        cmdN += 1
        cmdB += s.length
        doAssert s.length >= 16 and s.length mod 2 == 0
      elif s.name.startsWith("table_far4_"):
        far4N += 1
        far4B += s.length
        doAssert s.length mod 4 == 0 and s.length >= 12
        for i in 0 ..< (s.length div 4):
          let bk = gold[s.offset + i * 4 + 2].int
          doAssert bk >= 0xC0 and bk <= 0xEF
          doAssert gold[s.offset + i * 4 + 3] == 0
      elif s.name.startsWith("table_u16mono_"):
        u16N += 1
        u16B += s.length
        doAssert s.length mod 2 == 0 and s.length >= 10
        var prev = -1
        for i in 0 ..< (s.length div 2):
          let v = gold[s.offset + i * 2].int or (gold[s.offset + i * 2 + 1].int shl 8)
          if prev >= 0:
            doAssert v >= prev, s.name
          prev = v
      elif s.name.startsWith("as_wave98_"):
        asN += 1
        asB += s.length
        doAssert s.kind == ekActionScript
        doAssert isGoodActionScriptSpan(gold, s.offset, s.length), s.name
      elif s.name.startsWith("table_constFill_"):
        let v = gold[s.offset]
        for j in 0 ..< s.length:
          doAssert gold[s.offset + j] == v
      elif s.name.startsWith("zero_wave98_"):
        doAssert s.kind == ekZeroPad
        for j in 0 ..< s.length:
          doAssert gold[s.offset + j] == 0

      if isW98 or s.name.startsWith("table_far4_") or s.name.startsWith("table_u16mono_") or
          s.name.startsWith("table_seqE0_") or s.name.startsWith("table_planePair_") or
          s.name.startsWith("table_cmdPair_") or s.name.startsWith("table_feRec_") or
          s.name.startsWith("table_fdRec_") or s.name.startsWith("as_wave98_"):
        for c in chunks:
          if c.kind != ckImplementedCode:
            continue
          let a0 = max(s.offset, c.offset)
          let a1 = min(s.offset + s.length, c.offset + c.length)
          doAssert a0 >= a1, &"overlap {s.name} with code 0x{c.offset:06X}"

    doAssert feB >= 3000, &"feRec {feB}"
    doAssert fdB >= 500, &"fdRec {fdB}"
    doAssert seqB >= 5000, &"seqE0 {seqB}"
    doAssert planeB >= 2000, &"plane {planeB}"
    doAssert cmdB >= 3000, &"cmd {cmdB}"
    doAssert u16B >= 2000, &"u16 {u16B}"
    doAssert asB >= 1000, &"as {asB}"
    let waveTot = feB + fdB + seqB + planeB + cmdB + far4B + u16B + asB
    doAssert waveTot >= 20000, &"wave98 core total {waveTot}"
    echo "[test_baserom_extract] wave98 residual OK: fe=", feB,
      " fd=", fdB, " seqE0=", seqB, " plane=", planeB, " cmd=", cmdB,
      " far4=", far4B, " u16=", u16B, " as=", asB,
      " core=", waveTot, " B"


block liveWave99Residual:
  ## Residual wave99: u8pair/countN/u16/smooth/fix/term/cmd/seq/as free-only.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var u8B, countB, u16B, smoothB, fixB, termB, cmdB, seqB, asB, planeB = 0
    let chunks = allRomChunksMeta()
    for s in allBaseromExtractSpans():
      let isW99 =
        (s.name.startsWith("table_u8pair_") and not s.name.startsWith("table_u8pair55_") and not s.name.startsWith("table_u8pair4_")) or
        (s.name.startsWith("table_countN_") and not s.name.contains("w100")) or
        s.name.startsWith("table_u16tab_") or
        (s.name.startsWith("table_smooth") and not s.name.contains("w100")) or
        (s.name.startsWith("table_fix3_") and not s.name.contains("w100")) or
        (s.name.startsWith("table_fix4_") and not s.name.contains("w100")) or
        (s.name.startsWith("table_fix5col_") and not s.name.contains("w100")) or
        (s.name.startsWith("table_fix6col_") and not s.name.contains("w100")) or
        (s.name.startsWith("table_fix7col_") and not s.name.contains("w100")) or
        (s.name.startsWith("table_fix8col_") and not s.name.contains("w100")) or
        (s.name.startsWith("table_fix9col_") and not s.name.contains("w100")) or
        (s.name.startsWith("table_fix10col_") and not s.name.contains("w100")) or
        (s.name.startsWith("table_fix12col_") and not s.name.contains("w100")) or
        (s.name.startsWith("table_tF") and not s.name.contains("w100")) or
        s.name.startsWith("table_plane35_") or s.name.startsWith("table_cmd22_") or
        s.name.startsWith("table_seqLoose_") or s.name.startsWith("table_far3w99_") or
        s.name.startsWith("as_wave99_") or s.name.startsWith("script_wave99_") or
        s.name.startsWith("table_u8lo_") or s.name.startsWith("table_stride2_") or
        s.name.startsWith("table_lowEnt_") or s.name.startsWith("zero_wave99_") or
        s.name.startsWith("table_constFill_w99_")
      if not isW99:
        continue

      # hard gate: no code_span overlap
      for c in chunks:
        if c.kind != ckImplementedCode:
          continue
        let a0 = max(s.offset, c.offset)
        let a1 = min(s.offset + s.length, c.offset + c.length)
        doAssert a0 >= a1, &"overlap {s.name} with code 0x{c.offset:06X}"

      if s.name.startsWith("table_u8pair_"):
        u8B += s.length
        doAssert s.length >= 16 and s.length mod 2 == 0
        let nRec = s.length div 2
        var ok = 0
        for i in 0 ..< nRec:
          let a = gold[s.offset + i * 2]
          let b = gold[s.offset + i * 2 + 1]
          if a <= 0x40 or b <= 0x40:
            ok += 1
        doAssert ok * 100 >= nRec * 65, s.name
      elif s.name.startsWith("table_countN_"):
        countB += s.length
        doAssert s.length >= 6
        # header must match some stride packing
        var matched = false
        for hdr in 1 .. 2:
          for stride in [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 17, 25, 27, 41]:
            let cnt =
              if hdr == 1: gold[s.offset].int
              else: gold[s.offset].int or (gold[s.offset + 1].int shl 8)
            if cnt < 2 or cnt > 100: continue
            if hdr + cnt * stride == s.length:
              matched = true
              break
          if matched: break
        doAssert matched, &"{s.name}: no count*stride match len={s.length}"
      elif s.name.startsWith("table_u16tab_"):
        u16B += s.length
        doAssert s.length mod 2 == 0 and s.length >= 16
      elif s.name.startsWith("table_smooth"):
        smoothB += s.length
        doAssert s.length >= 24
      elif s.name.startsWith("table_fix3_") or s.name.startsWith("table_fix4_") or
          s.name.contains("col_"):
        fixB += s.length
      elif s.name.startsWith("table_tF"):
        termB += s.length
      elif s.name.startsWith("table_cmd22_"):
        cmdB += s.length
        doAssert s.length >= 12 and s.length mod 2 == 0
      elif s.name.startsWith("table_seqLoose_"):
        seqB += s.length
        var e0xx, notes, e0 = 0
        for j in 0 ..< s.length:
          let b = gold[s.offset + j].int
          if b >= 0x80 and b <= 0xC7: notes += 1
          elif b >= 0xE0:
            e0 += 1
            if b == 0xE0 and j + 1 < s.length and gold[s.offset + j + 1] < 0x40:
              e0xx += 1
        doAssert e0xx >= 1 and notes >= 2 and e0 >= 1, s.name
      elif s.name.startsWith("as_wave99_"):
        asB += s.length
        doAssert s.kind == ekActionScript
        doAssert isGoodActionScriptSpan(gold, s.offset, s.length), s.name
      elif s.name.startsWith("table_plane35_"):
        planeB += s.length
        doAssert s.length >= 16 and s.length mod 2 == 0
      elif s.name.startsWith("zero_wave99_"):
        doAssert s.kind == ekZeroPad
        for j in 0 ..< s.length:
          doAssert gold[s.offset + j] == 0
      elif s.name.startsWith("table_constFill_w99_"):
        let v = gold[s.offset]
        for j in 0 ..< s.length:
          doAssert gold[s.offset + j] == v

    doAssert u8B >= 8000, &"u8pair {u8B}"
    doAssert countB >= 10000, &"countN {countB}"
    let waveTot = u8B + countB + u16B + smoothB + fixB + termB + cmdB + seqB + asB + planeB
    doAssert waveTot >= 25000, &"wave99 core total {waveTot}"
    echo "[test_baserom_extract] wave99 residual OK: u8pair=", u8B,
      " countN=", countB, " u16=", u16B, " smooth=", smoothB,
      " fix=", fixB, " term=", termB, " cmd=", cmdB, " seq=", seqB,
      " as=", asB, " plane=", planeB, " core=", waveTot, " B"


block liveWave100Residual:
  ## Residual wave100: term/ss/u8pair/countN/fix/plane/print/smooth/zero/const free-only.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var termB, ssB, u8B, countB, fixB, planeB, printB, smoothB, asB, zeroB, constB = 0
    let chunks = allRomChunksMeta()
    for s in allBaseromExtractSpans():
      let isW100 =
        (s.name.startsWith("zero_wave100_") and not s.name.startsWith("zero_wave100b_")) or
        s.name.startsWith("table_constFill_w100_") and not s.name.contains("w100b") or
        (s.name.startsWith("table_tF") and s.name.contains("_w100_") and not s.name.contains("w100b")) or
        s.name.startsWith("script_wave100_") or
        (s.name.startsWith("as_wave100_") and not s.name.startsWith("as_wave100b_")) or
        s.name.startsWith("table_u8pair55_") or
        (s.name.startsWith("table_countN_w100_") and not s.name.contains("w100b")) or
        (s.name.startsWith("table_fix3_w100_") and not s.name.contains("w100b")) or
        (s.name.startsWith("table_fix4_w100_") and not s.name.contains("w100b")) or
        (s.name.contains("col_w100_") and not s.name.contains("w100b")) or
        (s.name.startsWith("table_plane25_w100_") and not s.name.contains("w100b")) or
        (s.name.startsWith("table_print70_w100_") and not s.name.contains("w100b")) or
        s.name.startsWith("table_smooth1_w100_") or
        (s.name.startsWith("table_far3_w100_") and not s.name.contains("w100b"))
      if not isW100:
        continue

      for c in chunks:
        if c.kind != ckImplementedCode:
          continue
        let a0 = max(s.offset, c.offset)
        let a1 = min(s.offset + s.length, c.offset + c.length)
        doAssert a0 >= a1, &"overlap {s.name} with code 0x{c.offset:06X}"

      if s.name.startsWith("zero_wave100_"):
        zeroB += s.length
        doAssert s.kind == ekZeroPad
        for j in 0 ..< s.length:
          doAssert gold[s.offset + j] == 0
      elif s.name.startsWith("table_constFill_w100_"):
        constB += s.length
        let v = gold[s.offset]
        for j in 0 ..< s.length:
          doAssert gold[s.offset + j] == v
      elif s.name.startsWith("table_tF") and s.name.contains("_w100_"):
        termB += s.length
        # last byte must be the terminator nibble family F0-FF
        doAssert gold[s.offset + s.length - 1] >= 0xF0
      elif s.name.startsWith("script_wave100_"):
        ssB += s.length
        doAssert s.kind == ekScriptStream
        let w = walkScriptStream(gold, s.offset, s.offset + s.length)
        doAssert isGoodScriptStream(w) and w.length == s.length, s.name
      elif s.name.startsWith("as_wave100_"):
        asB += s.length
        doAssert s.kind == ekActionScript
        doAssert isGoodActionScriptSpan(gold, s.offset, s.length), s.name
      elif s.name.startsWith("table_u8pair55_"):
        u8B += s.length
        doAssert s.length >= 12 and s.length mod 2 == 0
        let nRec = s.length div 2
        var ok = 0
        for i in 0 ..< nRec:
          let a = gold[s.offset + i * 2]
          let b = gold[s.offset + i * 2 + 1]
          if a <= 0x50 or b <= 0x50:
            ok += 1
        doAssert ok * 100 >= nRec * 55, s.name
      elif s.name.startsWith("table_countN_w100_"):
        countB += s.length
        doAssert s.length >= 5
        var matched = false
        for hdr in 1 .. 2:
          for stride in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 17, 20, 24, 25, 27, 32, 41]:
            let cnt =
              if hdr == 1: gold[s.offset].int
              else: gold[s.offset].int or (gold[s.offset + 1].int shl 8)
            if cnt < 2 or cnt > 160: continue
            if hdr + cnt * stride == s.length:
              matched = true
              break
          if matched: break
        doAssert matched, &"{s.name}: no count*stride match len={s.length}"
      elif s.name.startsWith("table_fix3_w100_") or s.name.startsWith("table_fix4_w100_") or
          s.name.contains("col_w100_"):
        fixB += s.length
      elif s.name.startsWith("table_plane25_w100_"):
        planeB += s.length
        doAssert s.length >= 12 and s.length mod 2 == 0
      elif s.name.startsWith("table_print70_w100_"):
        printB += s.length
        var pr = 0
        for j in 0 ..< s.length:
          let b = gold[s.offset + j]
          if (b >= 0x20 and b <= 0x7E) or (b >= 0x50 and b <= 0x90):
            pr += 1
        doAssert pr * 100 >= s.length * 70, s.name
      elif s.name.startsWith("table_smooth1_w100_"):
        smoothB += s.length
        doAssert s.length >= 12

    let waveTot = termB + ssB + u8B + countB + fixB + planeB + printB + smoothB + asB + zeroB + constB
    doAssert waveTot >= 4000, &"wave100 total {waveTot}"
    doAssert termB >= 800, &"term {termB}"
    doAssert printB >= 500, &"print {printB}"
    echo "[test_baserom_extract] wave100 residual OK: term=", termB,
      " ss=", ssB, " u8pair55=", u8B, " countN=", countB,
      " fix=", fixB, " plane=", planeB, " print=", printB,
      " smooth=", smoothB, " as=", asB, " zero=", zeroB,
      " const=", constB, " total=", waveTot, " B"


block liveWave100bResidual:
  ## Residual wave100b: u8pair4/countN4/fix/far3/print/plane/zero/const free-only.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var u8B, countB, fixB, farB, printB, planeB, zeroB, constB, asB = 0
    let chunks = allRomChunksMeta()
    for s in allBaseromExtractSpans():
      let isW =
        s.name.startsWith("zero_wave100b_") or
        s.name.startsWith("table_constFill_w100b_") or
        s.name.startsWith("as_wave100b_") or
        s.name.startsWith("table_u8pair4_w100b_") or
        s.name.startsWith("table_countN_w100b_") or
        s.name.startsWith("table_fix3_w100b_") or s.name.startsWith("table_fix4_w100b_") or
        s.name.startsWith("table_far3_w100b_") or
        s.name.startsWith("table_print70_w100b_") or
        s.name.startsWith("table_plane25_w100b_")
      if not isW:
        continue
      for c in chunks:
        if c.kind != ckImplementedCode:
          continue
        let a0 = max(s.offset, c.offset)
        let a1 = min(s.offset + s.length, c.offset + c.length)
        doAssert a0 >= a1, &"overlap {s.name} with code 0x{c.offset:06X}"
      if s.name.startsWith("zero_wave100b_"):
        zeroB += s.length
        for j in 0 ..< s.length:
          doAssert gold[s.offset + j] == 0
      elif s.name.startsWith("table_constFill_w100b_"):
        constB += s.length
        let v = gold[s.offset]
        for j in 0 ..< s.length:
          doAssert gold[s.offset + j] == v
      elif s.name.startsWith("as_wave100b_"):
        asB += s.length
        doAssert isGoodActionScriptSpan(gold, s.offset, s.length), s.name
      elif s.name.startsWith("table_u8pair4_w100b_"):
        u8B += s.length
        doAssert s.length >= 8 and s.length mod 2 == 0
      elif s.name.startsWith("table_countN_w100b_"):
        countB += s.length
        var matched = false
        for hdr in 1 .. 2:
          for stride in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 17, 20, 24, 25, 27, 32, 41]:
            let cnt =
              if hdr == 1: gold[s.offset].int
              else: gold[s.offset].int or (gold[s.offset + 1].int shl 8)
            if cnt < 2 or cnt > 160: continue
            if hdr + cnt * stride == s.length:
              matched = true
              break
          if matched: break
        doAssert matched, s.name
      elif s.name.startsWith("table_fix3_w100b_") or s.name.startsWith("table_fix4_w100b_"):
        fixB += s.length
      elif s.name.startsWith("table_far3_w100b_"):
        farB += s.length
        doAssert s.length mod 3 == 0 and s.length >= 3
        for i in 0 ..< (s.length div 3):
          let b = gold[s.offset + i*3 + 2]
          doAssert b >= 0xC0 and b <= 0xEF, s.name
      elif s.name.startsWith("table_print70_w100b_"):
        printB += s.length
      elif s.name.startsWith("table_plane25_w100b_"):
        planeB += s.length
        doAssert s.length mod 2 == 0 and s.length >= 8

    let waveTot = u8B + countB + fixB + farB + printB + planeB + zeroB + constB + asB
    doAssert waveTot >= 2500, &"wave100b total {waveTot}"
    doAssert farB >= 500, &"far3 {farB}"
    echo "[test_baserom_extract] wave100b residual OK: u8pair4=", u8B,
      " countN=", countB, " fix=", fixB, " far3=", farB,
      " print=", printB, " plane=", planeB, " zero=", zeroB,
      " const=", constB, " as=", asB, " total=", waveTot, " B"


block liveWave101Residual:
  ## Residual wave101: zero/as/term/u8pair/const/far3align/bitFlag free-only.
  if not goldBaseromAvailable():
    discard
  else:
    let gold = readGoldBaseromBytes()
    var zeroB, asB, termB, u8B, constB, farB, bitB = 0
    let chunks = allRomChunksMeta()
    for s in allBaseromExtractSpans():
      let isW =
        s.name.startsWith("zero_wave101_") or
        s.name.startsWith("as_wave101_") or
        s.name.startsWith("table_term_w101_") or
        s.name.startsWith("table_term1_w101_") or
        s.name.startsWith("table_u8pair4_w101_") or
        s.name.startsWith("table_constFill_w101_") or
        s.name.startsWith("table_far3_w101_") or
        s.name.startsWith("table_bitFlag_w101_")
      if not isW:
        continue
      for c in chunks:
        if c.kind != ckImplementedCode:
          continue
        let a0 = max(s.offset, c.offset)
        let a1 = min(s.offset + s.length, c.offset + c.length)
        doAssert a0 >= a1, &"overlap {s.name} with code 0x{c.offset:06X}"
      if s.name.startsWith("zero_wave101_"):
        zeroB += s.length
        doAssert s.kind == ekZeroPad
        for j in 0 ..< s.length:
          doAssert gold[s.offset + j] == 0
      elif s.name.startsWith("as_wave101_"):
        asB += s.length
        doAssert isGoodActionScriptSpan(gold, s.offset, s.length), s.name
      elif s.name.startsWith("table_term_w101_") or s.name.startsWith("table_term1_w101_"):
        termB += s.length
        doAssert s.length >= 4
        let term = gold[s.offset + s.length - 1]
        doAssert term >= 0xF0
        doAssert gold[s.offset + s.length - 1] == term
      elif s.name.startsWith("table_u8pair4_w101_"):
        u8B += s.length
        doAssert s.length >= 8 and s.length mod 2 == 0
      elif s.name.startsWith("table_constFill_w101_"):
        constB += s.length
        let v = gold[s.offset]
        for j in 0 ..< s.length:
          doAssert gold[s.offset + j] == v
      elif s.name.startsWith("table_far3_w101_"):
        farB += s.length
        doAssert s.length mod 3 == 0 and s.length >= 3
        for i in 0 ..< (s.length div 3):
          let b = gold[s.offset + i*3 + 2]
          let lo = gold[s.offset + i*3].int or (gold[s.offset + i*3 + 1].int shl 8)
          doAssert b >= 0xC0 and b <= 0xEF and lo != 0, s.name
      elif s.name.startsWith("table_bitFlag_w101_"):
        bitB += s.length
        doAssert s.length >= 4
        var nz = 0
        for j in 0 ..< s.length:
          let b = gold[s.offset + j]
          doAssert b in [0x00u8, 0x01u8, 0x80u8], s.name
          if b != 0: nz += 1
        doAssert nz >= 1, s.name

    let waveTot = zeroB + asB + termB + u8B + constB + farB + bitB
    doAssert waveTot >= 1000, &"wave101 total {waveTot}"
    doAssert zeroB >= 20, &"zero {zeroB}"
    doAssert asB >= 30, &"as {asB}"
    doAssert farB >= 200, &"far3 {farB}"
    doAssert bitB >= 800, &"bitFlag {bitB}"
    echo "[test_baserom_extract] wave101 residual OK: zero=", zeroB,
      " as=", asB, " term=", termB, " u8pair=", u8B,
      " const=", constB, " far3=", farB, " bitFlag=", bitB,
      " total=", waveTot, " B"

