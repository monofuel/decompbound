## Scan gold ROM banks C0-C4 for AbsoluteLong opcodes whose 24-bit operand
## lands in residual free runs of CA/CE/D7/DB. Also try to infer fixed record
## sizes from residual run structure and find pointer tables into those runs.

import
  std/[algorithm, os, strformat, strutils, tables, sets],
  ../decompbound/[memmap, rom_chunks]

const
  Gold = "bin/Earthbound (U) [!].smc"
  TargetFileBanks = {0x0A, 0x0E, 0x17, 0x1B}
  # Absolute long opcodes (24-bit operand)
  # AF LDA al, CF CMP al, EF SBC al, BF LDA al,X, DF CMP al,X, FF SBC al,X
  # 8F STA al, 9F STA al,X, 22 JSL, 5C JML
  AbsLongOps = {0xAF'u8, 0xCF'u8, 0xEF'u8, 0xBF'u8, 0xDF'u8, 0xFF'u8,
                0x8F'u8, 0x9F'u8}

proc main() =
  ## Find real AbsoluteLong loaders into residual dense banks.
  let gold = readFile(Gold)
  let chunks = allRomChunksMeta()
  var claimed = newSeq[bool](gold.len)
  var isCode = newSeq[bool](gold.len)
  for c in chunks:
    if c.kind != ckUnclaimed:
      for i in c.offset ..< min(c.offset + c.length, claimed.len):
        claimed[i] = true
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset + c.length, isCode.len):
        isCode[i] = true

  type Run = object
    off, len: int
  var runs: seq[Run] = @[]
  var i = 0
  while i < gold.len:
    if claimed[i] or (i div 0x10000) notin TargetFileBanks:
      i += 1
      continue
    let start = i
    let fb0 = start div 0x10000
    while i < gold.len and not claimed[i] and (i div 0x10000) == fb0:
      i += 1
    runs.add Run(off: start, len: i - start)

  proc findRun(fo: int): int =
    for r in runs:
      if fo >= r.off and fo < r.off + r.len: return r.off
    -1

  # Scan file banks 0..4 (C0-C4) for abs long ops
  type LHit = object
    op: uint8
    at: int # file off of opcode
    snesTarget: uint32
    foTarget: int
    runOff: int
    runLen: int

  var lhits: seq[LHit] = @[]
  for bank in 0..4:
    let base = bank * 0x10000
    let limit = base + 0x10000 - 4
    var p = base
    while p < limit and p < gold.len:
      # only trust ops inside code spans (avoid data false positives)
      if not isCode[p]:
        p += 1
        continue
      let op = gold[p].uint8
      if op in AbsLongOps:
        let lo = gold[p+1].uint8.uint32
        let hi = gold[p+2].uint8.uint32
        let bk = gold[p+3].uint8.uint32
        let snes = lo or (hi shl 8) or (bk shl 16)
        let fb = int(bk) - 0xC0
        if fb in TargetFileBanks:
          let fo = snesToFile(snes)
          if fo >= 0 and fo < gold.len:
            let ro = findRun(fo)
            if ro >= 0:
              var rl = 0
              for r in runs:
                if r.off == ro: rl = r.len; break
              lhits.add LHit(op: op, at: p, snesTarget: snes, foTarget: fo,
                runOff: ro, runLen: rl)
      p += 1

  echo &"AbsoluteLong ops in C0-C4 code spans → residual CA/CE/D7/DB: {lhits.len}"
  # group by run
  var byRun = initTable[int, seq[LHit]]()
  for h in lhits:
    if h.runOff notin byRun: byRun[h.runOff] = @[]
    byRun[h.runOff].add h
  var keys: seq[int] = @[]
  for k in byRun.keys: keys.add k
  keys.sort(proc(a,b: int): int = cmp(byRun[b].len, byRun[a].len))
  for k in keys:
    let hs = byRun[k]
    echo &"  run 0x{k:06X}+{hs[0].runLen} hits={hs.len}"
    var shown = 0
    for h in hs:
      if shown >= 6: break
      let opName = case h.op
        of 0xAF: "LDA.L"
        of 0xBF: "LDA.L,X"
        of 0xCF: "CMP.L"
        of 0xDF: "CMP.L,X"
        of 0xEF: "SBC.L"
        of 0xFF: "SBC.L,X"
        of 0x8F: "STA.L"
        of 0x9F: "STA.L,X"
        else: &"op{h.op:02X}"
      echo &"    {opName} ${h.snesTarget:06X}  @file 0x{h.at:06X} (SNES ${fileToSnes(h.at):06X})"
      shown += 1

  # Broader: ANY bank code span abs long → residual targets
  var allHits = 0
  var byRunAll = initTable[int, seq[LHit]]()
  for bank in 0..0x2F:
    let base = bank * 0x10000
    let limit = min(base + 0x10000 - 4, gold.len)
    var p = base
    while p < limit:
      if not isCode[p]:
        p += 1
        continue
      let op = gold[p].uint8
      if op in AbsLongOps:
        let lo = gold[p+1].uint8.uint32
        let hi = gold[p+2].uint8.uint32
        let bk = gold[p+3].uint8.uint32
        let snes = lo or (hi shl 8) or (bk shl 16)
        let fb = int(bk) - 0xC0
        if fb in TargetFileBanks:
          let fo = snesToFile(snes)
          if fo >= 0 and fo < gold.len:
            let ro = findRun(fo)
            if ro >= 0:
              allHits += 1
              var rl = 0
              for r in runs:
                if r.off == ro: rl = r.len; break
              if ro notin byRunAll: byRunAll[ro] = @[]
              byRunAll[ro].add LHit(op: op, at: p, snesTarget: snes, foTarget: fo,
                runOff: ro, runLen: rl)
      p += 1
  echo &"\nAll banks AbsoluteLong → residual: {allHits} hits across {byRunAll.len} runs"
  keys = @[]
  for k in byRunAll.keys: keys.add k
  keys.sort(proc(a,b: int): int =
    result = cmp(byRunAll[b].len, byRunAll[a].len)
    if result == 0: result = cmp(b, a)) # prefer larger runs? by hit count
  for idx in 0 ..< min(20, keys.len):
    let k = keys[idx]
    let hs = byRunAll[k]
    echo &"  run 0x{k:06X}+{hs[0].runLen} hits={hs.len} first=${hs[0].snesTarget:06X} from 0x{hs[0].at:06X}"

  # Also: scan for base addresses just BEFORE residual (claimed table heads)
  # that might be indexed into residual mid-body
  echo "\n--- Bases: claimed abs-long targets within 4KB before each large residual run ---"
  var largeRuns: seq[Run] = runs
  largeRuns.sort(proc(a,b: Run): int = cmp(b.len, a.len))
  for ri in 0 ..< min(15, largeRuns.len):
    let r = largeRuns[ri]
    # search code for abs long pointing to [r.off-0x1000, r.off+r.len)
    var bases: seq[tuple[fo: int, snes: uint32, at: int, op: uint8]] = @[]
    let windowLo = max(0, r.off - 0x1000)
    let windowHi = r.off + r.len
    for bank in 0..4:
      let base = bank * 0x10000
      let limit = min(base + 0x10000 - 4, gold.len)
      var p = base
      while p < limit:
        if not isCode[p]:
          p += 1
          continue
        let op = gold[p].uint8
        if op in {0xAF'u8, 0xBF'u8, 0xCF'u8, 0x8F'u8}:
          let lo = gold[p+1].uint8.uint32
          let hi = gold[p+2].uint8.uint32
          let bk = gold[p+3].uint8.uint32
          let snes = lo or (hi shl 8) or (bk shl 16)
          let fo = snesToFile(snes)
          if fo >= windowLo and fo < windowHi:
            bases.add (fo, snes, p, op)
        p += 1
    if bases.len > 0:
      echo &"  run 0x{r.off:06X}+{r.len}: {bases.len} C0-C4 abs-long near-window"
      var uniq = initHashSet[uint32]()
      for b in bases:
        if b.snes in uniq: continue
        uniq.incl b.snes
        if uniq.len > 8: break
        let inRes = not claimed[b.fo]
        echo &"    ${b.snes:06X} fo=0x{b.fo:06X} residual={inRes} from 0x{b.at:06X} op={b.op:02X}"

  # Structure probe: for top residual runs, try record sizes 2..32
  echo "\n--- Structure: fixed record size fit for top residual runs ---"
  for ri in 0 ..< min(12, largeRuns.len):
    let r = largeRuns[ri]
    var bestSz = 0
    var bestScore = -1.0
    for sz in [2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20, 24, 25, 27, 28, 32]:
      if r.len < sz * 3: continue
      let n = r.len div sz
      # score: low variance of byte-at-position across records; high mono of first u16
      var posEntropy = 0.0
      for pos in 0 ..< sz:
        var counts: array[256, int]
        for rec in 0 ..< n:
          counts[gold[r.off + rec * sz + pos].uint8] += 1
        var mx = 0
        for c in counts: mx = max(mx, c)
        posEntropy += mx.float / n.float
      let avg = posEntropy / sz.float
      # u16 monotonicity at +0
      var mono = 0
      if sz >= 2:
        for rec in 1 ..< n:
          let a = gold[r.off + (rec-1)*sz].int or (gold[r.off + (rec-1)*sz + 1].int shl 8)
          let b = gold[r.off + rec*sz].int or (gold[r.off + rec*sz + 1].int shl 8)
          if b >= a: mono += 1
      let monoR = if n > 1: mono.float / (n-1).float else: 0
      let score = avg + monoR * 0.3
      if score > bestScore:
        bestScore = score
        bestSz = sz
    # also check FF-terminated
    var ffRecs = 0
    var j = 0
    while j < r.len:
      var k = j
      while k < r.len and gold[r.off + k].uint8 != 0xFF: k += 1
      if k < r.len:
        let recLen = k - j + 1
        if recLen >= 2 and recLen <= 32: ffRecs += 1
        j = k + 1
      else:
        break
    var hex = ""
    for b in 0 ..< min(24, r.len):
      hex.add &"{gold[r.off+b].uint8:02X} "
    echo &"  0x{r.off:06X}+{r.len}: best fixed sz={bestSz} score={bestScore:.3f} ffRecs~{ffRecs}"
    echo &"    head: {hex}"

  # Global residual analysis: how much residual is "interior" holes of size <32
  # surrounded by code on both sides (false-code reclass candidate vs true tables)
  var interiorSmall, edgeLarge = 0
  for r in runs:
    let leftCode = r.off > 0 and isCode[r.off - 1]
    let rightCode = r.off + r.len < gold.len and isCode[r.off + r.len]
    if leftCode and rightCode and r.len < 32:
      interiorSmall += r.len
    elif r.len >= 64:
      edgeLarge += r.len
  echo &"\nInterior residual holes <32B (code both sides): {interiorSmall} B"
  echo &"Large residual ≥64B: {edgeLarge} B"
  var allRes = 0
  for r in runs: allRes += r.len
  echo &"All residual in target banks: {allRes} B"

main()
