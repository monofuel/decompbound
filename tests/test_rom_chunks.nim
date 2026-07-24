## Full-ROM chunk inventory: structural coverage + per-chunk gold checks.
## Structural blocks need no ROM. Gold blocks skip when baserom is absent.

import
  std/[os, strutils],
  decompbound/[common, rom_chunks, regions]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"

block purePartitionToy:
  ## partitionFromSpans covers [0, romSize) with no overlap and fills gaps.
  let spans = @[
    (name: "a", offset: 10, length: 5, kind: ckImplementedCode, built: @[1'u8, 2, 3, 4, 5]),
    (name: "b", offset: 20, length: 3, kind: ckImplementedMeta, built: @[9'u8, 8, 7]),
  ]
  let chunks = partitionFromSpans(spans, romSize = 30)
  doAssert inventoryCoversRom(chunks, 30)
  doAssert chunks.len == 5  # gap0-10, a, gap15-20, b, gap23-30
  doAssert chunks[0].kind == ckUnclaimed and chunks[0].offset == 0 and chunks[0].length == 10
  doAssert chunks[1].id == "a" and chunks[1].length == 5
  doAssert chunks[2].kind == ckUnclaimed and chunks[2].offset == 15
  doAssert chunks[3].id == "b"
  doAssert chunks[4].kind == ckUnclaimed and chunks[4].offset == 23 and chunks[4].length == 7
  let totals = totalBytesByKind(chunks)
  doAssert totals[ckImplementedCode] == 5
  doAssert totals[ckImplementedMeta] == 3
  doAssert totals[ckUnclaimed] == 22

block pureCheckMatchAndMismatch:
  ## checkChunkAgainstGold compares built vs gold without claiming unclaimed.
  var gold = newString(EarthboundRomSize)
  for i in 0..<EarthboundRomSize:
    gold[i] = '\0'
  gold[10] = char(0xAA)
  gold[11] = char(0xBB)
  let good = RomChunk(
    id: "toy",
    kind: ckImplementedCode,
    offset: 10,
    length: 2,
    doneCriteria: DoneImplementedCode,
    built: @[0xAA'u8, 0xBB])
  let rOk = checkChunkAgainstGold(good, gold)
  doAssert rOk.status == ccsMatch, rOk.message
  let bad = RomChunk(
    id: "toy_bad",
    kind: ckImplementedCode,
    offset: 10,
    length: 2,
    doneCriteria: DoneImplementedCode,
    built: @[0xAA'u8, 0x00])
  let rBad = checkChunkAgainstGold(bad, gold)
  doAssert rBad.status == ccsMismatch, rBad.message
  doAssert rBad.mismatchOffset == 11
  doAssert "toy_bad" in rBad.message
  let gap = RomChunk(
    id: "gap",
    kind: ckUnclaimed,
    offset: 100,
    length: 50,
    doneCriteria: DoneUnclaimed,
    built: @[])
  let rGap = checkChunkAgainstGold(gap, gold)
  doAssert rGap.status == ccsUnclaimed
  doAssert "not decompiled" in rGap.message

block liveInventoryStructural:
  ## Real registry partition covers the full ROM, no overlaps, unique ids.
  let chunks = allRomChunks()
  doAssert inventoryCoversRom(chunks), "inventory must cover full ROM"
  doAssert chunks.len > 200
  var ids: seq[string]
  var endPos = 0
  for c in chunks:
    doAssert c.length > 0, c.id
    doAssert c.offset == endPos, c.id & " gap/overlap at " & $c.offset
    doAssert c.id.len > 0
    doAssert c.id notin ids, "duplicate id " & c.id
    ids.add c.id
    doAssert c.doneCriteria.len > 0
    if c.kind in {ckImplementedCode, ckImplementedMeta}:
      doAssert c.built.len == c.length, c.id
    else:
      doAssert c.built.len == 0, c.id & " unclaimed must not carry built bytes"
    endPos = c.offset + c.length
  doAssert endPos == EarthboundRomSize
  let totals = totalBytesByKind(chunks)
  doAssert totals[ckImplementedCode] + totals[ckImplementedMeta] +
           totals[ckUnclaimed] == EarthboundRomSize
  # Implemented byte count matches sum of allRegions lengths.
  var regBytes = 0
  for r in allRegions():
    regBytes += r.data.len
  doAssert totals[ckImplementedCode] + totals[ckImplementedMeta] == regBytes,
    "implemented chunk bytes must equal region registry"

block liveGoldImplementedChunks:
  ## Every implemented chunk matches local gold when present.
  if not fileExists(GoldMasterRom):
    echo "[test_rom_chunks] skip live gold (no baserom)"
  else:
    let gold = readFile(GoldMasterRom)
    doAssert gold.len == EarthboundRomSize
    var matched = 0
    for c in allRomChunks():
      if c.kind == ckUnclaimed:
        let r = checkChunkAgainstGold(c, gold)
        doAssert r.status == ccsUnclaimed, r.message
        continue
      let r = checkChunkAgainstGold(c, gold)
      doAssert r.status == ccsMatch, r.message
      inc matched
    doAssert matched > 200
    echo "[test_rom_chunks] live gold: ", matched, " implemented chunks matched"

block findChunkHelpers:
  let chunks = allRomChunks()
  let header = findChunk(chunks, "header")
  doAssert header.kind == ckImplementedMeta
  doAssert header.offset == HiRomHeaderOffset
  let at0 = findChunkAt(chunks, 0)
  doAssert at0.offset == 0
