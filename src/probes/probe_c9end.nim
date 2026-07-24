## Check SS terminators past residual gaps.
import
  std/[strformat, os],
  ../decompbound/[baserom_extract, text_decode, rom_chunks]

proc main() =
  ## Probe stream ends for C9EE90 / C5 bodies.
  let g = readGoldBaseromBytes()
  let off = 0x09EE90
  let gapLen = 379
  let w = walkScriptStream(g, off, off + 2000)
  echo &"walk from C9EE90: len={w.length} ended={w.ended} glyphs={w.glyphs} bad={w.badGlyphs} good={isGoodScriptStream(w)}"
  echo &"ends at 0x{off+w.length:06X}"

  let chunks = allRomChunksMeta()
  for c in chunks:
    if c.offset <= off+gapLen and c.offset+c.length > off+gapLen:
      echo &"chunk covering end of gap: {c.id} 0x{c.offset:06X}+{c.length}"
    if c.offset >= off+gapLen and c.offset < off+gapLen+80:
      echo &"next chunk: {c.id} 0x{c.offset:06X}+{c.length}"

  echo "after gap:"
  for i in 0..<48:
    stdout.write &"{g[off+gapLen+i]:02X} "
  echo ""

  echo "\nC5 body streams:"
  for (id, f, ln) in [(30, 0x053AF6, 16), (80, 0x054065, 16), (244, 0x0565BC, 24)]:
    let w2 = walkScriptStream(g, f, f+200)
    echo &"  id={id} @0x{f:06X}: walk={w2.length} ended={w2.ended} glyphs={w2.glyphs} bad={w2.badGlyphs} good={isGoodScriptStream(w2)}"
    var hx = ""
    for i in 0..<ln: hx.add &"{g[f+i]:02X} "
    echo &"    bytes: {hx}"

  echo "\nbytes before 0x05980E:"
  for i in 0..<24:
    stdout.write &"{g[0x05980E-16+i]:02X} "
  echo ""

  # Try C9EE90 as run of streams if internal 00s exist
  var zeros = 0
  for i in 0..<gapLen:
    if g[off+i] == 0: zeros += 1
  echo &"\nC9EE90 zero count in gap: {zeros}"

main()
