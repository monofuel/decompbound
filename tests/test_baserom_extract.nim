## Tests for baserom extract metadata + gold slice equality.
## Structural checks always run. Live gold checks run when baserom is present.

import
  std/[algorithm, strformat],
  decompbound/[baserom_extract, common, gfx_lz, rom_chunks, text_decode]

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
