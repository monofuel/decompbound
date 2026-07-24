import std/[strformat, os, sets, strutils, algorithm],
  ../decompbound/[rom_chunks, baserom_extract, memmap, opcodes, assembler]

const
  ObservedPath = "src/decompbound/observed_entries.txt"
  ResolvedPath = "src/decompbound/resolved_entries.txt"
  Epi = ["RTL", "RTS", "PLD", "PLB", "PLY", "PLX", "PLA", "PLP", "PHX", "PHY",
         "PHA", "PHP", "PHD", "PHB", "PHK", "REP", "SEP", "NOP", "TCD", "TDC",
         "CLC", "SEC", "TYA", "TXA", "TAX", "TAY", "XBA", "XCE", "INA", "DEA",
         "INX", "DEX", "INY", "DEY", "TXY", "TYX", "TSX", "TXS", "LDA", "LDX",
         "LDY", "STA", "STX", "STY", "STZ", "ASL", "LSR", "ROL", "ROR", "INC",
         "DEC", "AND", "ORA", "EOR", "ADC", "SBC", "CMP", "CPX", "CPY", "BIT",
         "TRB", "TSB", "MVP", "MVN", "PEA", "PEI", "PER", "BRK", "COP", "WDM",
         "STP", "WAI", "RTI", "JMP", "JML", "JSR", "JSL", "BRA", "BRL", "BEQ",
         "BNE", "BCC", "BCS", "BPL", "BMI", "BVC", "BVS"]

# Actually for honesty we want SHORT pure stack/flag epilogues OR short with LDA imm + PLD/RTL
const PureEpi = ["RTL", "RTS", "PLD", "PLB", "PLY", "PLX", "PLA", "PLP", "PHX", "PHY",
                 "PHA", "PHP", "PHD", "PHB", "PHK", "REP", "SEP", "NOP", "TCD", "TDC",
                 "CLC", "SEC", "TYA", "TXA", "TAX", "TAY", "XBA", "XCE", "INA", "DEA",
                 "INX", "DEX", "INY", "DEY", "TXY", "TYX", "TSX", "TXS", "ROL", "ROR",
                 "ASL", "LSR"]

proc loadSeeded(): HashSet[uint32] =
  result = initHashSet[uint32]()
  for path in [ObservedPath, ResolvedPath]:
    if not fileExists(path): continue
    for raw in readFile(path).splitLines():
      let line = raw.strip()
      if line.len == 0 or line.startsWith("#"): continue
      result.incl parseHexInt(line.splitWhitespace()[0]).uint32

proc flagNibble(f: FlagState): int =
  (if f.m8: 1 else: 0) or (if f.x8: 2 else: 0) or (if f.emulation: 4 else: 0)

let g = readGoldBaseromBytes()
let seeded = loadSeeded()
var claimed = newSeq[bool](g.len)
var codeOnly = newSeq[bool](g.len)
var metaOnly = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset ..< min(c.offset + c.length, claimed.len):
      claimed[i] = true
  if c.kind == ckImplementedCode:
    for i in c.offset ..< min(c.offset + c.length, codeOnly.len):
      codeOnly[i] = true
  if c.kind == ckImplementedMeta:
    for i in c.offset ..< min(c.offset + c.length, metaOnly.len):
      metaOnly[i] = true

proc isHonest(instrs: seq[Instruction]): bool =
  ## Pure epilogue, or LDA/LDX/LDY imm + pure epilogue, or single CF.
  if instrs.len == 0: return false
  let last = OpcodeTable[instrs[^1].opcode].mnemonic
  if last notin ["RTL", "RTS"]: return false
  var pure = true
  for instr in instrs:
    if OpcodeTable[instr.opcode].mnemonic notin PureEpi:
      pure = false
  if pure: return true
  # LDA/LDX/LDY #imm then pure epi
  let m0 = OpcodeTable[instrs[0].opcode].mnemonic
  if m0 in ["LDA", "LDX", "LDY"] and instrs.len >= 2:
    var restOk = true
    for instr in instrs[1..^1]:
      if OpcodeTable[instr.opcode].mnemonic notin PureEpi:
        restOk = false
    if restOk: return true
  false

