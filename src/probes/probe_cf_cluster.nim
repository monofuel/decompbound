import
  std/[strformat, algorithm],
  ../decompbound/[rom_chunks, baserom_extract]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0..<n:
    if o+j>=0 and o+j<c.len: c[o+j]=true

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var nameAt = newSeq[string](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)
  for s in KnownBaseromExtracts:
    for j in 0..<s.length:
      if s.offset+j < nameAt.len:
        nameAt[s.offset+j] = s.name

  # window around 0x0FB000..0x0FB700
  let lo = 0x0FAF00
  let hi = 0x0FB700
  echo "claimed map (name if extract, CODE/META/free):"
  var o = lo
  while o < hi:
    if not claimed[o]:
      var e = o
      while e+1 < hi and not claimed[e+1]: e += 1
      var hx=""
      for j in 0..<min(24, e-o+1): hx.add &"{g[o+j]:02X} "
      echo &"FREE 0x{o:06X}+{e-o+1} {hx}"
      o = e+1
    else:
      let n = nameAt[o]
      var e = o
      while e+1 < hi and claimed[e+1] and nameAt[e+1]==n: e += 1
      let label = if n.len>0: n else: "CODE/META"
      echo &"CLM  0x{o:06X}+{e-o+1} {label}"
      o = e+1

  # pattern: free scraps look like u16 id + u8 + u8 heads 01 xx 00 04 08
  echo "\ntry reconstruct as 12B obj-like with holes:"
  # look at claimed neighbors of free 5B runs
  for s in KnownBaseromExtracts:
    if s.offset >= lo and s.offset < hi:
      echo &"  extract {s.name} 0x{s.offset:06X}+{s.length} {s.kind} {s.note}"

main()
