## Sandwich free pure code stubs for convert_all seeds (wave105).
import
  std/[algorithm, os, sets, strformat, strutils],
  ../decompbound/[baserom_extract, disasm, memmap, opcodes, rom_chunks]

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

proc main() =
  let g = readGoldBaseromBytes()
  let seeded = loadSeeded()
  var codeOnly = newSeq[bool](g.len)
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      for i in c.offset ..< min(c.offset + c.length, claimed.len):
        claimed[i] = true
      if c.kind == ckImplementedCode:
        for i in c.offset ..< min(c.offset + c.length, codeOnly.len):
          codeOnly[i] = true

  var seeds: seq[tuple[snes: uint32, o, n: int, kind: string]]
  var o = 0
  while o < g.len:
    if claimed[o]:
      o += 1; continue
    let start = o
    while o < g.len and not claimed[o]: o += 1
    let n = o - start
    let sandwich = start > 0 and codeOnly[start - 1] and o < g.len and codeOnly[o]
    if not sandwich: continue
    # 1-byte pure RTS/RTL
    if n == 1 and g[start] in [0x60u8, 0x6Bu8]:
      let snes = fileToSnes(start)
      if snes notin seeded:
        seeds.add (snes, start, n, if g[start]==0x60: "RTS" else: "RTL")
      continue
    # 2-byte: RTL RTL, RTS RTS, REP;RTL, PHP;RTL, etc full epilogue
    if n == 2:
      let b0 = g[start]; let b1 = g[start+1]
      # both return
      if b0 in [0x60u8, 0x6Bu8] and b1 in [0x60u8, 0x6Bu8]:
        let snes = fileToSnes(start)
        if snes notin seeded:
          seeds.add (snes, start, n, "RETRET")
        continue
      # REP/SEP + RTL/RTS
      if b0 in [0xC2u8, 0xE2u8] and b1 in [0x60u8, 0x6Bu8]:
        # invalid - REP needs operand
        discard
      if b0 == 0xC2 and (b1 and 0x30) != 0:
        # 2-byte is just REP #imm — not full endsRun alone
        discard
      # PLD/RTL, PLB/RTL, etc
      if b0 in [0x2Bu8, 0xABu8, 0x68u8, 0x28u8, 0x7Au8, 0xFAu8] and b1 in [0x60u8, 0x6Bu8]:
        let snes = fileToSnes(start)
        if snes notin seeded:
          seeds.add (snes, start, n, "PL;RET")
        continue

  seeds.sort(proc(a,b: auto): int = cmp(a.o, b.o))
  var bytes = 0
  for s in seeds:
    bytes += s.n
    echo &"{s.snes:06X} 0  # file 0x{s.o:06X}+{s.n} {s.kind} sandwich"
  echo &"# seeds: {seeds.len} covering {bytes} B free"

main()
