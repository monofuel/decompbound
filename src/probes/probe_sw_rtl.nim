import std/[strformat, algorithm],
  ../decompbound/[assembler, baserom_extract, memmap, opcodes, rom_chunks, disasm]

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
var codeOnly = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset ..< min(c.offset+c.length, claimed.len): claimed[i]=true
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset+c.length, codeOnly.len): codeOnly[i]=true

proc recover(g: seq[uint8]; start, endOff: int): (bool, FlagState, string) =
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
      if off + 1 + opSize > endOff: ok=false; break
      let instr = decode(g, off, flags)
      lastM = OpcodeTable[instr.opcode].mnemonic
      flags.applyInstruction(instr.opcode, instr.operand)
      off += instr.size
    if ok and off == endOff: return (true, flags, lastM)
  (false, FlagState(), "")

echo "=== sandwich free ending RTL/RTS (any size) ==="
var o=0
while o<g.len:
  if claimed[o]: o+=1; continue
  let s=o
  while o<g.len and not claimed[o]: o+=1
  let n=o-s
  let sandwich = s>0 and codeOnly[s-1] and o<g.len and codeOnly[o]
  if not sandwich: continue
  if g[o-1] notin [0x60u8, 0x6Bu8]: continue
  var hx=""
  for j in 0..<n: hx.add &"{g[s+j]:02X} "
  var ls=s-1
  while ls>0 and codeOnly[ls-1]: dec ls
  if s-ls>256: ls=s-256
  let (rec, fl, leftLast) = recover(g, ls, s)
  var dis=""
  if rec:
    let (instrs, cov) = decodeRange(g, s, n, fl)
    for i, instr in instrs:
      if i>8: break
      dis.add OpcodeTable[instr.opcode].mnemonic & ";"
    dis.add &" cov={cov}/{n}"
  else:
    dis="norec"
  # left tail hex
  var lhx=""
  for j in max(0,s-6)..<s: lhx.add &"{g[j]:02X} "
  var rhx=""
  for j in o..<min(g.len, o+4): rhx.add &"{g[j]:02X} "
  echo &"0x{s:06X}+{n} left={leftLast} [{hx}] dis={dis} L[{lhx}] R[{rhx}]"

echo "\n=== non-sandwich free with full epilogue cover (n<=8 ends RTL/RTS) ==="
const Epi = ["RTL","RTS","PLD","PLB","PLY","PLX","PLA","PLP","PHX","PHY","PHA","PHP","PHD","PHB","PHK","REP","SEP","NOP","TCD","TDC","CLC","SEC"]
o=0
var found=0
while o<g.len:
  if claimed[o]: o+=1; continue
  let s=o
  while o<g.len and not claimed[o]: o+=1
  let n=o-s
  let sandwich = s>0 and codeOnly[s-1] and o<g.len and codeOnly[o]
  if sandwich: continue
  if n>8 or n<1: continue
  if g[o-1] notin [0x60u8, 0x6Bu8]: continue
  # try flags from left if code
  var tries: seq[FlagState]
  if s>0 and codeOnly[s-1]:
    var ls=s-1
    while ls>0 and codeOnly[ls-1]: dec ls
    if s-ls>256: ls=s-256
    let (rec, fl, _) = recover(g, ls, s)
    if rec: tries.add fl
  tries.add FlagState(m8:false,x8:false,emulation:false)
  tries.add FlagState(m8:true,x8:true,emulation:false)
  for fl in tries:
    let (instrs, cov) = decodeRange(g, s, n, fl)
    if cov!=n or instrs.len==0: continue
    let last = OpcodeTable[instrs[^1].opcode].mnemonic
    if last notin ["RTL","RTS"]: continue
    var ok=true
    for instr in instrs:
      if OpcodeTable[instr.opcode].mnemonic notin Epi: ok=false
    if not ok: continue
    var sum=""
    for instr in instrs: sum.add OpcodeTable[instr.opcode].mnemonic & ";"
    var hx=""
    for j in 0..<n: hx.add &"{g[s+j]:02X} "
    let leftC = s>0 and codeOnly[s-1]
    let rightC = o<g.len and codeOnly[o]
    echo &"0x{s:06X}+{n} Lcode={leftC} Rcode={rightC} {sum} [{hx}]"
    found+=1
    break
echo &"found {found}"

echo "\n=== sandwich free: left fallThru (left not endsRun) with any decode cover ==="
const EndRun = ["RTL","RTS","JMP","JML","BRA","BRL"]
o=0
var ft=0
while o<g.len:
  if claimed[o]: o+=1; continue
  let s=o
  while o<g.len and not claimed[o]: o+=1
  let n=o-s
  if not (s>0 and codeOnly[s-1] and o<g.len and codeOnly[o]): continue
  if n>24: continue
  var ls=s-1
  while ls>0 and codeOnly[ls-1]: dec ls
  if s-ls>256: ls=s-256
  let (rec, fl, leftLast) = recover(g, ls, s)
  if not rec or leftLast in EndRun: continue
  let (instrs, cov) = decodeRange(g, s, n, fl)
  if instrs.len==0: continue
  var sum=""
  for i,instr in instrs:
    if i>10: break
    sum.add OpcodeTable[instr.opcode].mnemonic & ";"
  var hx=""
  for j in 0..<min(n,12): hx.add &"{g[s+j]:02X} "
  let last = if instrs.len>0: OpcodeTable[instrs[^1].opcode].mnemonic else: "?"
  echo &"0x{s:06X}+{n} left={leftLast} cov={cov}/{n} last={last} {sum} [{hx}]"
  ft+=1
  if ft>=40: break
echo &"fallThru shown {ft}"
