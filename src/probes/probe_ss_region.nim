## Walk consecutive script streams through false-positive code spans.
import
  std/[strformat, algorithm],
  ../decompbound/[baserom_extract, text_decode, rom_chunks, generated/code_spans]

proc main() =
  ## Map script coverage through C9EE90 region and global carve candidates.
  let g = readGoldBaseromBytes()

  echo "===== consecutive SS from 0x09EE7D ====="
  var pos = 0x09EE7D
  var total = 0
  while pos < 0x09F200:
    let w = walkScriptStream(g, pos, 0x09F200)
    if not isGoodScriptStream(w):
      echo &"  stop @0x{pos:06X} walk={w.length} ended={w.ended} glyphs={w.glyphs} bad={w.badGlyphs}"
      # try skip 1
      break
    echo &"  SS 0x{pos:06X}+{w.length} glyphs={w.glyphs}"
    total += w.length
    pos += w.length
  echo &"  total good run {total} ends 0x{pos:06X}"

  # Global: for each code span, check if it's fully covered by good SS walks from nearby unclaimed
  echo "\n===== code spans fully consumable as SS ====="
  let chunks = allRomChunksMeta()
  # build claimed for unclaimed starts
  var codeSpans: seq[(int,int)] = @[]
  for s in GeneratedCodeSpans:
    codeSpans.add (s.offset, s.length)

  var carveBytes = 0
  var carveN = 0
  var candidates: seq[(int,int,int)] = @[] # start, len, streamTotal
  for c in chunks:
    if c.kind != ckUnclaimed or c.length < 8: continue
    # try consume from unclaimed start through following code
    var pos = c.offset
    var consumed = 0
    var streams = 0
    let hardLim = min(c.offset + c.length + 512, g.len)
    while pos < hardLim:
      let w = walkScriptStream(g, pos, hardLim)
      if not isGoodScriptStream(w): break
      consumed += w.length
      streams += 1
      pos += w.length
      if streams > 30: break
    if consumed > c.length + 4:
      # extends past unclaimed
      let overhang = consumed - c.length
      candidates.add (c.offset, c.length, consumed)
      carveBytes += consumed
      carveN += 1

  candidates.sort(proc(a,b:(int,int,int)):int = cmp(b[2], a[2]))
  echo &"candidates: {carveN} total stream bytes {carveBytes}"
  for i in 0 .. min(30, candidates.high):
    let (o, l, t) = candidates[i]
    echo &"  start 0x{o:06X} unclaimed={l} fullSS={t} gain_meta={t} (was code overhang~{t-l})"

  # Safer residual-only: claim only unclaimed portion when full stream validates
  echo "\n===== residual-only SS when full stream validates (no carve) ====="
  var residualOnly = 0
  var spans: seq[(int,int)] = @[]
  for (o, l, t) in candidates:
    # claim just the unclaimed prefix if it's a clean prefix of good streams
    # verify: walk with limit=o+t equals t, and first streams cover o..o+l
    let w = walkScriptStream(g, o, o + t)
    if isGoodScriptStream(w) and w.length == t:
      residualOnly += l
      spans.add (o, l)
    else:
      # multi-stream: use consumeScriptStreamRun
      let got = consumeScriptStreamRun(g, o, t)
      if got == t:
        residualOnly += l
        spans.add (o, l)
  echo &"residual-only claimable (validated by full stream): {residualOnly} B in {spans.len} spans"
  for i in 0 .. min(20, spans.high):
    echo &"  0x{spans[i][0]:06X}+{spans[i][1]}"

main()
