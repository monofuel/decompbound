import
  std/sequtils,
  std/[algorithm, strformat, strutils, tables, sets],
  ../decompbound/[rom_chunks, baserom_extract, memmap, disasm, opcodes, assembler]

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      for i in c.offset ..< min(c.offset+c.length, claimed.len): claimed[i] = true
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset+c.length, isCode.len): isCode[i] = true

  var pure1, pure1B = 0
  var pure1List: seq[int]
  var o = 0
  while o < g.len:
    if claimed[o]:
      o += 1; continue
    let start = o
    while o < g.len and not claimed[o]: o += 1
    let n = o - start
    let left = start > 0 and isCode[start-1]
    let right = o < g.len and isCode[o]
    if left and right and n == 1 and g[start] in [0x60u8, 0x6Bu8]:
      pure1 += 1; pure1B += 1
      pure1List.add start
  echo &"pure 1B RTS/RTL sandwich free: {pure1B}"
  for fo in pure1List:
    echo &"  {fileToSnes(fo):06X} 0  # file 0x{fo:06X}+1 {g[fo]:02X}"

  # also pure 2B that decode as BRA/RTS etc
  echo "\npure sandwich free n=1..4 all heads:"
  var hist: CountTable[string]
  o = 0
  while o < g.len:
    if claimed[o]:
      o += 1; continue
    let start = o
    while o < g.len and not claimed[o]: o += 1
    let n = o - start
    let left = start > 0 and isCode[start-1]
    let right = o < g.len and isCode[o]
    if left and right and n <= 4:
      var hx = ""
      for j in 0..<n: hx.add &"{g[start+j]:02X}"
      hist.inc hx
  var keys = toSeq(hist.keys)
  keys.sort(proc(a,b: string): int =
    result = cmp(hist[b], hist[a])
    if result == 0: result = cmp(a,b))
  for i in 0 ..< min(40, keys.len):
    echo &"  {keys[i]}: {hist[keys[i]]}"

main()
