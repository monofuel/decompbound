import std/[strformat, os, sets, strutils, algorithm],
  ../decompbound/[baserom_extract, memmap, rom_chunks]

const
  ObservedPath = "src/decompbound/observed_entries.txt"
  ResolvedPath = "src/decompbound/resolved_entries.txt"

proc loadSeeded(): HashSet[uint32] =
  result = initHashSet[uint32]()
  for path in [ObservedPath, ResolvedPath]:
    if not fileExists(path): continue
    for raw in readFile(path).splitLines():
      let line = raw.strip()
      if line.len == 0 or line.startsWith("#"): continue
      result.incl parseHexInt(line.splitWhitespace()[0]).uint32

# Strong 2-byte epilogue signatures (opcode pairs)
const Sig2 = [
  [0x98u8, 0x6Bu8], # TYA RTL
  [0x98u8, 0x60u8], # TYA RTS
  [0x2Bu8, 0x6Bu8], # PLD RTL
  [0x2Bu8, 0x60u8], # PLD RTS
  [0xABu8, 0x6Bu8], # PLB RTL
  [0xABu8, 0x60u8], # PLB RTS
  [0x28u8, 0x6Bu8], # PLP RTL
  [0x28u8, 0x60u8], # PLP RTS
  [0x68u8, 0x6Bu8], # PLA RTL
  [0x68u8, 0x60u8], # PLA RTS
  [0x7Au8, 0x6Bu8], # PLY RTL
  [0xFAu8, 0x6Bu8], # PLX RTL
  [0x7Au8, 0x60u8],
  [0xFAu8, 0x60u8],
  [0x6Bu8, 0x6Bu8], # RTL RTL
  [0x60u8, 0x60u8], # RTS RTS
  [0x18u8, 0x6Bu8], # CLC RTL
  [0x38u8, 0x6Bu8], # SEC RTL
]

# Strong 3-byte: REP/SEP + RTL/RTS, PHK PLB RTL, etc
# C2 xx 6B, E2 xx 6B, 4B AB 6B

let g = readGoldBaseromBytes()
let seeded = loadSeeded()
var claimed = newSeq[bool](g.len)
var codeOnly = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset ..< min(c.offset + c.length, claimed.len): claimed[i] = true
  if c.kind == ckImplementedCode:
    for i in c.offset ..< min(c.offset + c.length, codeOnly.len): codeOnly[i] = true

proc hx(o, n: int): string =
  for j in 0 ..< n:
    if j > 0: result.add ' '
    result.add &"{g[o+j]:02X}"

var hits: seq[tuple[o, n: int, lab: string]]
var o = 0
while o < g.len:
  if claimed[o]:
    o += 1
    continue
  let s = o
  while o < g.len and not claimed[o]: o += 1
  let n = o - s
  # match sigs as full free cover or prefix
  if n >= 2:
    for sig in Sig2:
      if g[s] == sig[0] and g[s+1] == sig[1]:
        # only if free is exactly 2, OR free is longer but we only seed 2-byte (endsRun)
        if n == 2 or (n > 2 and g[s+1] in [0x60u8, 0x6Bu8]):
          let lab = &"{sig[0]:02X}{sig[1]:02X}"
          hits.add (s, 2, lab)
          break
  if n >= 3:
    # REP/SEP #imm ; RTL/RTS
    if g[s] in [0xC2u8, 0xE2u8] and g[s+2] in [0x60u8, 0x6Bu8]:
      if n == 3:
        hits.add (s, 3, "REP/SEP;RET")
    # PHK PLB RTL
    if g[s] == 0x4B and g[s+1] == 0xAB and g[s+2] in [0x60u8, 0x6Bu8]:
      if n == 3:
        hits.add (s, 3, "PHK;PLB;RET")
  # 1-byte pure RTL/RTS only if BOTH neighbors code (sandwich) — already drained
  if n == 1 and g[s] in [0x60u8, 0x6Bu8]:
    let leftC = s > 0 and codeOnly[s-1]
    let rightC = o < g.len and codeOnly[o]
    if leftC and rightC:
      hits.add (s, 1, "RET sandwich")

# Also scan for free 98 6B even mid-run? no - only free heads

# Dedup and print with context
var seen = initHashSet[int]()
var newB = 0
var newN = 0
for h in hits:
  if h.o in seen: continue
  seen.incl h.o
  let leftC = h.o > 0 and codeOnly[h.o - 1]
  let rightC = h.o + h.n < g.len and codeOnly[h.o + h.n]
  # Require abut code at least one side
  if not leftC and not rightC: continue
  # Extra honesty for non-sandwich: require strong multi-byte only
  if not (leftC and rightC) and h.n < 2: continue
  # Reject if neighbors look like sequential counter data for PLD;RTS in mid-tables
  # Heuristic: if right bytes are sequential u8/u16 counting patterns - skip weak
  let snes = fileToSnes(h.o)
  if snes in seeded: continue
  var L = ""
  for j in max(0, h.o-8) ..< h.o:
    L.add &"{g[j]:02X} "
  var R = ""
  for j in h.o+h.n ..< min(g.len, h.o+h.n+8):
    R.add &"{g[j]:02X} "
  # Strong pattern boost: nearby JSL (22) or REP C2
  var strong = false
  for j in max(0, h.o-6) ..< min(g.len, h.o+h.n+6):
    if g[j] == 0x22 or g[j] == 0xC2: strong = true
  # PLD;RTS with sequential A0 E0 20 neighbors is data
  var dataish = false
  if h.lab in ["2B60", "2B6B"]:
    # count of xx A0 / xx E0 pattern around
    var cnt = 0
    for j in max(0, h.o-10) ..< min(g.len, h.o+h.n+10):
      if g[j] in [0xA0u8, 0xE0u8, 0x20u8]: cnt += 1
    if cnt >= 6: dataish = true
  if dataish:
    echo &"# SKIP dataish {snes:06X} {h.lab} L[{L}] *[{hx(h.o,h.n)}] R[{R}]"
    continue
  let side = if leftC and rightC: "S" elif leftC: "L" else: "R"
  echo &"{snes:06X} 0  # file 0x{h.o:06X}+{h.n} {h.lab} side={side} strong={strong} L[{L}] *[{hx(h.o,h.n)}] R[{R}]"
  newN += 1
  newB += h.n

echo &"# NEW strong epi: {newN} / {newB} B"
