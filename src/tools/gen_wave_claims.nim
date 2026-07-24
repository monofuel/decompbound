## Generate residual claim list for this wave (print Nim spans).
import
  std/[strformat, algorithm, tables],
  ../decompbound/[baserom_extract, common, text_decode, rom_chunks, generated/code_spans]

proc isFreeRelative(claimed: seq[bool]; o, n: int): bool =
  for j in 0..<n:
    if claimed[o + j]: return false
  true

proc markRange(claimed: var seq[bool]; o, n: int) =
  for j in 0..<n: claimed[o + j] = true

proc main() =
  ## Emit BaseromExtractSpan entries for the residual wave.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](EarthboundRomSize)
  # mark existing extracts + code
  for s in allBaseromExtractSpans():
    markRange(claimed, s.offset, s.length)
  for s in GeneratedCodeSpans:
    markRange(claimed, s.offset, s.length)

  var outSpans: seq[tuple[name: string, offset, length: int, kind: string, note: string]]
  var total = 0

  # --- C5 14B index table residual ---
  block:
    let start = 0x05A5B6
    var runS = -1
    var runL = 0
    for i in 0..<253:
      let o = start + i * 14
      if isFreeRelative(claimed, o, 14):
        if runS < 0: runS = o
        runL += 14
      else:
        if runL > 0:
          outSpans.add (
            &"table_c5Idx14_0x{runS:06X}", runS, runL, "ekTable",
            "C5 14B index recs residual: far ptr bank $C5 + 00 18 07 + id + fixed tail; 253-wide table @$C5A5B6; bodies prefix 01 50 6C 1C 05")
          markRange(claimed, runS, runL)
          total += runL
        runS = -1; runL = 0
    if runL > 0:
      outSpans.add (
        &"table_c5Idx14_0x{runS:06X}", runS, runL, "ekTable",
        "C5 14B index recs residual: far ptr bank $C5 + 00 18 07 + id + fixed tail; 253-wide table @$C5A5B6; bodies prefix 01 50 6C 1C 05")
      markRange(claimed, runS, runL)
      total += runL

  # --- C5 body residual (ptr-bounded, prefix-validated) ---
  block:
    let start = 0x05A5B6
    type PE = tuple[id, f: int]
    var ptrs: seq[PE] = @[]
    for i in 0..<253:
      let o = start + i * 14
      let lo = g[o].int or (g[o+1].int shl 8)
      let id = g[o+6].int
      ptrs.add (id, (0xC5 - 0xC0) * 0x10000 + lo)
    ptrs.sort(proc(a, b: PE): int = cmp(a.f, b.f))
    var uniq: seq[PE] = @[]
    for p in ptrs:
      if uniq.len == 0 or uniq[^1].f != p.f: uniq.add p
    var runS = -1
    var runL = 0
    var id0, id1: int
    for i in 0 ..< uniq.len - 1:
      let f = uniq[i].f
      let ln = uniq[i+1].f - f
      if ln <= 0 or ln > 200: 
        if runL > 0:
          outSpans.add (
            &"table_c5Body_0x{runS:06X}", runS, runL, "ekTable",
            &"C5 body residual ids {id0}..{id1}; ptr-bounded from $C5A5B6 14B index; prefix 01 50 6C 1C 05")
          markRange(claimed, runS, runL)
          total += runL
        runS = -1; runL = 0
        continue
      let prefixOk = g[f] == 0x01 and g[f+1] == 0x50 and g[f+2] == 0x6C and
          g[f+3] == 0x1C and g[f+4] == 0x05
      if prefixOk and isFreeRelative(claimed, f, ln):
        if runS < 0:
          runS = f; runL = ln; id0 = uniq[i].id; id1 = uniq[i].id
        elif f == runS + runL:
          runL += ln; id1 = uniq[i].id
        else:
          outSpans.add (
            &"table_c5Body_0x{runS:06X}", runS, runL, "ekTable",
            &"C5 body residual ids {id0}..{id1}; ptr-bounded from $C5A5B6 14B index; prefix 01 50 6C 1C 05")
          markRange(claimed, runS, runL)
          total += runL
          runS = f; runL = ln; id0 = uniq[i].id; id1 = uniq[i].id
      else:
        if runL > 0:
          outSpans.add (
            &"table_c5Body_0x{runS:06X}", runS, runL, "ekTable",
            &"C5 body residual ids {id0}..{id1}; ptr-bounded from $C5A5B6 14B index; prefix 01 50 6C 1C 05")
          markRange(claimed, runS, runL)
          total += runL
        runS = -1; runL = 0
    if runL > 0:
      outSpans.add (
        &"table_c5Body_0x{runS:06X}", runS, runL, "ekTable",
        &"C5 body residual ids {id0}..{id1}; ptr-bounded from $C5A5B6 14B index; prefix 01 50 6C 1C 05")
      markRange(claimed, runS, runL)
      total += runL

  # --- BBG layer 17B residual ---
  block:
    let base = 0x0ADEA1
    var runS = -1
    var runL = 0
    for i in 0..<327:
      let o = base + i * 17
      if isFreeRelative(claimed, o, 17):
        if runS < 0: runS = o
        runL += 17
      else:
        if runL > 0:
          outSpans.add (
            &"table_bbgLayer17_0x{runS:06X}", runS, runL, "ekTable",
            "battle-BG layer table residual 17B/entry @$CADEA1 (~327 layers); docs/battle-backgrounds.md")
          markRange(claimed, runS, runL)
          total += runL
        runS = -1; runL = 0
    if runL > 0:
      outSpans.add (
        &"table_bbgLayer17_0x{runS:06X}", runS, runL, "ekTable",
        "battle-BG layer table residual 17B/entry @$CADEA1 (~327 layers); docs/battle-backgrounds.md")
      markRange(claimed, runS, runL)
      total += runL

  # --- Full SS streams starting in unclaimed, may carve false code via extract priority ---
  # Strategy: find unclaimed starts, walk consecutive good streams as far as possible.
  # Claim each individual good stream that has ANY free bytes; length = full stream.
  # Only if every byte of the stream is either free OR currently code (not extract/adopted).
  # Rebuild "code-only" mask for carve targets.
  var isCode = newSeq[bool](EarthboundRomSize)
  for s in GeneratedCodeSpans:
    for j in 0..<s.length: isCode[s.offset + j] = true
  var isExtract = newSeq[bool](EarthboundRomSize)
  for s in allBaseromExtractSpans():
    for j in 0..<s.length: isExtract[s.offset + j] = true
  # also mark what we'll add as extract so far
  for s in outSpans:
    for j in 0..<s.length: isExtract[s.offset + j] = true

  let chunks = allRomChunksMeta()
  var ssCandidates: seq[(int, int)] = @[]
  for c in chunks:
    if c.kind != ckUnclaimed or c.length < 6: continue
    var pos = c.offset
    # Only start a stream at the gap start or after prior stream in this gap chain
    # Actually scan for stream starts that are free
    while pos < c.offset + c.length:
      if isExtract[pos]:
        pos += 1
        continue
      let hardLim = min(pos + ScriptStreamMaxLen, g.len)
      let w = walkScriptStream(g, pos, hardLim)
      if not isGoodScriptStream(w):
        pos += 1
        continue
      # validate every byte is free or code (carveable)
      var ok = true
      var freeBytes = 0
      var codeBytes = 0
      for j in 0..<w.length:
        let p = pos + j
        if isExtract[p]:
          ok = false
          break
        if isCode[p]: codeBytes += 1
        else: freeBytes += 1
      if ok and freeBytes > 0 and (codeBytes > 0 or freeBytes == w.length):
        # prefer streams that are fully free OR carve code
        ssCandidates.add (pos, w.length)
      pos += 1  # will skip; better jump
      # actually if good stream, jump by length to avoid overlap
      # but we may have failed ok - then +1

  # re-do cleaner: only start at free bytes; on success jump by length
  ssCandidates = @[]
  for c in chunks:
    if c.kind != ckUnclaimed or c.length < 6: continue
    var pos = c.offset
    let gapEnd = c.offset + c.length
    while pos < gapEnd:
      if isExtract[pos]:
        pos += 1
        continue
      let w = walkScriptStream(g, pos, min(pos + ScriptStreamMaxLen, g.len))
      if not isGoodScriptStream(w):
        pos += 1
        continue
      var ok = true
      var freeBytes = 0
      for j in 0..<w.length:
        let p = pos + j
        if isExtract[p]:
          ok = false; break
        # allow free (unclaimed) or code (carve)
        # not allowed: other meta already in isExtract
        if not isCode[p]:
          # must be unclaimed (not already claimed by something non-code non-extract)
          # After marking extracts and code, free = not extract and not code... but adopted?
          freeBytes += 1
      if ok and freeBytes > 0:
        # ensure stream doesn't hit non-code non-free that's not extract-checked
        # simplify: all bytes either !claimed-original-extract and (code or unclaimed)
        var ok2 = true
        for j in 0..<w.length:
          let p = pos + j
          # original extract before this wave
          if isBaseromExtractOffset(p) and not (p >= pos and p < pos): 
            discard
        # Use: for each byte, either isCode or currently unclaimed in chunk inventory
        for j in 0..<w.length:
          let p = pos + j
          if isBaseromExtractOffset(p):
            ok2 = false; break
          # if not code and not in any unclaimed... check claimed mask from start of main
          # rebuild: allowed if isCode or not claimed (wait claimed includes code)
        if ok2:
          # check overhang bytes that are code OR free
          var ok3 = true
          var fb = 0
          for j in 0..<w.length:
            let p = pos + j
            if isBaseromExtractOffset(p):
              ok3 = false; break
            if isCode[p]:
              discard
            else:
              # must not be inside a code span we're not marking - if it's implemented meta non-extract?
              # free unclaimed only
              fb += 1
          if ok3 and fb > 0:
            ssCandidates.add (pos, w.length)
            # mark so we don't re-claim
            for j in 0..<w.length:
              isExtract[pos + j] = true
            pos += w.length
            continue
      pos += 1

  # Simpler robust approach for SS carve:
  ssCandidates = @[]
  # reset isExtract to only original extracts + table claims we'll add
  isExtract = newSeq[bool](EarthboundRomSize)
  for s in allBaseromExtractSpans():
    for j in 0..<s.length: isExtract[s.offset + j] = true
  for s in outSpans:
    for j in 0..<s.length: isExtract[s.offset + j] = true

  proc streamCarveOk(pos, length: int): bool =
    var freeB = 0
    for j in 0..<length:
      let p = pos + j
      if isExtract[p]: return false
      if isCode[p]:
        discard
      else:
        freeB += 1
    freeB > 0

  for c in chunks:
    if c.kind != ckUnclaimed or c.length < 6: continue
    var pos = c.offset
    while pos < c.offset + c.length:
      if isExtract[pos]:
        pos += 1; continue
      let w = walkScriptStream(g, pos, min(pos + ScriptStreamMaxLen, g.len))
      if isGoodScriptStream(w) and streamCarveOk(pos, w.length):
        ssCandidates.add (pos, w.length)
        for j in 0..<w.length: isExtract[pos + j] = true
        pos += w.length
      else:
        pos += 1

  # Merge contiguous SS candidates for cleaner spans? Test requires consumeScriptStreamRun cover - merged OK if consecutive good streams
  ssCandidates.sort(proc(a, b: (int, int)): int = cmp(a[0], b[0]))
  # merge adjacent
  var merged: seq[(int, int)] = @[]
  for (o, l) in ssCandidates:
    if merged.len > 0 and merged[^1][0] + merged[^1][1] == o:
      merged[^1][1] += l
    else:
      merged.add (o, l)

  for (o, l) in merged:
    # verify consume covers
    let got = consumeScriptStreamRun(g, o, l)
    if got != l:
      # split into individual streams instead
      var pos = o
      while pos < o + l:
        let w = walkScriptStream(g, pos, o + l)
        if not isGoodScriptStream(w): break
        outSpans.add (
          &"scriptStream_0x{pos:06X}", pos, w.length, "ekScriptStream",
          "residual/carve SS: good CC walk; may replace false-positive code_span mid-stream (extract wins at code start)")
        total += w.length
        pos += w.length
    else:
      outSpans.add (
        &"scriptStream_0x{o:06X}", o, l, "ekScriptStream",
        "residual/carve SS run: consecutive good CC walks; extract carves false-positive code_spans whose start falls inside")
      total += l

  # zero pad 10
  if isFreeRelative(claimed, 0x00FFB6, 10):
    # check zeros
    var z = true
    for i in 0..<10:
      if g[0x00FFB6 + i] != 0: z = false
    if z:
      outSpans.add (
        "zero_pad_0x00FFB6", 0x00FFB6, 10, "ekZeroPad",
        "residual zero padding")
      total += 10

  outSpans.sort(proc(a, b: auto): int = cmp(a.offset, b.offset))
  echo &"# wave total claim bytes: {total}"
  echo &"# span count: {outSpans.len}"
  for s in outSpans:
    echo &"  BaseromExtractSpan("
    echo &"    name: \"{s.name}\","
    echo &"    offset: 0x{s.offset:06X},"
    echo &"    length: {s.length},"
    echo &"    kind: {s.kind},"
    echo &"    note: \"{s.note}\"),"

main()
