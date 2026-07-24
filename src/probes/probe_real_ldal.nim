
import std/[strformat, tables, algorithm, sets],
  ../decompbound/[memmap, rom_chunks, baserom_extract]

const AbsLoad = {0xAF'u8, 0xBF'u8} # LDA.L / LDA.L,X

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
var isCode = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset..<min(c.offset+c.length, claimed.len): claimed[i]=true
  if c.kind == ckImplementedCode:
    for i in c.offset..<min(c.offset+c.length, isCode.len): isCode[i]=true

type Hit = object
  op: uint8
  at, fo: int
  snes: uint32
  srcBank: int

var hits: seq[Hit] = @[]
# scan banks 0..0x0F only (C0-CF) - more real code
for bank in 0..0x0F:
  let base = bank * 0x10000
  var p = base
  while p < base + 0x10000 - 4 and p < g.len:
    if not isCode[p]:
      p += 1; continue
    let op = g[p]
    if op in AbsLoad:
      let snes = g[p+1].uint32 or (g[p+2].uint32 shl 8) or (g[p+3].uint32 shl 16)
      let bk = int(snes shr 16)
      if bk >= 0xC0 and bk <= 0xEF:
        let fo = snesToFile(snes)
        if fo >= 0 and fo < g.len and not claimed[fo]:
          hits.add Hit(op: op, at: p, fo: fo, snes: snes, srcBank: bank)
    p += 1

echo &"C0-CF LDA.L/LDA.L,X → residual: {hits.len}"
# group by target rounded to 256-byte page
var byPage = initTable[int, seq[Hit]]()
for h in hits:
  let pg = h.fo and not 0xFF
  if pg notin byPage: byPage[pg] = @[]
  byPage[pg].add h

var keys: seq[int] = @[]
for k in byPage.keys: keys.add k
keys.sort(proc(a,b:int): int = cmp(byPage[b].len, byPage[a].len))

for i in 0 ..< min(25, keys.len):
  let k = keys[i]
  let hs = byPage[k]
  var tgts = initHashSet[int]()
  var banks = initHashSet[int]()
  for h in hs:
    tgts.incl h.fo
    banks.incl h.srcBank
  # free run size around first target
  var fo0 = hs[0].fo
  var lo = fo0
  while lo > 0 and not claimed[lo-1]: lo -= 1
  var hi = fo0
  while hi+1 < claimed.len and not claimed[hi+1]: hi += 1
  let runN = hi - lo + 1
  var hex = ""
  for b in 0 ..< min(12, runN):
    hex.add &"{g[lo+b]:02X} "
  echo &"  page 0x{k:06X} hits={hs.len} uniqT={tgts.len} srcBanks={banks.len} run=0x{lo:06X}+{runN} head={hex}"
  var shown = 0
  var seen = initHashSet[uint32]()
  for h in hs:
    if h.snes in seen: continue
    seen.incl h.snes
    if shown >= 4: break
    let on = if h.op == 0xAF: "LDA.L" else: "LDA.L,X"
    echo &"    {on} ${h.snes:06X} from ${0xC0+h.srcBank:02X}@0x{h.at:06X}"
    shown += 1
