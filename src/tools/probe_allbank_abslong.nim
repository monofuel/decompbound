## Scan AbsoluteLong loaders from ALL ROM code banks into residual free runs.
## Also discover unclaimed APU packages from the pack table and probe residual
## islands for package structure. Emits claimable residual spans only.

import
  std/[algorithm, os, strformat, strutils, tables, sets],
  ../decompbound/[memmap, rom_chunks, baserom_extract, common]

const
  Gold = "bin/Earthbound (U) [!].smc"
  PackTableFile = 0x04F947
  PackCount = 169 # song-loader pack table size (3 B/entry)
  # Absolute long load/store ops with 24-bit operand (not JSL/JML)
  AbsLongOps = {0xAF'u8, 0xCF'u8, 0xEF'u8, 0xBF'u8, 0xDF'u8, 0xFF'u8,
                0x8F'u8, 0x9F'u8}
  LoadOps = {0xAF'u8, 0xBF'u8, 0xCF'u8, 0xDF'u8, 0xEF'u8, 0xFF'u8}

proc opName(op: uint8): string =
  ## Mnemonic for absolute-long opcode.
  case op
  of 0xAF: "LDA.L"
  of 0xBF: "LDA.L,X"
  of 0xCF: "CMP.L"
  of 0xDF: "CMP.L,X"
  of 0xEF: "SBC.L"
  of 0xFF: "SBC.L,X"
  of 0x8F: "STA.L"
  of 0x9F: "STA.L,X"
  else: &"op{op:02X}"

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len:
      c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len:
    return false
  for j in 0 ..< n:
    if claimed[o + j]:
      return false
  true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  ## All residual free runs on the whole ROM.
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

proc freeRunsIn(claimed: seq[bool]; lo, hi: int): seq[tuple[o, n: int]] =
  result = @[]
  var rs = -1
  var rl = 0
  let lim = min(hi, claimed.len)
  for o in lo ..< lim:
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

proc packFileOff(g: seq[uint8]; packIdx: int): int =
  ## Pack table entry → file offset (bank $C0+).
  let base = PackTableFile + packIdx * 3
  if base + 2 >= g.len:
    return -1
  let bank = g[base].int
  let addrLo = g[base + 1].int or (g[base + 2].int shl 8)
  if bank < 0xC0 or bank > 0xEF:
    return -1
  snesToFile(uint32(addrLo or (bank shl 16)))

proc walkApuPackage(g: seq[uint8]; off: int; maxScan = 0x20000): tuple[
    ok: bool, size: int, blocks: int] =
  ## Walk [u16 len][u16 tgt][payload]… until len=0 terminator.
  if off < 0 or off + 4 > g.len:
    return (false, 0, 0)
  var pos = off
  var blocks = 0
  let limit = min(off + maxScan, g.len)
  while pos + 4 <= limit:
    let ln = g[pos].int or (g[pos + 1].int shl 8)
    let tgt = g[pos + 2].int or (g[pos + 3].int shl 8)
    if ln == 0:
      let size = pos + 4 - off
      if blocks == 0 and tgt == 0:
        return (false, 0, 0)
      return (true, size, blocks)
    if ln > 0xC000:
      return (false, 0, 0)
    if pos + 4 + ln > g.len:
      return (false, 0, 0)
    blocks += 1
    pos += 4 + ln
  (false, 0, 0)

