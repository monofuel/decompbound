## Tests for baserom extract metadata + gold slice equality.
## Structural checks always run. Live gold checks run when baserom is present.

import
  std/[algorithm, strformat],
  decompbound/[baserom_extract, common, gfx_lz, rom_chunks]

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
