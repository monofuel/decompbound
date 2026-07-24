## Probe residual free for complete action-script walks.

import
  std/[algorithm, strformat],
  ../decompbound/[rom_chunks, baserom_extract, action_script]

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  ## Residual free runs.
  result = @[]
  var rs = -1
  var rl = 0
  for o in 0 ..< claimed.len:
    if not claimed[o]:
      if rs < 0:
        rs = o
        rl = 1
      else:
        rl += 1
    else:
      if rs >= 0:
        result.add (rs, rl)
        rs = -1
  if rs >= 0:
    result.add (rs, rl)

proc main() =
  ## Find residual action-script and idle-block claims.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      for i in c.offset ..< min(c.offset + c.length, claimed.len):
        claimed[i] = true

  var runs = freeRuns(claimed)
  runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))

  var asTot = 0
  var asN = 0
  var claimMask = claimed
  for r in runs:
    if r.n < 6:
      continue
    var pos = r.o
    let lim = r.o + r.n
    var covered = 0
    while pos < lim:
      let w = walkActionScript(g, pos, lim)
      if not isGoodActionScriptWalk(w):
        break
      covered += w.length
      pos += w.length
    if covered >= 6:
      echo &"  AS 0x{r.o:06X}+{covered} (run {r.n})"
      asTot += covered
      asN += 1
      for j in 0 ..< covered:
        claimMask[r.o + j] = true

  echo &"# AS claimable: {asTot} B in {asN}"

  var idle = 0
  for r in freeRuns(claimMask):
    var o = r.o
    let endO = r.o + r.n
    while o + 9 <= endO:
      if isIdleActionBlock(g, o):
        var n = 0
        var p = o
        while p + 9 <= endO and isIdleActionBlock(g, p):
          n += 9
          p += 9
        if n >= 9:
          echo &"  idle 0x{o:06X}+{n}"
          idle += n
          o = p
          continue
      o += 1
  echo &"# idle blocks: {idle} B"
  echo &"# total AS+idle: {asTot + idle}"

main()
