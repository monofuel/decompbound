
import std/[strformat, algorithm],
  ../decompbound/[rom_chunks, baserom_extract, memmap]

proc freeIn(claimed: seq[bool]; lo, hi: int): seq[tuple[o,n:int]] =
  result = @[]
  var rs = -1; var rl = 0
  for o in lo ..< min(hi, claimed.len):
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0: result.add (rs, rl); rs = -1
  if rs >= 0: result.add (rs, rl)

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset..<min(c.offset+c.length, claimed.len): claimed[i]=true

let windows = [
  ("EF sprite ptrs/bodies", 0x2F133F, 0x2F6000),
  ("C4 hitbox", 0x042B0D, 0x043200),
  ("C5 idx+body", 0x05A5B6, 0x060000),
  ("formPtr 8B", 0x10C60D, 0x10C60D+484*8),
  ("owEnemyArr", 0x10B880, 0x10C60D),
  ("item 0x27", 0x155000, 0x155000+254*0x27),
  ("shop 7B", 0x1578B2, 0x1578B2+66*7),
  ("exp u32", 0x158F51, 0x158F51+4*0x190),
  ("CADCA1 17B", 0x0ADCA1, 0x0ADCA1+280*17),
  ("CADEA1 17B", 0x0ADEA1, 0x0ADEA1+327*17),
  ("D7A800 attr", 0x17A800, 0x17B200),
  ("D7B200 prop", 0x17B200, 0x17B200+0x200),
  ("CEDC45 ptrs", 0x0EDC45, 0x0EDC45+126*2),
  ("CE62EE 5B", 0x0E62EE, 0x0E62EE+110*5),
  ("CF map ptrs", 0x0F6921, 0x0F6BE7),
  ("CF obj12", 0x0F9315, 0x0F9FF7),
  ("CF programs after u16", 0x0F59F1, 0x0F6921),
  ("pack table", 0x04F947, 0x04F947+170*3),
  ("song table", 0x04F70A, 0x04F947),
  ("DBA7A2 area", 0x1BA7A2, 0x1BB400),
  ("D9 audio bank", 0x190000, 0x1A0000),
  ("CC HDMA band", 0x0C6000, 0x0C8000),
  ("CA dense mid", 0x0A7000, 0x0AC000),
]

for (name, lo, hi) in windows:
  let runs = freeIn(claimed, lo, hi)
  var tot = 0
  for r in runs: tot += r.n
  if tot > 0:
    echo &"{name}: free={tot} B in {runs.len} runs"
    #
    # show largest
    var rs = runs
    rs.sort(proc(a,b: auto): int = cmp(b.n, a.n))
    for i in 0 ..< min(3, rs.len):
      echo &"    0x{rs[i].o:06X}+{rs[i].n}"
