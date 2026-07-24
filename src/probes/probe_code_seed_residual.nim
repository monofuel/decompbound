## Scout free residual runs with clean 65816 prologues for convert_all seeds.
## High-confidence: REP #$31 / REP #$30 / RTL stubs between code_spans.
## Usage: nim r src/probes/probe_code_seed_residual.nim

import
  std/[algorithm, os, sets, strformat, strutils, tables],
  ../decompbound/[memmap, rom_chunks, baserom_extract]

const
  ObservedPath = "src/decompbound/observed_entries.txt"
  ResolvedPath = "src/decompbound/resolved_entries.txt"

proc loadSeeded(): HashSet[uint32] =
  ## Load already-seeded SNES addresses from observed + resolved entry files.
  result = initHashSet[uint32]()
  for path in [ObservedPath, ResolvedPath]:
    if not fileExists(path): continue
    for raw in readFile(path).splitLines():
      let line = raw.strip()
      if line.len == 0 or line.startsWith("#"): continue
      let parts = line.splitWhitespace()
      result.incl parseHexInt(parts[0]).uint32

proc isCodeSpanNeighbor(claimed: seq[bool]; codeOnly: seq[bool]; o: int): bool =
  ## True when the free run abuts implemented code on either side.
  if o > 0 and codeOnly[o - 1]: return true
  false

proc cleanPrologueKind(g: seq[uint8]; o, n: int): string =
  ## Classify free-run head as a clean code prologue, or empty if not.
  if n < 1: return ""
  let b0 = g[o]
  if n >= 2 and b0 == 0xC2:
    let m = g[o + 1]
    if m == 0x31: return "REP31"
    if m == 0x30: return "REP30"
    if m == 0x20: return "REP20"
    if m == 0x10: return "REP10"
    if (m and 0x30) != 0: return "REPmx"
  if n >= 2 and b0 == 0xE2:
    let m = g[o + 1]
    if m == 0x20: return "SEP20"
    if m == 0x10: return "SEP10"
    if m == 0x30: return "SEP30"
    if (m and 0x30) != 0: return "SEPmx"
  if b0 == 0x08 and n >= 3 and g[o + 1] == 0xC2:
    return "PHPREP"
  if b0 == 0x08 and n >= 1:
    return "PHP"
  if b0 == 0x6B:
    return "RTL"
  if b0 == 0x60:
    return "RTS"
  if b0 == 0x4B and n >= 2:
    return "PHK"
  if b0 == 0xA2 and n >= 2:
    return "LDXimm"
  if b0 == 0xA0 and n >= 2:
    return "LDYimm"
  if b0 == 0xA9 and n >= 2:
    return "LDAimm"
  if b0 == 0x22 and n >= 4:
    return "JSL"
  if b0 == 0x20 and n >= 3:
    return "JSR"
  if b0 == 0xAD and n >= 3:
    return "LDAabs"
  if b0 == 0xAF and n >= 4:
    return "LDAlong"
  if b0 == 0x48:
    return "PHA"
  if b0 == 0xDA:
    return "PHX"
  if b0 == 0x5A:
    return "PHY"
  if b0 == 0x18:
    return "CLC"
  if b0 == 0x38:
    return "SEC"
  if b0 == 0xFB:
    return "XCE"
  result = ""

proc highConfidence(kind: string): bool =
  ## Prefer seeds that are almost never data false-positives.
  kind in ["REP31", "REP30", "REP20", "REP10", "REPmx", "SEP20", "SEP10",
           "SEP30", "SEPmx", "PHPREP", "RTL", "RTS", "PHK", "XCE"]

