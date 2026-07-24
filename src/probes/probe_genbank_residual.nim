## Scan AbsoluteLong operands from ALL generated code_bank*.nim files whose
## SNES targets land in residual free runs. Also probe CC short-rec / HDMA-like
## residual islands, zero-pad runs, and pack-table APU free residual.

import
  std/[algorithm, os, sequtils, strformat, strutils, tables, sets],
  ../decompbound/[memmap, rom_chunks, baserom_extract, common]

const
  PackTableFile = 0x04F947
  PackCount = 170
  MaxPackSize = 0x2800

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

proc parseHex(s: string): int =
  var v = 0
  for c in s:
    let d =
      if c in {'0'..'9'}: ord(c) - ord('0')
      elif c in {'a'..'f'}: ord(c) - ord('a') + 10
      elif c in {'A'..'F'}: ord(c) - ord('A') + 10
      else: -1
    if d < 0: continue
    v = (v shl 4) or d
  result = v

proc walkApu(g: seq[uint8]; off: int): tuple[ok: bool, size, blocks: int] =
  if off < 0 or off + 4 > g.len:
    return (false, 0, 0)
  var pos = off
  var blocks = 0
  while pos + 4 <= g.len:
    let ln = g[pos].int or (g[pos + 1].int shl 8)
    let tgt = g[pos + 2].int or (g[pos + 3].int shl 8)
    if ln == 0:
      let size = pos + 4 - off
      if size > MaxPackSize:
        return (false, 0, 0)
      if blocks == 0 and tgt == 0:
        return (false, 0, 0)
      return (true, size, blocks)
    if ln > 0xC000 or pos + 4 + ln > g.len:
      return (false, 0, 0)
    if pos + 4 + ln - off > MaxPackSize:
      return (false, 0, 0)
    blocks += 1
    pos += 4 + ln
  (false, 0, 0)

proc packFo(g: seq[uint8]; i: int): int =
  let b = PackTableFile + i * 3
  let bank = g[b].int
  let a = g[b + 1].int or (g[b + 2].int shl 8)
  if bank < 0xC0 or bank > 0xEF:
    return -1
  snesToFile(uint32(a or (bank shl 16)))

