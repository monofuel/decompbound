## Verify baserom extracts do not overlap *live* code inventory.
##
## Inventory/build carve extract ranges out of GeneratedCodeSpans via
## carveSpanAroundHoles (see collectImplementedSpanMeta / convert_all). Raw
## code_spans ∩ extract may be non-zero for intentional free+false-code carve
## claims (wave106b); those are honest once inventory carves. This tool gates
## the carved view: extract must not collide with remaining code pieces, and
## extracts must not self-overlap.
import
  std/[strformat, algorithm, strutils],
  ../decompbound/[baserom_extract, common, generated/code_spans, rom_chunks]

proc main() =
  ## Report raw vs carved code∩extract; fail only on carved conflicts / self-overlap.
  var rawMask = newSeq[uint8](EarthboundRomSize) # 0 free, 1 raw code
  var codeBytes = 0
  for s in GeneratedCodeSpans:
    for j in 0..<s.length:
      if s.offset + j < rawMask.len:
        rawMask[s.offset + j] = 1
        codeBytes += 1

  # Carved code = GeneratedCodeSpans with extract+adopted holes removed
  # (same path as collectImplementedSpanMeta).
  var carvedMask = newSeq[uint8](EarthboundRomSize)
  var carvedCodeBytes = 0
  for c in allRomChunksMeta():
    if c.kind == ckImplementedCode:
      for j in 0..<c.length:
        let o = c.offset + j
        if o < carvedMask.len:
          carvedMask[o] = 1
          carvedCodeBytes += 1

  var extractBytes = 0
  var rawOverlap = 0
  var carvedOverlap = 0
  var selfOverlap = 0
  var extractMask = newSeq[uint8](EarthboundRomSize)
  for s in allBaseromExtractSpans():
    for j in 0..<s.length:
      let o = s.offset + j
      if o >= extractMask.len: continue
      if extractMask[o] == 1:
        selfOverlap += 1
        if selfOverlap <= 5:
          echo &"SELF-OVERLAP extract @0x{o:06X} in {s.name}"
      else:
        extractMask[o] = 1
        extractBytes += 1
      if rawMask[o] == 1:
        rawOverlap += 1
        if rawOverlap <= 8:
          echo &"RAW code∩extract @0x{o:06X} in {s.name} (expected for carve claims)"
      if carvedMask[o] == 1:
        carvedOverlap += 1
        if carvedOverlap <= 8:
          echo &"CARVED code∩extract @0x{o:06X} in {s.name}"

  echo &"code_spans raw bytes: {codeBytes}"
  echo &"code inventory carved bytes: {carvedCodeBytes}"
  echo &"extract unique bytes: {extractBytes}"
  echo &"raw code∩extract overlap: {rawOverlap}"
  echo &"carved code∩extract overlap: {carvedOverlap}"
  echo &"extract self-overlap: {selfOverlap}"

  var carveWave = 0
  for s in allBaseromExtractSpans():
    if "carve_w106b" in s.name:
      carveWave += s.length
  echo &"wave106b carve extract bytes: {carveWave}"

  if carvedOverlap > 0 or selfOverlap > 0:
    quit(1)
  echo "OK: zero carved overlap (raw may be non-zero for intentional carves)"

main()