proc main() =
  ## All-bank AbsoluteLong residual scan + APU pack discovery.
  let gold = readFile(Gold)
  let g = cast[seq[uint8]](gold)
  let chunks = allRomChunksMeta()

  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  for c in chunks:
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset + c.length, isCode.len):
        isCode[i] = true

  var runs = freeRuns(claimed)
  runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))
  var residualTot = 0
  for r in runs:
    residualTot += r.n
  echo &"Residual free runs: {runs.len} totaling {residualTot} B"

  # Map offset → run index for O(1)-ish lookup via sorted binary-ish walk
  # Use interval table: for each run store start, binary search.
  type LHit = object
    op: uint8
    at: int
    snesTarget: uint32
    foTarget: int
    runOff: int
    runLen: int
    srcBank: int

  proc findRun(fo: int): int =
    ## Return residual run start containing fo, or -1.
    # linear over large runs first is fine; runs ~7k
    for r in runs:
      if fo >= r.o and fo < r.o + r.n:
        return r.o
    -1

  var byRun = initTable[int, seq[LHit]]()
  var totalHits = 0
  var loadHits = 0

  echo "Scanning AbsoluteLong in all code spans (banks 00..2F)…"
  for bank in 0..0x2F:
    let base = bank * 0x10000
    let limit = min(base + 0x10000 - 4, g.len)
    var p = base
    while p < limit:
      if not isCode[p]:
        p += 1
        continue
      let op = g[p]
      if op in AbsLongOps:
        let lo = g[p + 1].uint32
        let hi = g[p + 2].uint32
        let bk = g[p + 3].uint32
        let snes = lo or (hi shl 8) or (bk shl 16)
        let fb = int(bk) - 0xC0
        if fb >= 0 and fb <= 0x2F:
          let fo = snesToFile(snes)
          if fo >= 0 and fo < g.len and not claimed[fo]:
            let ro = findRun(fo)
            if ro >= 0:
              var rl = 0
              for r in runs:
                if r.o == ro:
                  rl = r.n
                  break
              let h = LHit(op: op, at: p, snesTarget: snes, foTarget: fo,
                runOff: ro, runLen: rl, srcBank: bank)
              if ro notin byRun:
                byRun[ro] = @[]
              byRun[ro].add h
              totalHits += 1
              if op in LoadOps:
                loadHits += 1
      p += 1

  echo &"AbsoluteLong → residual free: {totalHits} hits ({loadHits} load/cmp/sbc) across {byRun.len} runs"

  var keys: seq[int] = @[]
  for k in byRun.keys:
    keys.add k
  keys.sort(proc(a, b: int): int =
    result = cmp(byRun[b].len, byRun[a].len)
    if result == 0:
      result = cmp(a, b))

  echo "\n=== Residual runs with AbsoluteLong hits (top 40) ==="
  for idx in 0 ..< min(40, keys.len):
    let k = keys[idx]
    let hs = byRun[k]
    var loads = 0
    var srcBanks = initHashSet[int]()
    var targets = initHashSet[uint32]()
    for h in hs:
      if h.op in LoadOps:
        loads += 1
      srcBanks.incl h.srcBank
      targets.incl h.snesTarget
    var hex = ""
    for b in 0 ..< min(16, hs[0].runLen):
      hex.add &"{g[k + b]:02X} "
    let snes = fileToSnes(k)
    echo &"  run 0x{k:06X}+{hs[0].runLen} (${snes:06X}) hits={hs.len} loads={loads} " &
      &"uniqTgt={targets.len} srcBanks={srcBanks.len} head={hex}"
    var shown = 0
    var seenT = initHashSet[uint32]()
    for h in hs:
      if h.snesTarget in seenT:
        continue
      seenT.incl h.snesTarget
      if shown >= 6:
        break
      echo &"    {opName(h.op)} ${h.snesTarget:06X} from bank ${0xC0+h.srcBank:02X} @0x{h.at:06X}"
      shown += 1

  # Near-window: bases within 4KB before large residual that might index into it
  echo "\n=== Near-window bases (claimed AbsoluteLong within 4KB of large residual) ==="
  for ri in 0 ..< min(25, runs.len):
    let r = runs[ri]
    if r.n < 64:
      continue
    let windowLo = max(0, r.o - 0x1000)
    let windowHi = r.o + r.n
    var bases: seq[tuple[fo: int, snes: uint32, at: int, op: uint8, bank: int]] = @[]
    for bank in 0..0x2F:
      let base = bank * 0x10000
      let limit = min(base + 0x10000 - 4, g.len)
      var p = base
      while p < limit:
        if not isCode[p]:
          p += 1
          continue
        let op = g[p]
        if op in {0xAF'u8, 0xBF'u8, 0xCF'u8, 0x8F'u8}:
          let lo = g[p + 1].uint32
          let hi = g[p + 2].uint32
          let bk = g[p + 3].uint32
          let snes = lo or (hi shl 8) or (bk shl 16)
          let fo = snesToFile(snes)
          if fo >= windowLo and fo < windowHi:
            bases.add (fo, snes, p, op, bank)
        p += 1
    if bases.len > 0:
      var uniq = initHashSet[uint32]()
      var inRes = 0
      for b in bases:
        if not claimed[b.fo]:
          inRes += 1
        uniq.incl b.snes
      if uniq.len > 0:
        echo &"  run 0x{r.o:06X}+{r.n}: {bases.len} abs-long near-window, uniq={uniq.len}, residual_tgt={inRes}"
        var n = 0
        for b in bases:
          if b.snes notin uniq:
            continue
          # print unique
          discard
        var printed = initHashSet[uint32]()
        for b in bases:
          if b.snes in printed:
            continue
          printed.incl b.snes
          if n >= 8:
            break
          echo &"    ${b.snes:06X} fo=0x{b.fo:06X} residual={not claimed[b.fo]} from ${0xC0+b.bank:02X}@0x{b.at:06X} {opName(b.op)}"
          n += 1

  # ---- APU pack discovery from pack table ----
  echo "\n=== APU pack table discovery ==="
  var knownPackBases = initHashSet[int]()
  for s in allBaseromExtractSpans():
    if s.kind != ekApuPackage:
      continue
    let n = s.note
    let a = n.find("pack@0x")
    if a < 0:
      knownPackBases.incl s.offset
      continue
    let hexStart = a + 7
    var hexEnd = hexStart
    while hexEnd < n.len and n[hexEnd] in {'0'..'9', 'A'..'F', 'a'..'f'}:
      hexEnd += 1
    knownPackBases.incl parseHexInt(n[hexStart ..< hexEnd])

  var newPacks: seq[tuple[idx, fo, size, blocks, freeBytes: int]] = @[]
  var freeInKnown = 0
  for i in 0 ..< PackCount:
    let fo = packFileOff(g, i)
    if fo < 0:
      continue
    let (ok, size, blocks) = walkApuPackage(g, fo)
    if not ok or size < 8:
      continue
    # free residual bytes inside this pack container
    var freeB = 0
    for r in freeRunsIn(claimed, fo, fo + size):
      freeB += r.n
    if fo notin knownPackBases and freeB > 0:
      newPacks.add (i, fo, size, blocks, freeB)
    elif fo in knownPackBases and freeB >= 4:
      freeInKnown += freeB

  echo &"Known pack bases from extract notes: {knownPackBases.len}"
  echo &"Free residual inside known packs (≥4B holes): ~{freeInKnown} B total (re-walk interiors)"
  echo &"New pack-table packages with residual free: {newPacks.len}"
  newPacks.sort(proc(a, b: auto): int = cmp(b.freeBytes, a.freeBytes))
  var newPackFreeTot = 0
  for p in newPacks:
    newPackFreeTot += p.freeBytes
    if newPacks.find(p) < 25:
      echo &"  pack[{p.idx}] @0x{p.fo:06X} size={p.size} blocks={p.blocks} free={p.freeBytes}"
  echo &"  total free in new packs: {newPackFreeTot} B"

  # Probe top residual islands for APU package structure at start or nearby
  echo "\n=== Residual islands APU package probe (top 30 ≥64B) ==="
  var islandApu: seq[tuple[o, n, size, blocks: int]] = @[]
  for ri in 0 ..< min(80, runs.len):
    let r = runs[ri]
    if r.n < 64:
      continue
    # try start of run and every 16 B for package header
    var found = false
    var step = 0
    while step < min(r.n, 256) and not found:
      let (ok, size, blocks) = walkApuPackage(g, r.o + step, r.n - step + 4)
      if ok and size >= 8 and blocks >= 1 and size <= r.n - step + 4:
        # require terminator fully free or mostly free
        var freeIn = 0
        for j in 0 ..< min(size, r.n - step):
          if not claimed[r.o + step + j]:
            freeIn += 1
        if freeIn >= size * 3 div 4:
          islandApu.add (r.o + step, freeIn, size, blocks)
          echo &"  apu@0x{r.o+step:06X} run=0x{r.o:06X}+{r.n} size={size} blocks={blocks} freeIn={freeIn}"
          found = true
      step += 16
    if not found and ri < 30:
      var hex = ""
      for b in 0 ..< min(12, r.n):
        hex.add &"{g[r.o + b]:02X} "
      echo &"  no apu: 0x{r.o:06X}+{r.n} head={hex}"

  # ---- Emit candidate claims for residual free inside NEW packs ----
  echo "\n# === CLAIM CANDIDATES (residual free only) ==="
  var claimTot = 0
  var claimN = 0
  var claimMask = claimed

  # 1) New APU packs: claim free runs inside container
  for p in newPacks:
    for r in freeRunsIn(claimMask, p.fo, p.fo + p.size):
      if r.n < 4:
        continue
      echo &"""  BaseromExtractSpan(
    name: "apuPack_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekApuPackage,
    note: "APU pack {p.idx} residual (pack@0x{p.fo:06X} size={p.size}); pack-table discovery; free only"),"""
      mark(claimMask, r.o, r.n)
      claimTot += r.n
      claimN += 1

  # 2) Island APU packages discovered on residual
  for a in islandApu:
    if not isFree(claimMask, a.o, a.n):
      # claim only free subruns inside package
      for r in freeRunsIn(claimMask, a.o, a.o + a.size):
        if r.n < 4:
          continue
        echo &"""  BaseromExtractSpan(
    name: "apuPack_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekApuPackage,
    note: "APU package residual walk size={a.size} blocks={a.blocks}; free only"),"""
        mark(claimMask, r.o, r.n)
        claimTot += r.n
        claimN += 1
      continue
    # whole free chunk at package start
    let claimLen = min(a.n, a.size)
    if claimLen >= 4 and isFree(claimMask, a.o, claimLen):
      echo &"""  BaseromExtractSpan(
    name: "apuPack_0x{a.o:06X}",
    offset: 0x{a.o:06X},
    length: {claimLen},
    kind: ekApuPackage,
    note: "APU package residual walk size={a.size} blocks={a.blocks}; free only"),"""
      mark(claimMask, a.o, claimLen)
      claimTot += claimLen
      claimN += 1

  # 3) Loader-backed residual: for runs with many LDA.L,X hits to same base pattern
  # Infer record size from consecutive target deltas if ≥3 targets in same run
  echo "\n# --- loader-backed residual analysis ---"
  for k in keys:
    let hs = byRun[k]
    if hs[0].runLen < 8:
      continue
    # collect unique targets sorted
    var tgts: seq[int] = @[]
    var loadFrom = initHashSet[int]()
    for h in hs:
      if h.op notin LoadOps:
        continue
      loadFrom.incl h.at
      if h.foTarget notin tgts:
        tgts.add h.foTarget
    if tgts.len < 2:
      continue
    tgts.sort(cmp)
    # deltas
    var deltas: seq[int] = @[]
    for i in 1 ..< tgts.len:
      deltas.add tgts[i] - tgts[i - 1]
    if deltas.len == 0:
      continue
    # most common positive delta
    var counts = initTable[int, int]()
    for d in deltas:
      if d > 0 and d <= 64:
        counts.mgetOrPut(d, 0) += 1
    var bestD = 0
    var bestC = 0
    for d, c in counts:
      if c > bestC:
        bestC = c
        bestD = d
    if bestD > 0 and bestC >= 2:
      var fromBanks: seq[string] = @[]
      var seenB = initHashSet[int]()
      for h in hs:
        if h.srcBank notin seenB:
          seenB.incl h.srcBank
          fromBanks.add &"${0xC0+h.srcBank:02X}"
      let bankList = fromBanks.join(",")
      echo &"  run 0x{k:06X}+{hs[0].runLen}: rec~{bestD} (delta hits={bestC}) loadSites={loadFrom.len} banks={bankList}"
      # claim free run if we have a solid record size and loaders
      if isFree(claimMask, k, hs[0].runLen) and hs[0].runLen >= bestD * 2:
        # only claim multiples of bestD aligned from first target
        let first = tgts[0]
        let last = tgts[^1]
        let lo = max(k, first - (first - k) mod bestD)
        let hi = min(k + hs[0].runLen, last + bestD)
        if hi > lo and isFree(claimMask, lo, hi - lo):
          let n = ((hi - lo) div bestD) * bestD
          if n >= bestD * 2:
            let snes = fileToSnes(lo)
            let bankSlash = fromBanks.join("/")
            echo &"""  BaseromExtractSpan(
    name: "table_absLong_0x{lo:06X}",
    offset: 0x{lo:06X},
    length: {n},
    kind: ekTable,
    note: "loader-backed {bestD}B residual @ ${snes:06X}; AbsoluteLong from {bankSlash}; free only"),"""
            mark(claimMask, lo, n)
            claimTot += n
            claimN += 1

  # Re-walk known pack interiors (same as residual expand)
  echo "\n# --- known APU pack free interiors ---"
  var packRanges: seq[tuple[base, size: int]] = @[]
  for s in allBaseromExtractSpans():
    if s.kind != ekApuPackage:
      continue
    let n = s.note
    let a = n.find("pack@0x")
    if a < 0:
      continue
    let hexStart = a + 7
    var hexEnd = hexStart
    while hexEnd < n.len and n[hexEnd] in {'0'..'9', 'A'..'F', 'a'..'f'}:
      hexEnd += 1
    let b = n.find("size=", hexEnd)
    if b < 0:
      continue
    var numEnd = b + 5
    while numEnd < n.len and n[numEnd] in {'0'..'9'}:
      numEnd += 1
    let base = parseHexInt(n[hexStart ..< hexEnd])
    let size = parseInt(n[b + 5 ..< numEnd])
    var found = false
    for p in packRanges:
      if p.base == base:
        found = true
        break
    if not found:
      packRanges.add (base, size)
  var knownInterior = 0
  for p in packRanges:
    for r in freeRunsIn(claimMask, p.base, p.base + p.size):
      if r.n < 4:
        continue
      echo &"""  BaseromExtractSpan(
    name: "apuPack_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekApuPackage,
    note: "APU pack interior residual (pack@0x{p.base:06X} size={p.size}); container-bounded"),"""
      mark(claimMask, r.o, r.n)
      claimTot += r.n
      claimN += 1
      knownInterior += r.n
  echo &"# known pack interiors claimed: {knownInterior} B"

  echo &"\n# WAVE TOTAL residual claimable: {claimTot} B in {claimN} spans"

main()
