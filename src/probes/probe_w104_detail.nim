import
  std/[algorithm, strformat, strutils, tables, sets, sequtils],
  ../decompbound/[rom_chunks, baserom_extract, action_script, text_decode, gfx_lz, memmap]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len: return false
  for j in 0 ..< n:
    if claimed[o + j]: return false
  true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  result = @[]
  var rs = -1
  var rl = 0
  for o in 0 ..< claimed.len:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0: result.add (rs, rl); rs = -1
  if rs >= 0: result.add (rs, rl)

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset+c.length, isCode.len): isCode[i] = true

  # Classify remaining far3-like triples in free
  var cat = initTable[string, int]()
  var catN = initTable[string, int]()
  proc bump(k: string; n: int) =
    if k notin cat: cat[k]=0; catN[k]=0
    cat[k]+=n; catN[k]+=1

  for r in freeRuns(claimed):
    if r.n < 3: continue
    var i = 0
    while i + 3 <= r.n:
      let lo = g[r.o+i].int or (g[r.o+i+1].int shl 8)
      let b = g[r.o+i+2].int
      if b >= 0xC0 and b <= 0xFF:
        var key = ""
        if b <= 0xEF and lo != 0: key = "C0EFlo"
        elif b <= 0xEF and lo == 0: key = "C0EFzero"
        elif b >= 0xF0 and lo != 0: key = "F0FFlo"
        else: key = "F0FFzero"
        # chain length
        var k = i
        while k + 3 <= r.n:
          let lo2 = g[r.o+k].int or (g[r.o+k+1].int shl 8)
          let b2 = g[r.o+k+2].int
          let ok =
            if key.startsWith("C0EF"): b2 >= 0xC0 and b2 <= 0xEF and (lo2 != 0) == (lo != 0)
            else: b2 >= 0xF0 and b2 <= 0xFF
          if not ok: break
          # keep same lo!=0 class
          if key == "C0EFlo" and lo2 == 0: break
          if key == "C0EFzero" and lo2 != 0: break
          k += 3
        let n = k - i
        if n >= 3:
          bump(key, n)
          # sample
          if catN[key] <= 5:
            echo &"  sample {key} 0x{r.o+i:06X}+{n} head={g[r.o+i]:02X}{g[r.o+i+1]:02X}{g[r.o+i+2]:02X}"
          i = k
        else:
          i += 1
      else:
        i += 1

  echo "far3 class totals:"
  for k in cat.keys.toSeq.sorted:
    echo &"  {k}: {cat[k]} B / {catN[k]}"

  # term min2 quality samples
  var termB, termN = 0
  var samples = 0
  for termByte in 0xF0 .. 0xFF:
    var o = 0
    while o < g.len:
      if claimed[o]:
        o += 1; continue
      var k = o
      while k < g.len and not claimed[k] and g[k] != termByte.uint8 and (k-o) < 32:
        k += 1
      if k < g.len and not claimed[k] and g[k] == termByte.uint8:
        let n = k - o + 1
        if n == 2 and isFree(claimed, o, n):
          var tc, hi, z = 0
          for j in 0 ..< n:
            if g[o+j] == termByte.uint8: tc += 1
            if g[o+j] >= 0xE0: hi += 1
            if g[o+j] == 0: z += 1
          if tc == 1 and hi * 2 <= n and z * 3 <= n:
            termB += n; termN += 1
            if samples < 20:
              echo &"  term2 0x{o:06X} {g[o]:02X}{g[o+1]:02X} term=0x{termByte:02X}"
              samples += 1
            # don't mark - just count
            o = k + 1; continue
      o += 1
  echo &"term min2 only (n==2 quality): {termB}/{termN}"

  # high conf sandwich seeds not yet covered
  echo "\n# sandwich free with clean epilogue decode (n<=8):"
  var scB, scN = 0
  for r in freeRuns(claimed):
    let leftCode = r.o > 0 and isCode[r.o - 1]
    let rightCode = r.o + r.n < isCode.len and isCode[r.o + r.n]
    if not (leftCode and rightCode): continue
    if r.n > 8: continue
    let b0 = g[r.o]
    if b0 in [0x6Bu8, 0x60u8]: # RTL/RTS
      scB += r.n; scN += 1
      if scN <= 30:
        var hx = ""
        for j in 0 ..< r.n: hx.add &"{g[r.o+j]:02X} "
        echo &"  RTL/RTS sandwich 0x{r.o:06X}+{r.n} {hx}"
    elif r.n >= 2 and b0 == 0xC2 and g[r.o+1] in [0x30u8, 0x31u8, 0x20u8, 0x10u8]:
      scB += r.n; scN += 1
      if scN <= 40:
        var hx = ""
        for j in 0 ..< min(r.n, 8): hx.add &"{g[r.o+j]:02X} "
        echo &"  REP sandwich 0x{r.o:06X}+{r.n} {hx}"
  echo &"RTL/RTS/REP sandwich free: {scB}/{scN}"

main()
