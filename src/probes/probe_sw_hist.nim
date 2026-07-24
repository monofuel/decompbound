import std/[strformat, tables, algorithm],
  ../decompbound/[baserom_extract, memmap, rom_chunks]
let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
var codeOnly = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed:
    for i in c.offset ..< min(c.offset+c.length, claimed.len): claimed[i]=true
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset+c.length, codeOnly.len): codeOnly[i]=true
var hist: CountTable[int]
var histB: CountTable[int]
var endByte: CountTable[string]
var free, sw = 0
var o = 0
var swtop: seq[tuple[n,o:int]]
while o < g.len:
  if claimed[o]: o+=1; continue
  let s=o
  while o<g.len and not claimed[o]: o+=1
  let n=o-s
  free+=n
  let sandwich = s>0 and codeOnly[s-1] and o<g.len and codeOnly[o]
  if not sandwich: continue
  sw+=n
  let b = if n<=1: 1 elif n==2: 2 elif n==3: 3 elif n==4: 4 elif n<=6: 6 elif n<=8: 8 elif n<=12: 12 elif n<=16: 16 elif n<=24: 24 elif n<=32: 32 elif n<=48: 48 elif n<=64: 64 else: 99
  hist.inc b
  histB.inc b, n
  let tail = g[o-1]
  let key = case tail
    of 0x6B: "RTL"
    of 0x60: "RTS"
    of 0x40: "RTI?"
    of 0x4C: "JMP?"
    of 0x5C: "JML?"
    of 0x80: "BRA?"
    of 0x6C, 0x7C, 0xDC: "indJMP"
    else: &"0x{tail:02X}"
  endByte.inc key
  swtop.add (n,s)
swtop.sort(proc(a,b: auto):int = cmp(b.n,a.n))
echo &"free {free} sandwich {sw}"
echo "size hist (runs / bytes):"
var keys: seq[int]
for k in hist.keys: keys.add k
keys.sort()
for k in keys:
  echo &"  n~{k}: {hist[k]} runs / {histB[k]} B"
echo "ending byte of sandwich free:"
var ek: seq[string]
for k in endByte.keys: ek.add k
ek.sort()
for k in ek:
  echo &"  {k}: {endByte[k]}"
echo "top sandwich free:"
for i, t in swtop:
  if i>=30: break
  var hx=""
  for j in 0..<min(16,t.n):
    hx.add &"{g[t.o+j]:02X} "
  echo &"  0x{t.o:06X}+{t.n} head={hx}"
