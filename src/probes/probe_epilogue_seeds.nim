## Pure epilogue free (ends RTL/RTS, full cover) abutting implemented code.
import
  std/[algorithm, os, sets, strformat, strutils],
  ../decompbound/[assembler, baserom_extract, memmap, opcodes, rom_chunks]

const
  ObservedPath = "src/decompbound/observed_entries.txt"
  ResolvedPath = "src/decompbound/resolved_entries.txt"
  Epi = ["RTL", "RTS", "PLD", "PLB", "PLY", "PLX", "PLA", "PLP",
         "PHX", "PHY", "PHA", "PHP", "PHD", "PHB", "PHK", "REP",
         "SEP", "NOP", "TCD", "TDC", "CLC", "SEC", "XCE", "XBA",
         "TXY", "TYX", "TAX", "TAY", "TXA", "TYA", "TSX", "TXS",
         "INA", "DEA", "INX", "DEX", "INY", "DEY"]

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

proc recover(g: seq[uint8]; start, endOff: int): (bool, FlagState) =
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
      if off + 1 + opSize > endOff: ok=false; break
      let instr = decode(g, off, flags)
      flags.applyInstruction(instr.opcode, instr.operand)
      off += instr.size
    if ok and off == endOff: return (true, flags)
  (false, FlagState())

proc isEpi(instrs: seq[Instruction]): bool =
  if instrs.len == 0: return false
  for instr in instrs:
    if OpcodeTable[instr.opcode].mnemonic notin Epi: return false
  true

proc sumOf(instrs: seq[Instruction]): string =
  var p: seq[string]
  for i, instr in instrs:
    if i >= 8: break
    p.add OpcodeTable[instr.opcode].mnemonic
  p.join(";")

let g = readGoldBaseromBytes()
let seeded = loadSeeded()
var claimed = newSeq[bool](g.len)
var codeOnly = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset ..< min(c.offset+c.length, claimed.len): claimed[i]=true
  if c.kind == ckImplementedCode:
    for i in c.offset ..< min(c.offset+c.length, codeOnly.len): codeOnly[i]=true

var freeB, newB = 0
var newN = 0
var o = 0
while o < g.len:
  if claimed[o]: o+=1; continue
  let s = o
  while o < g.len and not claimed[o]: o += 1
  let n = o - s
  freeB += n
  if n > 12: continue
  let leftC = s > 0 and codeOnly[s-1]
  let rightC = o < g.len and codeOnly[o]
  if not leftC and not rightC: continue

  var flagTries: seq[FlagState]
  if leftC:
    var ls = s-1
    while ls > 0 and codeOnly[ls-1]: dec ls
    if s-ls > 256: ls = s-256
    let (rec, fl) = recover(g, ls, s)
    if rec: flagTries.add fl
  flagTries.add FlagState(m8: false, x8: false, emulation: false)
  flagTries.add FlagState(m8: true, x8: true, emulation: false)
  flagTries.add FlagState(m8: true, x8: false, emulation: false)
  flagTries.add FlagState(m8: false, x8: true, emulation: false)

  var bestSum = ""
  var bestFl = FlagState()
  var ok = false
  for fl in flagTries:
    let (instrs, cov) = decodeRange(g, s, n, fl)
    if cov != n or instrs.len == 0: continue
    let first = OpcodeTable[instrs[0].opcode].mnemonic
    let last = OpcodeTable[instrs[^1].opcode].mnemonic
    if last notin ["RTL", "RTS"]: continue
    if n == 1 and first notin ["RTL", "RTS"]: continue
    if not isEpi(instrs): continue
    # Reject pure data-looking: multi-byte where only last is RTS and head is not stack/flag
    # already gated by isEpi
    bestSum = sumOf(instrs)
    bestFl = fl
    ok = true
    break
  if not ok: continue

  let snes = fileToSnes(s)
  if snes in seeded: continue
  # dens check for 80-plane
  var c80 = 0
  for j in 0..<n:
    if g[s+j] == 0x80: inc c80
  if n > 1 and c80.float / n.float > 0.4: continue

  var hx = ""
  for j in 0..<n: hx.add &"{g[s+j]:02X} "
  let side = if leftC and rightC: "code|code" elif leftC: "code|?" else: "?|code"
  echo &"{snes:06X} {flagNibble(bestFl)}  # file 0x{s:06X}+{n} {side} {bestSum} [{hx}]"
  newN += 1
  newB += n

echo &"# free {freeB}; NEW pure-epilogue abutting code: {newN} / {newB} B"