proc main() =
  ## Enumerate free residual code-like heads and print seed candidates.
  let g = readGoldBaseromBytes()
  let seeded = loadSeeded()

  var claimed = newSeq[bool](g.len)
  var codeOnly = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      for i in c.offset ..< min(c.offset + c.length, claimed.len):
        claimed[i] = true
      if c.kind == ckImplementedCode:
        for i in c.offset ..< min(c.offset + c.length, codeOnly.len):
          codeOnly[i] = true

  type Cand = object
    o, n: int
    kind: string
    sandwich: bool
    head: string
    tail: string

  var cands: seq[Cand]
  var freeTotal = 0
  var sandwichBytes = 0
  var o = 0
  while o < g.len:
    if claimed[o]:
      o += 1
      continue
    let start = o
    while o < g.len and not claimed[o]:
      o += 1
    let n = o - start
    freeTotal += n
    let leftCode = start > 0 and codeOnly[start - 1]
    let rightCode = o < g.len and codeOnly[o]
    let sandwich = leftCode and rightCode
    if sandwich:
      sandwichBytes += n
    let kind = cleanPrologueKind(g, start, n)
    if kind.len == 0:
      continue
    # Skip ultra-tiny ambiguous single-byte PHP/PHA unless sandwich+RTL family.
    if n == 1 and kind notin ["RTL", "RTS"]:
      continue
    var head = ""
    for j in 0 ..< min(8, n):
      head.add &"{g[start + j]:02X}"
      if j + 1 < min(8, n): head.add " "
    var tail = ""
    if n >= 2:
      for j in max(0, n - 3) ..< n:
        if tail.len > 0: tail.add " "
        tail.add &"{g[start + j]:02X}"
    cands.add Cand(o: start, n: n, kind: kind, sandwich: sandwich,
                   head: head, tail: tail)

  cands.sort(proc(a, b: Cand): int =
    # High-confidence first, then sandwich, then larger runs.
    let ah = highConfidence(a.kind)
    let bh = highConfidence(b.kind)
    if ah != bh: return cmp(bh, ah)
    if a.sandwich != b.sandwich: return cmp(b.sandwich, a.sandwich)
    result = cmp(b.n, a.n)
    if result == 0: result = cmp(a.o, b.o))

  var byKind: CountTable[string]
  var hiBytes, midBytes, already = 0
  var hiCount, midCount = 0
  var seeds: seq[uint32]

  echo &"# free residual total: {freeTotal} B"
  echo &"# code|code sandwich free: {sandwichBytes} B"
  echo &"# prologue-shaped free runs: {cands.len}"
  echo ""
  echo "# === HIGH confidence seeds (not already seeded) ==="
  for c in cands:
    byKind.inc c.kind
    let snes = fileToSnes(c.o)
    let isHi = highConfidence(c.kind)
    if snes in seeded:
      already += 1
      continue
    if isHi:
      hiBytes += c.n
      hiCount += 1
      seeds.add snes
      let sw = if c.sandwich: "code|code" else: "other"
      echo &"{snes:06X} 0  # file 0x{c.o:06X}+{c.n} {c.kind} {sw} head={c.head} tail={c.tail}"
    else:
      midBytes += c.n
      midCount += 1

  echo ""
  echo "# === MEDIUM confidence summary (not seeded as default) ==="
  echo &"# medium candidates: {midCount} runs / {midBytes} B (LDAimm/JSL/etc)"
  # Print top medium sandwich-only for optional review
  var medPrinted = 0
  for c in cands:
    if highConfidence(c.kind): continue
    if not c.sandwich: continue
    let snes = fileToSnes(c.o)
    if snes in seeded: continue
    if medPrinted >= 40: break
    echo &"# MED {snes:06X} 0  # file 0x{c.o:06X}+{c.n} {c.kind} head={c.head}"
    medPrinted += 1

  echo ""
  echo "# === kind histogram (all free prologue-shaped) ==="
  var kinds: seq[string]
  for k, _ in byKind: kinds.add k
  kinds.sort()
  for k in kinds:
    echo &"#   {k}: {byKind[k]}"

  echo ""
  echo &"# already seeded among candidates: {already}"
  echo &"# NEW high-confidence seeds: {hiCount} runs / {hiBytes} B potential free"
  echo &"# seed lines ready: {seeds.len}"

when isMainModule:
  main()