proc sumOf(instrs: seq[Instruction]): string =
  var p: seq[string]
  for i, instr in instrs:
    if i >= 8: break
    p.add OpcodeTable[instr.opcode].mnemonic
  p.join(";")

var cands: seq[tuple[o, n, score: int, snes: uint32, fl: FlagState, sum, note: string]]
var o = 0
while o < g.len:
  if claimed[o]:
    o += 1
    continue
  let s = o
  while o < g.len and not claimed[o]: o += 1
  let n = o - s
  if n < 1 or n > 12: continue
  let leftC = s > 0 and codeOnly[s - 1]
  let rightC = o < g.len and codeOnly[o]
  let leftM = s > 0 and metaOnly[s - 1]
  let rightM = o < g.len and metaOnly[o]
  # Prefer abutting code or meta (real function body often meta extract)
  if not (leftC or rightC or leftM or rightM): continue

  var flagTries: seq[FlagState]
  if leftC:
    var ls = s - 1
    while ls > 0 and codeOnly[ls - 1]: dec ls
    if s - ls > 128: ls = s - 128
    for entryFlags in [
      FlagState(m8: false, x8: false, emulation: false),
      FlagState(m8: true, x8: true, emulation: false),
      FlagState(m8: true, x8: false, emulation: false),
      FlagState(m8: false, x8: true, emulation: false),
    ]:
      var fl = entryFlags
      var off = ls
      var ok = true
      while off < s:
        let opSize = operandSize(OpcodeTable[g[off]].mode, fl)
        if off + 1 + opSize > s:
          ok = false
          break
        let instr = decode(g, off, fl)
        fl.applyInstruction(instr.opcode, instr.operand)
        off += instr.size
      if ok and off == s:
        flagTries.add fl
        break
  # common widths
  flagTries.add FlagState(m8: false, x8: false, emulation: false)
  flagTries.add FlagState(m8: true, x8: true, emulation: false)
  flagTries.add FlagState(m8: true, x8: false, emulation: false)
  flagTries.add FlagState(m8: false, x8: true, emulation: false)

  var bestSum = ""
  var bestFl = FlagState()
  var ok = false
  for fl in flagTries:
    let (instrs, cov) = decodeRange(g, s, n, fl)
    if cov != n or not isHonest(instrs): continue
    bestSum = sumOf(instrs)
    bestFl = fl
    ok = true
    break
  if not ok: continue

  # Reject dataish sequential tables for PLD;RTS alone in high banks
  if n == 2 and g[s] == 0x2B:
    var cnt = 0
    for j in max(0, s - 10) ..< min(g.len, s + n + 10):
      if g[j] in [0xA0u8, 0xE0u8]: cnt += 1
    if cnt >= 6: continue

  # Prefer low banks (C0-C4) and meta-abutting
  var score = n * 10
  if s < 0x050000: score += 50
  if leftM or rightM: score += 30
  if leftC or rightC: score += 20
  if bestSum.contains("PLD") or bestSum.contains("TYA"): score += 15
  if bestSum.startsWith("LDA"): score += 20

  let snes = fileToSnes(s)
  if snes in seeded: continue
  var note = ""
  if leftC and rightC: note = "code|code"
  elif leftM and rightC: note = "meta|code"
  elif leftC and rightM: note = "code|meta"
  elif leftM: note = "meta|?"
  elif rightC: note = "?|code"
  elif leftC: note = "code|?"
  else: note = "other"
  cands.add (s, n, score, snes, bestFl, bestSum, note)

cands.sort(proc(a, b: auto): int =
  result = cmp(b.score, a.score)
  if result == 0: result = cmp(a.o, b.o))

var newB = 0
var newN = 0
for c in cands:
  var hx = ""
  for j in 0 ..< c.n: hx.add &"{g[c.o+j]:02X} "
  echo &"{c.snes:06X} {flagNibble(c.fl)}  # file 0x{c.o:06X}+{c.n} score={c.score} {c.note} {c.sum} [{hx}]"
  newN += 1
  newB += c.n
echo &"# NEW: {newN} / {newB} B"
