## Inspect spans around C9EE90 for extract carve safety.
import
  std/[strformat, algorithm],
  ../decompbound/[baserom_extract, text_decode, rom_chunks, generated/code_spans]

proc main() =
  ## List code spans and chunks near C9EE90.
  let g = readGoldBaseromBytes()
  echo "GeneratedCodeSpans near 0x09EE00..0x09F100:"
  for s in GeneratedCodeSpans:
    if s.offset + s.length > 0x09EE00 and s.offset < 0x09F100:
      echo &"  code 0x{s.offset:06X}+{s.length} end=0x{s.offset+s.length:06X}"

  echo "\nExtracts near:"
  for s in allBaseromExtractSpans():
    if s.offset + s.length > 0x09EE00 and s.offset < 0x09F100:
      echo &"  extract {s.name} 0x{s.offset:06X}+{s.length}"

  # Full good stream
  let w = walkScriptStream(g, 0x09EE90, 0x09F100)
  echo &"\nstream: 0x09EE90+{w.length} good={isGoodScriptStream(w)} end=0x{0x09EE90+w.length:06X}"

  # What's at stream end?
  let endOff = 0x09EE90 + w.length
  echo &"bytes at end-4..end+16:"
  for i in endOff-4 .. endOff+16:
    stdout.write &"{g[i]:02X} "
  echo ""

  # Check prologue at endOff
  echo &"after stream: {g[endOff]:02X} {g[endOff+1]:02X} {g[endOff+2]:02X} {g[endOff+3]:02X}"
  # REP #$30/31 common
  if g[endOff] == 0xC2:
    echo "  looks like REP"
  if g[endOff] == 0x08 or g[endOff] == 0x0B:
    echo "  PHP/PHD?"

  # Find more false-positive: unclaimed SS that become good when extending into code
  echo "\n===== false-positive code tails (SS extends into code) ====="
  let chunks = allRomChunksMeta()
  var found = 0
  var totalGain = 0
  for c in chunks:
    if c.kind != ckUnclaimed or c.length < 20: continue
    let w0 = walkScriptStream(g, c.offset, c.offset + c.length)
    if isGoodScriptStream(w0): continue  # already complete in gap
    # extend
    let w1 = walkScriptStream(g, c.offset, min(c.offset + c.length + 256, g.len))
    if isGoodScriptStream(w1) and w1.length > c.length:
      # stream spans into claimed
      let over = w1.length - c.length
      found += 1
      totalGain += w1.length  # full stream claimable if we carve
      if found <= 25:
        echo &"  unclaimed 0x{c.offset:06X}+{c.length} extends to +{w1.length} (overhang {over}) glyphs={w1.glyphs}"
  echo &"total such gaps: {found} full-stream bytes if carved: {totalGain}"

main()
