## Hand-disasm real code sandwich free for convert_all seeds.
## Honesty matches probe_sandwich_continue + valid branch/JML targets.
import
  std/[algorithm, os, sets, strformat, strutils],
  ../decompbound/[assembler, baserom_extract, memmap, opcodes, rom_chunks]

const
  ObservedPath = "src/decompbound/observed_entries.txt"
  ResolvedPath = "src/decompbound/resolved_entries.txt"
  EndRun = ["RTL", "RTS", "JMP", "JML", "BRA", "BRL"]
  EpilogueOnly = ["RTL", "RTS", "PLD", "PLB", "PLY", "PLX", "PLA", "PLP",
                  "PHX", "PHY", "PHA", "PHP", "PHD", "PHB", "PHK", "REP",
                  "SEP", "NOP", "TCD", "TDC", "CLC", "SEC", "XCE", "XBA",
                  "TXY", "TYX", "TAX", "TAY", "TXA", "TYA", "TSX", "TXS",
                  "INA", "DEA", "INX", "DEX", "INY", "DEY"]

proc loadSeeded(): HashSet[uint32] =
  ## Load SNES addrs already in observed/resolved entry files.
  result = initHashSet[uint32]()
  for path in [ObservedPath, ResolvedPath]:
    if not fileExists(path): continue
    for raw in readFile(path).splitLines():
      let line = raw.strip()
      if line.len == 0 or line.startsWith("#"): continue
      result.incl parseHexInt(line.splitWhitespace()[0]).uint32

proc flagNibble(f: FlagState): int =
  ## Encode m8/x8/emulation as convert_all seed nibble.
  (if f.m8: 1 else: 0) or (if f.x8: 2 else: 0) or (if f.emulation: 4 else: 0)

proc dens80(g: seq[uint8]; off, n: int): float =
  ## Fraction of 0x80 bytes in a window.
  if n <= 0: return 0
  var c = 0
  for i in 0..<n:
    if g[off + i] == 0x80: inc c
  c.float / n.float

proc recoverExitFlags(g: seq[uint8]; start, endOff: int): (bool, FlagState, string) =
  ## Decode left code span; return flags + last mnemonic at endOff.
  for entryFlags in [
    FlagState(m8: false, x8: false, emulation: false),
    FlagState(m8: true, x8: true, emulation: false),
    FlagState(m8: true, x8: false, emulation: false),
    FlagState(m8: false, x8: true, emulation: false),
  ]:
    var flags = entryFlags
    var off = start
    var ok = true
    var lastM = ""
    while off < endOff:
      let opSize = operandSize(OpcodeTable[g[off]].mode, flags)
      if off + 1 + opSize > endOff:
        ok = false
        break
      let instr = decode(g, off, flags)
      lastM = OpcodeTable[instr.opcode].mnemonic
      flags.applyInstruction(instr.opcode, instr.operand)
      off += instr.size
    if ok and off == endOff:
      return (true, flags, lastM)
  (false, FlagState(), "")

proc summaryOf(instrs: seq[Instruction]): string =
  ## Short mnemonic chain for seed comments.
  var parts: seq[string]
  for i, instr in instrs:
    if i >= 12: break
    parts.add OpcodeTable[instr.opcode].mnemonic
  parts.join(";")

proc isEpilogueInstrs(instrs: seq[Instruction]): bool =
  ## Every mnemonic is stack/flag/return family.
  if instrs.len == 0: return false
  for instr in instrs:
    if OpcodeTable[instr.opcode].mnemonic notin EpilogueOnly:
      return false
  true

proc hexBytes(g: seq[uint8]; o, n: int): string =
  ## Hex dump helper.
  var parts: seq[string]
  for i in 0 ..< min(n, 16):
    parts.add &"{g[o + i]:02X}"
  parts.join(" ")

proc validRomFile(ft: int; gLen: int): bool =
  ## True when file offset lands in the 3MB EB image.
  ft >= 0 and ft < gLen

