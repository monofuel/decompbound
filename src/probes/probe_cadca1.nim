## RE $CADCA1 17-byte table (loader scales X = id*17) and residual free runs.

import
  std/[algorithm, strformat, strutils],
  ../decompbound/[memmap, rom_chunks]

const
  Gold = "bin/Earthbound (U) [!].smc"
  Base = 0x0ADCA1
  RecSz = 17

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0..<n:
    if o + j < c.len: c[o + j] = true

proc isFree(c: seq[bool]; o, n: int): bool =
  if o < 0 or o + n > c.len: return false
  for j in 0..<n:
    if c[o + j]: return false
  true

proc main() =
  let g = readFile(Gold)
  var claimed = newSeq[bool](g.len)
  for ch in allRomChunksMeta():
    if ch.kind != ckUnclaimed:
      mark(claimed, ch.offset, ch.length)

  # Walk records while still in bank CA and somewhat structured
  var n = 0
  var freeRecs = 0
  var freeBytes = 0
  var freeRuns: seq[tuple[o, n, id0, id1: int]] = @[]
  var runS = -1
  var runL = 0
  var id0, id1 = 0
  while Base + (n + 1) * RecSz <= 0x0B0000 and n < 512:
    let o = Base + n * RecSz
    # soft end: long zero runs or leave bank
    var allZero = true
    for j in 0..<RecSz:
      if g[o + j].uint8 != 0: allZero = false
    # don't stop on zeros (valid empty records)
    if isFree(claimed, o, RecSz):
      freeRecs += 1
      freeBytes += RecSz
      if runS < 0:
        runS = o; runL = RecSz; id0 = n; id1 = n
      elif o == runS + runL:
        runL += RecSz; id1 = n
      else:
        freeRuns.add (runS, runL, id0, id1)
        runS = o; runL = RecSz; id0 = n; id1 = n
    else:
      if runS >= 0:
        freeRuns.add (runS, runL, id0, id1)
        runS = -1
    n += 1
    # stop if we're deep into next different structure: after ~200 all nonfree and past residual zone
    if n > 100 and freeRecs == 0 and o > 0x0AF000:
      # keep counting for size
      discard
  if runS >= 0: freeRuns.add (runS, runL, id0, id1)

  # Find table end: first id where next 4 records look invalid?
  # Use: scan until 0x0B0000, report residual
  echo &"Scanned {n} × {RecSz}B records from $CADCA1"
  echo &"Full residual free records: {freeRecs} ({freeBytes} B) in {freeRuns.len} runs"
  for r in freeRuns:
    var head = ""
    for b in 0 ..< min(17, r.n):
      head.add &"{g[r.o + b].uint8:02X} "
    echo &"  0x{r.o:06X}+{r.n} ids {r.id0}..{r.id1}  {head}"

  # Partial residual (not full 17)
  var partial = 0
  for i in 0..<n:
    let o = Base + i * RecSz
    if isFree(claimed, o, RecSz): continue
    var fb = 0
    for j in 0..<RecSz:
      if not claimed[o + j]: fb += 1
    if fb > 0: partial += fb
  echo &"Partial mid-record residual (not claimed): {partial} B"

  # Field structure sample first 8 records
  echo "Sample records (17B):"
  for i in 0 ..< min(8, n):
    let o = Base + i * RecSz
    var h = ""
    for b in 0..<RecSz:
      h.add &"{g[o+b].uint8:02X} "
    echo &"  id{i}: {h}  free={isFree(claimed, o, RecSz)}"

  # Also D7A800 claim list
  echo "\nD7A800 residual free runs [0x17A800,0x17B200):"
  var d7 = 0
  var rs = -1
  var rl = 0
  var d7runs: seq[tuple[o, n: int]] = @[]
  for o in 0x17A800 ..< 0x17B200:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0:
        d7runs.add (rs, rl); d7 += rl; rs = -1
  if rs >= 0: d7runs.add (rs, rl); d7 += rl
  for r in d7runs:
    echo &"  0x{r.o:06X}+{r.n}"
  echo &"  total {d7} B"

main()
