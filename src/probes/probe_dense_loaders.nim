## Probe LDA.L / absolute-long loaders in banks C0-C4 that land in residual
## free runs of dense banks CA, CE, D7, DB.

import
  std/[algorithm, os, strformat, strutils, tables, sets],
  ../decompbound/[memmap, rom_chunks, baserom_extract, common]

const
  Gold = "bin/Earthbound (U) [!].smc"
  TargetFileBanks = {0x0A, 0x0E, 0x17, 0x1B} # CA CE D7 DB
  LowBanks = 0..4 # code_bank00..04 = C0..C4

proc parseHex(s: string): int =
  ## Parse hex digits into an int.
  var v = 0
  for c in s:
    let d =
      if c in {'0'..'9'}: ord(c) - ord('0')
      elif c in {'a'..'f'}: ord(c) - ord('a') + 10
      elif c in {'A'..'F'}: ord(c) - ord('A') + 10
      else: -1
    if d < 0: continue
    v = (v shl 4) or d
  result = v

proc main() =
  ## Rank residual free runs by C0-C4 absolute-long loader hits.
  let gold = readFile(Gold)
  let chunks = allRomChunksMeta()

  var claimed = newSeq[bool](gold.len)
  for c in chunks:
    if c.kind != ckUnclaimed:
      for i in c.offset ..< c.offset + c.length:
        if i < claimed.len: claimed[i] = true

  type Run = object
    off, len: int
  var runs: seq[Run] = @[]
  var i = 0
  while i < gold.len:
    if claimed[i] or (i div 0x10000) notin TargetFileBanks:
      i += 1
      continue
    let start = i
    let fb0 = start div 0x10000
    while i < gold.len and not claimed[i] and (i div 0x10000) == fb0:
      i += 1
    runs.add Run(off: start, len: i - start)
  runs.sort(proc(a, b: Run): int = cmp(b.len, a.len))

  var residualTot = 0
  for r in runs: residualTot += r.len
  echo &"Target banks residual free runs: {runs.len} totaling {residualTot} B"

  var bankCode, bankMeta, bankUnc: array[256, int]
  for c in chunks:
    let fb = c.offset div 0x10000
    if fb notin TargetFileBanks: continue
    case c.kind
    of ckImplementedCode: bankCode[fb] += c.length
    of ckImplementedMeta: bankMeta[fb] += c.length
    of ckUnclaimed: bankUnc[fb] += c.length
  echo "Per-bank composition (code / meta / unclaimed / total 64K):"
  for fb in [0x0A, 0x0E, 0x17, 0x1B]:
    let snes = 0xC0 + fb
    let tot = bankCode[fb] + bankMeta[fb] + bankUnc[fb]
    echo &"  ${snes:02X}: code={bankCode[fb]} meta={bankMeta[fb]} unc={bankUnc[fb]} sum={tot}"

  type Hit = object
    bankFile: string
    lineNo: int
    line: string
    snes: uint32
    fileOff: int
    inResidual: bool
    runOff, runLen: int

  var hits: seq[Hit] = @[]

  for bi in LowBanks:
    let path = &"src/decompbound/generated/code_bank{bi:02X}.nim"
    if not fileExists(path): continue
    let text = readFile(path)
    var ln = 0
    for line in text.splitLines():
      ln += 1
      if not (('$') in line or ("0x" in line)): continue
      var j = 0
      while j < line.len:
        var snes: uint32 = 0
        var found = false
        if line[j] == '$' and j + 7 <= line.len:
          let digs = line[j+1 ..< j+7]
          var ok = true
          for c in digs:
            if not c.isAlphaNumeric: ok = false
          if ok:
            snes = parseHex(digs).uint32
            found = true
            j += 7
          else:
            j += 1
            continue
        elif j + 8 <= line.len and line[j] == '0' and line[j+1] in {'x', 'X'}:
          var k = j + 2
          while k < line.len and line[k].isAlphaNumeric: k += 1
          if k - (j + 2) == 6:
            snes = parseHex(line[j+2 ..< k]).uint32
            found = true
            j = k
          else:
            j += 1
            continue
        else:
          j += 1
          continue
        if not found: continue
        let bank = int((snes shr 16) and 0xFF)
        let fileBank = bank - 0xC0
        if fileBank notin TargetFileBanks: continue
        let fo = snesToFile(snes)
        if fo < 0 or fo >= gold.len: continue
        let upper = line.toUpperAscii
        let isLoad = ("LDA" in upper or "ADC" in upper or "AND" in upper or
          "ORA" in upper or "EOR" in upper or "CMP" in upper or "SBC" in upper or
          "LDX" in upper or "LDY" in upper or "STA" in upper)
        let isAbsL = ("AbsoluteLong" in line or ".L" in upper)
        if not (isLoad or isAbsL): continue
        var inRes = not claimed[fo]
        var ro, rl = 0
        if inRes:
          for r in runs:
            if fo >= r.off and fo < r.off + r.len:
              ro = r.off
              rl = r.len
              break
        hits.add Hit(bankFile: path.extractFilename, lineNo: ln, line: line.strip,
          snes: snes, fileOff: fo, inResidual: inRes, runOff: ro, runLen: rl)

  echo &"\nAbsolute-long hits from C0-C4 into CA/CE/D7/DB: {hits.len}"
  var resHits = 0
  var byRun = initTable[int, seq[Hit]]()
  for h in hits:
    if h.inResidual:
      resHits += 1
      if h.runOff notin byRun: byRun[h.runOff] = @[]
      byRun[h.runOff].add h
  echo &"  residual free-run hits: {resHits}"
  echo &"  residual runs with ≥1 hit: {byRun.len}"

  var runKeys: seq[int] = @[]
  for k in byRun.keys: runKeys.add k
  runKeys.sort(proc(a, b: int): int =
    result = cmp(byRun[b].len, byRun[a].len)
    if result == 0: result = cmp(a, b))

  echo "\nTop residual runs with C0-C4 abs-long hits:"
  for idx in 0 ..< min(30, runKeys.len):
    let k = runKeys[idx]
    let hs = byRun[k]
    let snes = fileToSnes(k)
    echo &"  run 0x{k:06X}+{hs[0].runLen} (${snes:06X}) hits={hs.len}"
    var seen = initHashSet[uint32]()
    for h in hs:
      if h.snes in seen: continue
      seen.incl h.snes
      if seen.len > 5: break
      let short = if h.line.len > 110: h.line[0..109] & "..." else: h.line
      echo &"    ${h.snes:06X} @ {h.bankFile}:{h.lineNo}  {short}"

  echo "\nLargest residual runs with ZERO C0-C4 abs-long hits:"
  var shown = 0
  for r in runs:
    if r.off in byRun: continue
    let snes = fileToSnes(r.off)
    var hex = ""
    for b in 0 ..< min(16, r.len):
      hex.add &"{gold[r.off + b].uint8:02X} "
    echo &"  0x{r.off:06X}+{r.len} (${snes:06X})  head: {hex}"
    shown += 1
    if shown >= 25: break

  var big, small = 0
  for r in runs:
    if r.len >= 64: big += r.len
    else: small += r.len
  echo &"\nResidual size: ≥64B runs = {big} B; <64B = {small} B"

  # Cross-check: how much residual sits BETWEEN code_span pieces in same bank
  # (false-code reclassification candidate = residual holes inside dense code)
  echo "\nResidual hole size histogram (all 4 banks):"
  var hist = [0, 0, 0, 0, 0] # 1-7, 8-15, 16-63, 64-255, 256+
  for r in runs:
    if r.len < 8: hist[0] += r.len
    elif r.len < 16: hist[1] += r.len
    elif r.len < 64: hist[2] += r.len
    elif r.len < 256: hist[3] += r.len
    else: hist[4] += r.len
  echo &"  1-7: {hist[0]}  8-15: {hist[1]}  16-63: {hist[2]}  64-255: {hist[3]}  256+: {hist[4]}"

main()
