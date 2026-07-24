## Deep APU pack free + C0-C4 residual LDA.L
import std/[strformat, strutils, algorithm, tables, sets],
  ../decompbound/[memmap, rom_chunks, baserom_extract, common]

const PackTableFile = 0x04F947
const PackCount = 170

proc walkApu(g: seq[uint8]; off: int): tuple[ok: bool, size, blocks: int] =
  if off < 0 or off + 4 > g.len: return (false,0,0)
  var pos = off
  var blocks = 0
  while pos + 4 <= g.len:
    let ln = g[pos].int or (g[pos+1].int shl 8)
    let tgt = g[pos+2].int or (g[pos+3].int shl 8)
    if ln == 0:
      return (blocks > 0 or tgt != 0, pos+4-off, blocks)
    if ln > 0xC000 or pos+4+ln > g.len: return (false,0,0)
    blocks += 1
    pos += 4 + ln
  (false,0,0)

proc packFo(g: seq[uint8]; i: int): int =
  let b = PackTableFile + i*3
  let bank = g[b].int
  let a = g[b+1].int or (g[b+2].int shl 8)
  if bank < 0xC0 or bank > 0xEF: return -1
  snesToFile(uint32(a or (bank shl 16)))

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
var isCode = newSeq[bool](g.len)
var isMeta = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset..<min(c.offset+c.length, claimed.len): claimed[i]=true
  if c.kind == ckImplementedCode:
    for i in c.offset..<min(c.offset+c.length, isCode.len): isCode[i]=true
  if c.kind == ckImplementedMeta:
    for i in c.offset..<min(c.offset+c.length, isMeta.len): isMeta[i]=true

var knownBases = initHashSet[int]()
for s in allBaseromExtractSpans():
  if s.kind != ekApuPackage: continue
  let n = s.note
  let a = n.find("pack@0x")
  if a >= 0:
    var he = a+7
    while he < n.len and n[he] in HexDigits: he += 1
    knownBases.incl parseHexInt(n[a+7..<he])
  else:
    knownBases.incl s.offset

echo &"known pack bases: {knownBases.len}"
var freeTot, codeTot, metaTot, unclaimedPacks, fullFreePacks = 0
var fullFree: seq[tuple[i,fo,sz,fr:int]] = @[]
var partial: seq[tuple[i,fo,sz,fr,cd,mt:int]] = @[]
for i in 0..<PackCount:
  let fo = packFo(g, i)
  if fo < 0: continue
  let (ok, size, blocks) = walkApu(g, fo)
  if not ok or size < 8: continue
  var fr, cd, mt = 0
  for j in 0..<size:
    let o = fo+j
    if o >= g.len: break
    if not claimed[o]: fr += 1
    elif isCode[o]: cd += 1
    elif isMeta[o]: mt += 1
  freeTot += fr
  codeTot += cd
  metaTot += mt
  if fo notin knownBases:
    unclaimedPacks += 1
    if fr == size:
      fullFreePacks += 1
      fullFree.add (i, fo, size, fr)
    elif fr >= 4:
      partial.add (i, fo, size, fr, cd, mt)

echo &"all packs free residual sum: {freeTot}  code-in-pack: {codeTot}  meta-in-pack: {metaTot}"
echo &"packs not in knownBases: {unclaimedPacks}; fully free: {fullFreePacks}"
fullFree.sort(proc(a,b: auto): int = cmp(b.sz, a.sz))
partial.sort(proc(a,b: auto): int = cmp(b.fr, a.fr))
echo "top fully free packs:"
for p in fullFree[0 ..< min(15, fullFree.len)]:
  echo &"  [{p.i}] @0x{p.fo:06X} size={p.sz}"
echo "top partial free packs:"
for p in partial[0 ..< min(20, partial.len)]:
  echo &"  [{p.i}] @0x{p.fo:06X} size={p.sz} free={p.fr} code={p.cd} meta={p.mt}"

# Also: for known bases, free left?
var knownFree = 0
for b in knownBases:
  let (ok, size, blocks) = walkApu(g, b)
  if not ok: continue
  for j in 0..<size:
    if b+j < g.len and not claimed[b+j]: knownFree += 1
echo &"free inside knownBases packs: {knownFree}"

# AbsoluteLong from real C0-C4 only into residual - list solid LDA/AND ops
const AbsLong = {0xAF'u8, 0xBF'u8}
echo "\nC0-C4 real LDA.L / LDA.L,X into residual free (all banks):"
var hits = 0
for bank in 0..4:
  let base = bank*0x10000
  var p = base
  while p < base+0x10000-4 and p < g.len:
    if not isCode[p]:
      p += 1; continue
    let op = g[p]
    if op in AbsLong:
      let lo = g[p+1].uint32
      let hi = g[p+2].uint32
      let bk = g[p+3].uint32
      let snes = lo or (hi shl 8) or (bk shl 16)
      let fo2 = snesToFile(snes)
      if fo2 >= 0 and fo2 < g.len and not claimed[fo2]:
        hits += 1
        if hits <= 40:
          let on = if op == 0xAF: "LDA.L" else: "LDA.L,X"
          echo &"  {on} ${snes:06X} from ${0xC0+bank:02X}@0x{p:06X}"
    p += 1
echo &"total C0-C4 LDA.L residual hits: {hits}"
