
import std/[strformat], ../decompbound/[rom_chunks, baserom_extract]
proc mark(c: var seq[bool]; o, n: int) =
  for j in 0..<n:
    if o+j < c.len: c[o+j]=true
proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
  var codeLike, asLike, tiny, mid = 0
  var o = 0
  while o < g.len:
    if claimed[o]: o+=1; continue
    let start=o
    while o < g.len and not claimed[o]: o+=1
    let n = o-start
    if n <= 3: tiny += n
    elif n <= 7: mid += n
    if n >= 7 and g[start]==0xC2 and g[start+1]==0x31:
      codeLike += n
      echo &"code 0x{start:06X}+{n}"
    if n >= 4 and g[start]==0x42 and g[start+3] >= 0xC0 and g[start+3] <= 0xFF:
      asLike += n
  echo &"tiny1-3={tiny} mid4-7={mid} codeLikeC2={codeLike} asLike42={asLike}"
main()
