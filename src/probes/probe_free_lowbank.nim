import std/[strformat, algorithm],
  ../decompbound/[rom_chunks, baserom_extract, memmap, opcodes, assembler]

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
var codeOnly = newSeq[bool](g.len)
var kinds = newSeq[string](g.len)
for i in 0..<g.len: kinds[i] = "."
for c in allRomChunksMeta():
  let k = case c.kind
    of ckImplementedCode: "C"
    of ckImplementedMeta: "M"
    of ckUnclaimed: "."
  for i in c.offset ..< min(c.offset + c.length, claimed.len):
    if c.kind != ckUnclaimed:
      claimed[i] = true
      kinds[i] = k
    if c.kind == ckImplementedCode:
      codeOnly[i] = true

proc show(off, n: int) =
  echo &"--- window 0x{off:06X}+{n} ---"
  for i in off ..< off + n:
    if i >= g.len: break
    echo &"  0x{i:06X} {g[i]:02X} {kinds[i]}"

show(0x009220, 40)
show(0x016160, 30)

echo "\n# free runs banks C0-C4 n>=2:"
var o = 0
var total = 0
while o < min(g.len, 0x050000):
  if claimed[o]:
    o += 1
    continue
  let s = o
  while o < min(g.len, 0x050000) and not claimed[o]: o += 1
  let n = o - s
  if n < 2: continue
  total += n
  var hx = ""
  for j in 0 ..< min(n, 12): hx.add &"{g[s+j]:02X} "
  let leftC = s > 0 and codeOnly[s - 1]
  let rightC = o < g.len and codeOnly[o]
  let (instrs, cov) = decodeRange(g, s, n, FlagState(m8: false, x8: false, emulation: false))
  var sum = ""
  for i, instr in instrs:
    if i > 8: break
    sum.add OpcodeTable[instr.opcode].mnemonic & ";"
  echo &"0x{s:06X}+{n} L={leftC} R={rightC} cov={cov} {sum} [{hx}]"
echo &"total free C0-C4 n>=2: {total}"

echo "\n# free C0-CF n=2..16 ending RET full epi:"
const Epi = ["RTL", "RTS", "PLD", "PLB", "PLY", "PLX", "PLA", "PLP", "PHX", "PHY",
             "PHA", "PHP", "PHD", "PHB", "PHK", "REP", "SEP", "NOP", "TCD", "TDC",
             "CLC", "SEC", "TYA", "TXA", "TAX", "TAY", "XBA", "XCE", "INA", "DEA",
             "INX", "DEX", "INY", "DEY", "TXY", "TYX", "TSX", "TXS"]
o = 0
while o < min(g.len, 0x100000):
  if claimed[o]:
    o += 1
    continue
  let s = o
  while o < min(g.len, 0x100000) and not claimed[o]: o += 1
  let n = o - s
  if n < 2 or n > 16: continue
  if g[s + n - 1] notin [0x6Bu8, 0x60u8]: continue
  let leftC = s > 0 and codeOnly[s - 1]
  let rightC = o < g.len and codeOnly[o]
  if not leftC and not rightC: continue
  var flags = FlagState(m8: false, x8: false, emulation: false)
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
        flags = fl
        break
  let (instrs, cov) = decodeRange(g, s, n, flags)
  if cov != n or instrs.len == 0: continue
  var ok = true
  for instr in instrs:
    if OpcodeTable[instr.opcode].mnemonic notin Epi: ok = false
  if not ok: continue
  var sum = ""
  for instr in instrs: sum.add OpcodeTable[instr.opcode].mnemonic & ";"
  var hx = ""
  for j in 0 ..< n: hx.add &"{g[s+j]:02X} "
  echo &"{fileToSnes(s):06X} 0  # 0x{s:06X}+{n} L={leftC} R={rightC} {sum} [{hx}]"
