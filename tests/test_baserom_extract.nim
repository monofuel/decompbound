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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    discard readGoldBaseromBytes()
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
    for s in allBaseromExtractSpans():
      if not (s.name.startsWith("table_d7MapAttr_") or s.name.startsWith("table_ca17_") or
          s.name == "table_cePtr_0x0EDD15"):
        continue
      for c in allRomChunksMeta():
        if c.kind != ckImplementedCode: continue
        let a0 = max(s.offset, c.offset)
        let a1 = min(s.offset + s.length, c.offset + c.length)
        doAssert a0 >= a1, &"overlap {s.name} with code chunk 0x{c.offset:06X}"
    echo "[test_baserom_extract] dense-bank loader residual OK: d7MapAttr=",
      d7, " ca17=", ca, " cePtr=", ce, " B"

