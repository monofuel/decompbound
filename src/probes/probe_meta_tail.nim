import std/[strformat, os, sets, strutils, algorithm],
  ../decompbound/[rom_chunks, baserom_extract, memmap, opcodes, assembler]

const
  ObservedPath = "src/decompbound/observed_entries.txt"
  ResolvedPath = "src/decompbound/resolved_entries.txt"
  PureEpi = ["RTL", "RTS", "PLD", "PLB", "PLY", "PLX", "PLA", "PLP", "PHX", "PHY",
             "PHA", "PHP", "PHD", "PHB", "PHK", "REP", "SEP", "NOP", "TCD", "TDC",
             "CLC", "SEC", "TYA", "TXA", "TAX", "TAY", "XBA", "XCE", "INA", "DEA",
             "INX", "DEX", "INY", "DEY", "TXY", "TYX", "TSX", "TXS"]

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
  if instrs.len == 0: return false
  let last = OpcodeTable[instrs[^1].opcode].mnemonic
  if last notin ["RTL", "RTS"]: return false
  var pure = true
  for instr in instrs:
    if OpcodeTable[instr.opcode].mnemonic notin PureEpi: pure = false
  if pure: return true
  let m0 = OpcodeTable[instrs[0].opcode].mnemonic
  if m0 in ["LDA", "LDX", "LDY"] and instrs.len >= 2:
    for instr in instrs[1..^1]:
      if OpcodeTable[instr.opcode].mnemonic notin PureEpi: return false
    return true
  false

# Reject if free starts mid-instruction from left meta decode
proc leftMetaAligned(s: int): bool =
  ## Walk back meta region; if it ends on instruction boundary, ok.
  if s == 0 or not metaOnly[s - 1]: return true
  var ls = s - 1
  while ls > 0 and metaOnly[ls - 1]: dec ls
  if s - ls > 256: ls = s - 256
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
    if ok and off == s: return true
  false

var o = 0
var newB, newN = 0
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
  if not (leftC or rightC or leftM or rightM): continue

  # Alignment gate for meta-left
  if leftM and not leftMetaAligned(s):
    continue

  var flagTries: seq[FlagState]
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
    bestSum = ""
    for i, instr in instrs:
      if i > 0: bestSum.add ";"
      bestSum.add OpcodeTable[instr.opcode].mnemonic
      if i >= 7: break
    bestFl = fl
    ok = true
    break
  if not ok: continue

  # dataish PLD
  if n == 2 and g[s] == 0x2B:
    var cnt = 0
    for j in max(0, s - 10) ..< min(g.len, s + n + 10):
      if g[j] in [0xA0u8, 0xE0u8]: cnt += 1
    if cnt >= 6: continue

  # single-byte only if sandwich code|code
  if n == 1 and not (leftC and rightC): continue

  let snes = fileToSnes(s)
  if snes in seeded: continue
  var note = ""
  if leftM and rightC: note = "meta|code"
  elif leftC and rightC: note = "code|code"
  elif leftC and rightM: note = "code|meta"
  elif rightC: note = "?|code"
  elif leftC: note = "code|?"
  elif leftM: note = "meta|?"
  else: note = "other"

  var hx = ""
  for j in 0 ..< n: hx.add &"{g[s+j]:02X} "
  echo &"{snes:06X} {flagNibble(bestFl)}  # file 0x{s:06X}+{n} {note} {bestSum} [{hx}]"
  newN += 1
  newB += n

echo &"# NEW aligned honest epi: {newN} / {newB} B"
