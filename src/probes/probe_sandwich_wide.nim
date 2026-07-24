## Solid seeds to absorb code|code sandwich free into code_spans.
##
## Curated gates (2026-07-24 seed wave — prefer real disasm over extract pad):
## - Sandwich free only (code|code neighbors)
## - FULL free cover, last instr endsRun (no fall-through into meta)
## - Left code recovers aligned exit flags
## - Free / left not 0x80-dense (rejects bank $D8 plane false code)
## - Reject BRA #$00 (bitmap no-op); reject multi-BRA free runs
## - 1-byte: RTS/RTL only
## - Branch targets land in CODE or small free epilogue (≤4 B PLD/RTL/…)
##
## Usage:
##   nim r src/probes/probe_sandwich_continue.nim
##   nim r src/probes/probe_sandwich_continue.nim --apply

import
  std/[algorithm, os, sets, strformat, strutils, tables],
  ../decompbound/[assembler, baserom_extract, disasm, memmap, opcodes, rom_chunks]

const
  ObservedPath = "src/decompbound/observed_entries.txt"
  ResolvedPath = "src/decompbound/resolved_entries.txt"
  EndRun = ["RTL", "RTS", "JMP", "JML", "BRA", "BRL"]
  EpilogueOnly = ["RTL", "RTS", "PLD", "PLB", "PLY", "PLX", "PLA", "PLP",
                  "PHX", "PHY", "PHA", "PHP", "PHD", "PHB", "PHK", "REP",
                  "SEP", "NOP", "TCD", "TDC", "CLC", "SEC"]

proc loadSeeded(): HashSet[uint32] =
  ## Load already-seeded SNES addresses from observed + resolved entry files.
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

proc summaryOf(instrs: seq[Instruction]): string =
  ## Short mnemonic chain for seed comments.
  var parts: seq[string]
  for i, instr in instrs:
    if i >= 6: break
    parts.add OpcodeTable[instr.opcode].mnemonic
  parts.join(";")

proc dens80(g: seq[uint8]; off, n: int): float =
  ## Fraction of 0x80 bytes in a window.
  if n <= 0: return 0
  var c = 0
  for i in 0..<n:
    if g[off + i] == 0x80: inc c
  c.float / n.float

proc recoverExitFlags(g: seq[uint8]; start, endOff: int): (bool, FlagState) =
  ## Decode a code span to recover flag state at endOff.
  for entryFlags in [
    FlagState(m8: false, x8: false, emulation: false),
    FlagState(m8: true, x8: true, emulation: false),
    FlagState(m8: true, x8: false, emulation: false),
    FlagState(m8: false, x8: true, emulation: false),
  ]:
    var flags = entryFlags
    var off = start
    var ok = true
    while off < endOff:
      let opSize = operandSize(OpcodeTable[g[off]].mode, flags)
      if off + 1 + opSize > endOff:
        ok = false
        break
      let instr = decode(g, off, flags)
      flags.applyInstruction(instr.opcode, instr.operand)
      off += instr.size
    if ok and off == endOff:
      return (true, flags)
  (false, FlagState(m8: false, x8: false, emulation: false))

proc isEpilogueInstrs(instrs: seq[Instruction]): bool =
  ## Every mnemonic is stack/flag/return.
  if instrs.len == 0: return false
  for instr in instrs:
    if OpcodeTable[instr.opcode].mnemonic notin EpilogueOnly:
      return false
  true

type
  Seed = object
    fileOff, freeLen, cover, score: int
    kind, summary: string
    flags: FlagState