proc main() =
  ## Enumerate honest sandwich free code seeds.
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

  type Cand = object
    o, n, cover, score: int
    snes: uint32
    flags: FlagState
    summary, kind, leftLast: string
    bytes: string

  var cands: seq[Cand]
  var freeB, sandwichB, sandwichN = 0
  var o = 0
  while o < g.len:
    if claimed[o]:
      o += 1; continue
    let start = o
    while o < g.len and not claimed[o]: o += 1
    let n = o - start
    freeB += n
    let sandwich = start > 0 and codeOnly[start - 1] and o < g.len and codeOnly[o]
    if sandwich:
      sandwichB += n
      sandwichN += 1
    if not sandwich: continue
    if n > 48: continue

    var ls = start - 1
    while ls > 0 and codeOnly[ls - 1]: dec ls
    if start - ls > 512: ls = start - 512
    let (rec, exitFlags, leftLast) = recoverExitFlags(g, ls, start)
    if not rec: continue

    if dens80(g, start, n) > 0.45: continue
    if dens80(g, max(ls, start - 16), min(16, start - ls)) > 0.35: continue
    if start > 0 and g[start - 1] == 0x80 and g[start] == 0x80: continue

    let (instrs, covered) = decodeRange(g, start, n, exitFlags)
    if instrs.len == 0 or covered != n: continue
    let first = OpcodeTable[instrs[0].opcode].mnemonic
    let last = OpcodeTable[instrs[^1].opcode].mnemonic
    if last notin EndRun: continue
    if n == 1 and first notin ["RTS", "RTL"]: continue

    var braCount = 0
    for instr in instrs:
      if OpcodeTable[instr.opcode].mnemonic == "BRA":
        inc braCount
        if instr.operand == 0: braCount = 99
    if braCount > 1: continue

    var honest = isEpilogueInstrs(instrs)
    if not honest:
      if first notin ["BRA", "BRL", "JMP", "JML", "RTL", "RTS"]:
        continue
      honest = instrs.len == 1 or isEpilogueInstrs(instrs[1..^1])
    if not honest: continue

    # Validate control-flow targets land in ROM (and preferably code/free).
    var tgtOk = true
    var off = start
    var flags = exitFlags
    for instr in instrs:
      let m = OpcodeTable[instr.opcode].mnemonic
      let tgt = branchTargetSnes(instr, fileToSnes(off))
      if tgt >= 0:
        let ft = snesToFile(tgt.uint32)
        if not validRomFile(ft, g.len):
          tgtOk = false
        elif m in ["JMP", "JML", "BRL"]:
          # absolute jumps must land on code or inside this free
          if not (codeOnly[ft] or (ft >= start and ft < start + n)):
            # allow free small epilogue targets
            if claimed[ft]:
              tgtOk = false
      elif m in ["JMP", "JML"]:
        # unparseable absolute target
        tgtOk = false
      flags.applyInstruction(instr.opcode, instr.operand)
      off += instr.size
    if not tgtOk: continue

    if n >= 3:
      var same = true
      for i in 1..<n:
        if g[start + i] != g[start]: same = false
      if same: continue

    var score = 100 + n * 5
    if first in ["BRA", "PLD", "RTL", "RTS", "REP", "SEP", "PHP"]: score += 15
    if leftLast notin EndRun: score += 30
    if last in ["RTL", "RTS"] and isEpilogueInstrs(instrs): score += 20

    cands.add Cand(
      o: start, n: n, cover: covered, score: score, snes: fileToSnes(start),
      flags: exitFlags, summary: summaryOf(instrs),
      kind: if leftLast in EndRun: "afterEnds" else: "fallThru",
      leftLast: leftLast, bytes: hexBytes(g, start, n))

  cands.sort(proc(a, b: Cand): int =
    result = cmp(b.score, a.score)
    if result == 0: result = cmp(a.o, b.o))

  echo &"# free residual total: {freeB} B"
  echo &"# code|code sandwich free: {sandwichB} B / {sandwichN} runs"
  echo &"# honest seeds found: {cands.len}"
  var newN, newB, already = 0
  for c in cands:
    if c.snes in seeded:
      already += 1
      continue
    echo &"{c.snes:06X} {flagNibble(c.flags)}  # file 0x{c.o:06X}+{c.n} " &
         &"{c.kind} left={c.leftLast} score={c.score} {c.summary}  [{c.bytes}]"
    newN += 1
    newB += c.cover
  echo &"# already seeded: {already}"
  echo &"# NEW seeds: {newN} covering {newB} B"

when isMainModule:
  main()
