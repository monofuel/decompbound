## Find C0-C4 LDA.L/LDA.L,X table bases where residual free runs sit mid-table
## (between base and next known boundary / within 16KB of base).

import
  std/[algorithm, strformat, strutils, tables, sets],
  ../decompbound/[memmap, rom_chunks]

const Gold = "bin/Earthbound (U) [!].smc"

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0..<n:
    if o + j < c.len: c[o + j] = true

proc main() =
  let g = readFile(Gold)
  var claimed = newSeq[bool](g.len)
  for ch in allRomChunksMeta():
    if ch.kind != ckUnclaimed:
      mark(claimed, ch.offset, ch.length)

  # Collect unique LDA.L / LDA.L,X targets from C0-C4 into banks CA CE D7 DB
  type Base = object
    fo: int
    snes: uint32
    ops: int
    sites: seq[int]
  var bases = initTable[int, Base]()
  for bank in 0..4:
    let b0 = bank * 0x10000
    for p in b0 ..< b0 + 0x10000 - 4:
      let op = g[p].uint8
      if op notin {0xAF'u8, 0xBF'u8}: continue
      let snes = g[p+1].uint8.uint32 or (g[p+2].uint8.uint32 shl 8) or
        (g[p+3].uint8.uint32 shl 16)
      let fb = int((snes shr 16) and 0xFF) - 0xC0
      if fb notin {0x0A, 0x0E, 0x17, 0x1B}: continue
      let fo = snesToFile(snes)
      if fo < 0: continue
      if fo notin bases:
        bases[fo] = Base(fo: fo, snes: snes, ops: 0, sites: @[])
      bases[fo].ops += 1
      if bases[fo].sites.len < 5:
        bases[fo].sites.add p

  var items: seq[Base] = @[]
  for _, v in bases: items.add v
  items.sort(proc(a, b: Base): int = cmp(b.ops, a.ops))

  echo &"C0-C4 LDA.L/X bases into CA/CE/D7/DB: {items.len}"
  var totalClaimable = 0
  for it in items:
    # window: base .. base+0x2000 within same file bank
    let fb = it.fo div 0x10000
    let winEnd = min(it.fo + 0x2000, (fb + 1) * 0x10000)
    var free = 0
    var runs: seq[tuple[o, n: int]] = @[]
    var rs = -1
    var rl = 0
    for o in it.fo ..< winEnd:
      if not claimed[o]:
        if rs < 0: rs = o; rl = 1
        else: rl += 1
      else:
        if rs >= 0:
          runs.add (rs, rl)
          free += rl
          rs = -1
    if rs >= 0:
      runs.add (rs, rl)
      free += rl
    if free < 4: continue
    runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))
    totalClaimable += free
    echo &"  ${it.snes:06X} fo=0x{it.fo:06X} refs={it.ops} residual_in_+8K={free} B runs={runs.len}"
    echo &"    sites: {it.sites}"
    for r in runs[0 ..< min(6, runs.len)]:
      echo &"    free 0x{r.o:06X}+{r.n}"

  echo &"\nTotal residual mid-window of C0-C4 bases: {totalClaimable} B"

  # Specifically list ALL C0-C4 abs long bases into these banks
  echo "\nAll bases (even 0 residual):"
  for it in items:
    echo &"  ${it.snes:06X} refs={it.ops} claimed_base={claimed[it.fo]}"

main()