proc main() =
  ## Generated-bank AbsoluteLong residual + pack/zero/CC claims.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var runs = freeRuns(claimed)
  runs.sort(proc(a, b: auto): int = cmp(b.n, a.n))

  proc findRun(fo: int): tuple[o, n: int] =
    for r in runs:
      if fo >= r.o and fo < r.o + r.n:
        return r
    (-1, 0)

  type Hit = object
    bankFile: string
    lineNo: int
    mnem: string
    snes: uint32
    fo: int
    runO, runN: int
    line: string

  var hits: seq[Hit] = @[]
  let loadMnems = ["LDA", "ADC", "AND", "ORA", "EOR", "CMP", "SBC", "LDX", "LDY"]
  let storeMnems = ["STA", "STX", "STY"]

  for bi in 0..0x2F:
    let path = &"src/decompbound/generated/code_bank{bi:02X}.nim"
    if not fileExists(path):
      continue
    let text = readFile(path)
    var ln = 0
    for line in text.splitLines():
      ln += 1
      # Prefer AbsoluteLong addressing mode tokens from sourcegen
      if "AbsoluteLong" notin line and ".L" notin line.toUpperAscii:
        continue
      let upper = line.toUpperAscii
      var mnem = ""
      for m in loadMnems:
        if m in upper:
          mnem = m
          break
      if mnem.len == 0:
        for m in storeMnems:
          if m in upper:
            mnem = m
            break
      if mnem.len == 0:
        continue
      # extract 6-digit hex after $ or 0x
      var j = 0
      while j < line.len:
        var snes: uint32 = 0
        var found = false
        if line[j] == '$' and j + 7 <= line.len:
          let digs = line[j+1 ..< j+7]
          var ok = true
          for c in digs:
            if c notin HexDigits: ok = false
          if ok:
            snes = parseHex(digs).uint32
            found = true
            j += 7
          else:
            j += 1
            continue
        elif j + 8 <= line.len and line[j] == '0' and line[j+1] in {'x', 'X'}:
          var k = j + 2
          while k < line.len and line[k] in HexDigits: k += 1
          if k - (j + 2) == 6:
            snes = parseHex(line[j+2 ..< k]).uint32
            found = true
            j = k
          else:
            j += 1
            continue
        else:
          j += 1
          continue
        if not found: continue
        let bank = int((snes shr 16) and 0xFF)
        if bank < 0xC0 or bank > 0xEF: continue
        let fo = snesToFile(snes)
        if fo < 0 or fo >= g.len: continue
        if claimed[fo]: continue
        let (ro, rn) = findRun(fo)
        if ro < 0: continue
        hits.add Hit(bankFile: path.extractFilename, lineNo: ln, mnem: mnem,
          snes: snes, fo: fo, runO: ro, runN: rn, line: line.strip)

  echo &"Generated-bank AbsoluteLong → residual free: {hits.len} hits"
  var byRun = initTable[int, seq[Hit]]()
  for h in hits:
    if h.runO notin byRun: byRun[h.runO] = @[]
    byRun[h.runO].add h
  var keys: seq[int] = @[]
  for k in byRun.keys: keys.add k
  keys.sort(proc(a, b: int): int =
    result = cmp(byRun[b].len, byRun[a].len)
    if result == 0: result = cmp(a, b))

  echo "\nTop residual runs referenced by generated AbsoluteLong:"
  for idx in 0 ..< min(30, keys.len):
    let k = keys[idx]
    let hs = byRun[k]
    var loads = 0
    var banks = initHashSet[string]()
    var tgts = initHashSet[uint32]()
    for h in hs:
      if h.mnem in loadMnems: loads += 1
      banks.incl h.bankFile
      tgts.incl h.snes
    var hex = ""
    for b in 0 ..< min(16, hs[0].runN):
      hex.add &"{g[k + b]:02X} "
    echo &"  0x{k:06X}+{hs[0].runN} hits={hs.len} loads={loads} uniqT={tgts.len} banks={banks.len} head={hex}"
    var shown = 0
    var seen = initHashSet[uint32]()
    for h in hs:
      if h.snes in seen: continue
      seen.incl h.snes
      if shown >= 5: break
      echo &"    {h.mnem} ${h.snes:06X} @ {h.bankFile}:{h.lineNo}"
      shown += 1

  # ---- Emit claims ----
  echo "\n# === CLAIM CANDIDATES ==="
  var claimMask = claimed
  var claimTot = 0
  var claimN = 0

  # 1) C0B0A6 4-byte bit mask table (real LDA.L,X from $C0B04F region)
  if isFree(claimMask, 0x00B0A6, 4):
    echo """  BaseromExtractSpan(
    name: "table_c0BitMask_0x00B0A6",
    offset: 0x00B0A6,
    length: 4,
    kind: ekTable,
    note: "4B bit-nibble masks 00 0F F0 FF; loaders $C0B04F/$C0B065/$C0B07A LDA.L,X $C0B0A6; free only"),"""
    mark(claimMask, 0x00B0A6, 4)
    claimTot += 4
    claimN += 1

  # 2) Pack-table APU residual free (valid size only)
  var knownBases = initHashSet[int]()
  for s in allBaseromExtractSpans():
    if s.kind != ekApuPackage: continue
    let n = s.note
    let a = n.find("pack@0x")
    if a < 0: continue
    var he = a + 7
    while he < n.len and n[he] in HexDigits: he += 1
    knownBases.incl parseHex(n[a+7 ..< he])

  var packFree = 0
  for i in 0 ..< PackCount:
    let fo = packFo(g, i)
    if fo < 0: continue
    let (ok, size, blocks) = walkApu(g, fo)
    if not ok or size < 8 or blocks < 1: continue
    for r in freeRunsIn(claimMask, fo, fo + size):
      if r.n < 4: continue
      let tag = if fo in knownBases: "interior" else: "pack-table discovery"
      echo &"""  BaseromExtractSpan(
    name: "apuPack_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekApuPackage,
    note: "APU pack {i} residual (pack@0x{fo:06X} size={size}); {tag}; free only"),"""
      mark(claimMask, r.o, r.n)
      claimTot += r.n
      claimN += 1
      packFree += r.n
  echo &"# pack free claimed: {packFree} B"

  # 3) Zero-pad residual runs (≥8 contiguous 0x00 free)
  var zeroTot = 0
  for r in freeRuns(claimMask):
    if r.n < 8: continue
    var allZ = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0:
        allZ = false
        break
    if not allZ: continue
    echo &"""  BaseromExtractSpan(
    name: "zeroPad_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {r.n},
    kind: ekZeroPad,
    note: "ROM zero-fill padding residual; gold is all 0x00"),"""
    mark(claimMask, r.o, r.n)
    claimTot += r.n
    claimN += 1
    zeroTot += r.n
  echo &"# zero-pad residual: {zeroTot} B"

  # 4) CC short-rec pattern: 4B records ending with FF (e.g. 0x0C7371)
  # Pattern at 0C7371: 0B 7D F3 FF | 0F 7D F3 FF | 13 7D F3 FF | 17 7D F1 02 ...
  # Also try u16,u16 with high bytes often FF/F8 style HDMA
  proc claimCcRec4(lo, hi: int; namePrefix, note: string) =
    var o = lo
    while o + 4 <= hi:
      if not isFree(claimMask, o, 4):
        o += 1
        continue
      # require consecutive free 4B-aligned records with byte3 often FF or pattern
      var n = 0
      var p = o
      while p + 4 <= hi and isFree(claimMask, p, 4):
        # soft: not all zeros (zeros claimed separately)
        if g[p] == 0 and g[p+1] == 0 and g[p+2] == 0 and g[p+3] == 0:
          break
        n += 4
        p += 4
        if n >= 64: break # claim in chunks later
      if n >= 16:
        # verify FF density in byte3
        var ff = 0
        var recs = n div 4
        for i in 0 ..< recs:
          if g[o + i*4 + 3] == 0xFF: ff += 1
        if ff * 2 >= recs: # ≥50% FF terminators/high
          echo &"""  BaseromExtractSpan(
    name: "{namePrefix}_0x{o:06X}",
    offset: 0x{o:06X},
    length: {n},
    kind: ekTable,
    note: "{note}"),"""
          mark(claimMask, o, n)
          claimTot += n
          claimN += 1
          o = p
          continue
      o += 1

  # top CC residual islands
  for (lo, hi) in [(0x0C7371, 0x0C7371+401), (0x0C6DCF, 0x0C6DCF+368),
                   (0x0C6ADA, 0x0C6ADA+355)]:
    claimCcRec4(lo, hi, "table_ccRec4",
      "CC residual 4B-rec (high-byte FF density); AbsoluteLong/HDMA-like; free only")

  # 5) For generated AbsoluteLong load hits: claim residual free runs that have
  # ≥3 load hits from ≥2 banks OR ≥5 loads from one bank, with solid format.
  # Prefer whole-run claim only when run is small (≤128) and heavily targeted.
  var genTot = 0
  for k in keys:
    let hs = byRun[k]
    var loads = 0
    var loadBanks = initHashSet[string]()
    var loadTgts: seq[int] = @[]
    for h in hs:
      if h.mnem notin loadMnems: continue
      loads += 1
      loadBanks.incl h.bankFile
      if h.fo notin loadTgts:
        loadTgts.add h.fo
    if loads < 3: continue
    let rn = hs[0].runN
    if rn > 256: continue # too large without record walk
    if not isFree(claimMask, k, rn): continue
    # infer stride from sorted unique targets
    loadTgts.sort(cmp)
    var stride = 0
    if loadTgts.len >= 3:
      var deltas = initTable[int, int]()
      for i in 1 ..< loadTgts.len:
        let d = loadTgts[i] - loadTgts[i-1]
        if d > 0 and d <= 32:
          deltas.mgetOrPut(d, 0) += 1
      var bestC = 0
      for d, c in deltas:
        if c > bestC:
          bestC = c
          stride = d
    let bankList = toSeq(loadBanks).join("/")
    let note =
      if stride > 0:
        &"generated AbsoluteLong residual ~{stride}B; loads={loads} from {bankList}; free only"
      else:
        &"generated AbsoluteLong residual; loads={loads} from {bankList}; free only"
    # claim if multi-bank or high load density
    let okClaim = loadBanks.len >= 2 or loads >= 5 or (stride >= 2 and loads >= 3)
    if okClaim:
      echo &"""  BaseromExtractSpan(
    name: "table_genAbsL_0x{k:06X}",
    offset: 0x{k:06X},
    length: {rn},
    kind: ekTable,
    note: "{note}"),"""
      mark(claimMask, k, rn)
      claimTot += rn
      claimN += 1
      genTot += rn
  echo &"# gen AbsoluteLong residual runs: {genTot} B"

  # 6) Scan residual islands for APU package at start (valid size)
  var islandTot = 0
  for r in freeRuns(claimMask):
    if r.n < 64: continue
    let (ok, size, blocks) = walkApu(g, r.o)
    if not ok or size < 12 or blocks < 1: continue
    # claim free prefix of package
    let claimLen = min(r.n, size)
    # require package mostly inside free run
    if claimLen < size div 2: continue
    if not isFree(claimMask, r.o, claimLen): continue
    echo &"""  BaseromExtractSpan(
    name: "apuPack_0x{r.o:06X}",
    offset: 0x{r.o:06X},
    length: {claimLen},
    kind: ekApuPackage,
    note: "APU package residual walk size={size} blocks={blocks}; island discovery; free only"),"""
    mark(claimMask, r.o, claimLen)
    claimTot += claimLen
    claimN += 1
    islandTot += claimLen
  echo &"# island APU: {islandTot} B"

  echo &"\n# WAVE TOTAL residual claimable: {claimTot} B in {claimN} spans"

main()