proc main() =
  ## Emit strict sandwich-free seeds; --apply appends to resolved_entries.
  let apply = paramCount() >= 1 and paramStr(1) == "--apply"
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

  var freeStartAt = newSeq[int](g.len)
  var freeLenAt = newSeq[int](g.len)
  for i in 0..<g.len: freeStartAt[i] = -1
  var freeTotal, sandwichBytes, sandwichRuns = 0
  var o = 0
  while o < g.len:
    if claimed[o]:
      o += 1
      continue
    let start = o
    while o < g.len and not claimed[o]: o += 1
    let n = o - start
    freeTotal += n
    let sandwich = start > 0 and codeOnly[start - 1] and o < g.len and codeOnly[o]
    if sandwich:
      sandwichBytes += n
      sandwichRuns += 1
    for i in start..<o:
      freeStartAt[i] = start
      freeLenAt[i] = n

  proc freeIsSmallEpilogue(ft: int): bool =
    ## Target free window is ≤4 B pure epilogue ending in RTL/RTS.
    if ft < 0 or ft >= g.len or claimed[ft]: return false
    let fs = freeStartAt[ft]
    if fs < 0: return false
    let fl = freeLenAt[ft]
    if fl < 1 or fl > 4: return false
    let (instrs, covered) = decodeRange(g, fs, fl,
      FlagState(m8: false, x8: false, emulation: false))
    if covered != fl or not isEpilogueInstrs(instrs): return false
    OpcodeTable[instrs[^1].opcode].mnemonic in ["RTL", "RTS"]

  var seeds: seq[Seed]
  o = 0
  while o < g.len:
    if claimed[o]:
      o += 1
      continue
    let start = o
    while o < g.len and not claimed[o]: o += 1
    let n = o - start
    let sandwich = start > 0 and codeOnly[start - 1] and o < g.len and codeOnly[o]
    if not sandwich or n > 19: continue

    var ls = start - 1
    while ls > 0 and codeOnly[ls - 1]: dec ls
    let (rec, exitFlags) = recoverExitFlags(g, ls, start)
    if not rec: continue

    # Bitmap / plane noise: free mostly 0x80, or left tail is 0x80-heavy.
    let dFree = dens80(g, start, n)
    let dLeft = dens80(g, max(ls, start - 16), min(16, start - ls))
    if dFree > 0.5: continue
    if dLeft > 0.35: continue
    if start > 0 and g[start - 1] == 0x80 and g[start] == 0x80: continue

    let (instrs, covered) = decodeRange(g, start, n, exitFlags)
    if instrs.len == 0 or covered != n: continue
    let first = OpcodeTable[instrs[0].opcode].mnemonic
    let last = OpcodeTable[instrs[^1].opcode].mnemonic
    if last notin EndRun: continue
    if n == 1 and first notin ["RTS", "RTL"]: continue

    # Reject BRA #$00 (fall into next byte) and multi-BRA data soup.
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
      # Single control-flow instr only (no trailing ALU).
      honest = instrs.len == 1 or (
        instrs.len >= 1 and isEpilogueInstrs(instrs[1..^1]))
    if not honest: continue

    var tgtOk = true
    var off = start
    var flags = exitFlags
    for instr in instrs:
      let tgt = branchTargetSnes(instr, fileToSnes(off))
      if tgt >= 0:
        let ft = snesToFile(tgt.uint32)
        if ft < 0 or ft >= g.len:
          tgtOk = false
        elif codeOnly[ft] or (ft >= start and ft < start + n) or
             freeIsSmallEpilogue(ft):
          discard
        else:
          tgtOk = false
      flags.applyInstruction(instr.opcode, instr.operand)
      off += instr.size
    if not tgtOk: continue

    var score = 100 + n * 5
    if first in ["BRA", "PLD", "RTL", "RTS"]: score += 15
    if first == "BRA" and freeIsSmallEpilogue(
        snesToFile(branchTargetSnes(instrs[0], fileToSnes(start)).uint32)):
      score += 25
    seeds.add Seed(
      fileOff: start, freeLen: n, cover: covered, score: score,
      kind: "sandwich", summary: summaryOf(instrs), flags: exitFlags)

  var best = initTable[int, Seed]()
  for s in seeds:
    if s.fileOff notin best or s.score > best[s.fileOff].score:
      best[s.fileOff] = s
  var ordered: seq[Seed]
  for _, s in best: ordered.add s
  ordered.sort(proc(a, b: Seed): int =
    result = cmp(b.score, a.score)
    if result == 0: result = cmp(a.fileOff, b.fileOff))

  echo &"# free residual total: {freeTotal} B"
  echo &"# code|code sandwich free: {sandwichBytes} B / {sandwichRuns} runs"
  echo &"# strict seeds: {ordered.len}"
  echo ""
  var newN, newB, already = 0
  var lines: seq[string]
  for s in ordered:
    let snes = fileToSnes(s.fileOff)
    if snes in seeded:
      already += 1
      continue
    echo &"{snes:06X} {flagNibble(s.flags)}  # file 0x{s.fileOff:06X}+{s.freeLen} " &
         &"{s.kind} score={s.score} FULL code|code {s.summary}"
    lines.add &"{snes:06X} {flagNibble(s.flags)}  # sandwich 0x{s.fileOff:06X}+{s.freeLen} {s.summary}"
    newN += 1
    newB += s.cover

  echo ""
  echo &"# already seeded: {already}"
  echo &"# NEW seeds: {newN} covering {newB} B sandwich free"
  if apply and lines.len > 0:
    var f = open(ResolvedPath, fmAppend)
    f.write "\n# Sandwich free → code (probe_sandwich_continue) auto\n"
    for line in lines:
      f.writeLine line
    f.close()
    echo &"# APPLIED {lines.len} seeds → {ResolvedPath}"
  elif not apply:
    echo "# re-run with --apply to append (prefer hand-verify BRA/JMP first)"

when isMainModule:
  main()
