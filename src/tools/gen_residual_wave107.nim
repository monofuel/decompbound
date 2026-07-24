## Emit residual wave107 claims: expanded structure gates + CE62EE false-code reclass.
## Free residual only for structure families (code ∩ extract = 0 on free claims).
## CE62EE carve may overlap raw code_spans; inventory carves via carveSpanAroundHoles.
## No residualFree_*.
import
  std/[algorithm, strformat, strutils, tables, sequtils],
  ../decompbound/[rom_chunks, baserom_extract]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len:
      c[o + j] = true

proc isFree(claimed: seq[bool]; o, n: int): bool =
  if o < 0 or n <= 0 or o + n > claimed.len:
    return false
  for j in 0 ..< n:
    if claimed[o + j]:
      return false
  true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  var rs = -1
  var rl = 0
  for o in 0 ..< claimed.len:
    if not claimed[o]:
      if rs < 0:
        rs = o
        rl = 1
      else:
        rl += 1
    else:
      if rs >= 0:
        result.add (rs, rl)
        rs = -1
  if rs >= 0:
    result.add (rs, rl)

proc emit(kind, name: string; o, n: int; note: string) =
  echo &"""  BaseromExtractSpan(
    name: "{name}",
    offset: 0x{o:06X},
    length: {n},
    kind: {kind},
    note: "{note}"),"""

proc main() =
  ## Build wave107 residual structure + CE62EE carve claim list.
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var isCode = newSeq[bool](g.len)
  var isMeta = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset + c.length, isCode.len):
        isCode[i] = true
    if c.kind == ckImplementedMeta:
      for i in c.offset ..< min(c.offset + c.length, isMeta.len):
        isMeta[i] = true

  var total = 0
  var spanCount = 0
  var totals: Table[string, int]
  var nSpans: Table[string, int]
  proc bump(key: string; n: int) =
    if key notin totals:
      totals[key] = 0
      nSpans[key] = 0
    totals[key] = totals[key] + n
    nSpans[key] = nSpans[key] + 1
    total += n
    spanCount += 1

  echo "  # --- residual wave107: structure expand + CE62EE false-code reclass ---"

  # 1) u8pair min2 @70% (extends wave105 min3@55%)
  for r in freeRuns(claimed):
    if r.n < 4 or r.n mod 2 != 0:
      continue
    let nRec = r.n div 2
    if nRec < 2:
      continue
    var ok = 0
    var nz = 0
    for i in 0 ..< nRec:
      let a = g[r.o + i * 2]
      let b = g[r.o + i * 2 + 1]
      if a <= 0x50 or b <= 0x50:
        ok += 1
      if a != 0 or b != 0:
        nz += 1
    if nz * 2 < nRec:
      continue
    if ok * 100 < nRec * 70:
      continue
    emit("ekTable", &"table_u8pair2_w107_0x{r.o:06X}", r.o, r.n,
      "u8 pair residual (≥2 recs, ≥70% lo-byte≤0x50); free only; wave107")
    mark(claimed, r.o, r.n)
    bump("u8pair2", r.n)

  # 2) plane50 even-prefix ≥6 (wave103 used ≥8)
  for r in freeRuns(claimed):
    let evenN = r.n and not 1
    if evenN < 6:
      continue
    let pairs = evenN div 2
    var eq = 0
    for i in 0 ..< pairs:
      if g[r.o + i * 2] == g[r.o + i * 2 + 1]:
        eq += 1
    if eq * 100 < pairs * 50:
      continue
    emit("ekTable", &"table_plane50_w107_0x{r.o:06X}", r.o, evenN,
      "SNES bitplane-like residual even-prefix≥6 @50% equal pairs; free only; wave107")
    mark(claimed, r.o, evenN)
    bump("plane50", evenN)

  # 3) loplane 00-1F n≥4, ≥2 distinct, not pure zero
  for r in freeRuns(claimed):
    if r.n < 4:
      continue
    var ok = true
    var distSet: set[uint8]
    for j in 0 ..< r.n:
      if g[r.o + j] > 0x1F:
        ok = false
        break
      distSet.incl g[r.o + j]
    if not ok:
      continue
    if distSet.len < 2:
      continue
    emit("ekTable", &"table_loplane_w107_0x{r.o:06X}", r.o, r.n,
      "Low control-plane residual bytes 0x00–0x1F (≥2 distinct); free only; wave107")
    mark(claimed, r.o, r.n)
    bump("loplane", r.n)

  # 4) term F0–FF clean body n≥2 with anti-opcode head
  let badHeads: set[uint8] = {0x00, 0x18, 0x20, 0x22, 0x38, 0x40, 0x48, 0x4C,
    0x5C, 0x60, 0x68, 0x6B, 0x78, 0x80, 0xA0, 0xA2, 0xA5, 0xA9, 0xAD, 0xAE,
    0xAF, 0xC2, 0xD0, 0xE2, 0xEA, 0xF0, 0xF4, 0xFA, 0xFB}
  for r in freeRuns(claimed):
    if r.n < 2 or r.n > 32:
      continue
    let t = g[r.o + r.n - 1]
    if t < 0xF0:
      continue
    if g[r.o] in badHeads:
      continue
    var bodyTerm = 0
    var bodyNZ = 0
    var hi = 0
    var z = 0
    for j in 0 ..< r.n - 1:
      if g[r.o + j] == t:
        bodyTerm += 1
      elif g[r.o + j] != 0:
        bodyNZ += 1
      if g[r.o + j] >= 0xE0:
        hi += 1
      if g[r.o + j] == 0:
        z += 1
    if bodyTerm != 0 or bodyNZ < 1:
      continue
    if hi * 2 > r.n or z * 3 > r.n:
      continue
    emit("ekTable", &"table_term1_w107_0x{r.o:06X}", r.o, r.n,
      &"Terminator 0x{t:02X} clean-body residual min2 anti-opcode; free only; wave107")
    mark(claimed, r.o, r.n)
    bump("term1", r.n)

  # 5) bitMask powers-of-two distinct ≥3 (wave103 used ≥4)
  for r in freeRuns(claimed):
    if r.n < 3:
      continue
    var s: set[uint8]
    var ok = true
    for j in 0 ..< r.n:
      let b = g[r.o + j]
      if b notin [0x01u8, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80]:
        ok = false
        break
      s.incl b
    if not ok or s.len < 3:
      continue
    emit("ekTable", &"table_bitMask_w107_0x{r.o:06X}", r.o, r.n,
      "Bit-mask residual distinct powers-of-two ≥3; free only; wave107")
    mark(claimed, r.o, r.n)
    bump("bitMask", r.n)

  # 6) xxFF pair stream full free cover
  for r in freeRuns(claimed):
    if r.n < 2 or r.n mod 2 != 0:
      continue
    var ok = true
    var nz = 0
    for i in 0 ..< (r.n div 2):
      if g[r.o + i * 2 + 1] != 0xFF:
        ok = false
        break
      if g[r.o + i * 2] != 0:
        nz += 1
    if not ok or nz < 1:
      continue
    emit("ekTable", &"table_xxFF_w107_0x{r.o:06X}", r.o, r.n,
      "xxFF pair residual stream full free cover; free only; wave107")
    mark(claimed, r.o, r.n)
    bump("xxFF", r.n)

  let freeOnlyTotal = total
  let freeOnlySpans = spanCount

  # 7) CE62EE 5B table carve: loader $C2EBDF LDA.L,X; 110×[far][00][type1..6]
  # Allow lo==0 null far. Reclass false-positive code_spans → meta (label honesty).
  const
    Ce62eeBase = 0x0E62EE
    Ce62eeRecs = 110
    Ce62eeLen = Ce62eeRecs * 5
  var ceFree = 0
  var ceCode = 0
  var ceOk = true
  for r in 0 ..< Ce62eeRecs:
    let o = Ce62eeBase + r * 5
    let b = g[o + 2]
    let z = g[o + 3]
    let t = g[o + 4]
    if b < 0xC0 or b > 0xEF or z != 0 or t < 1 or t > 6:
      ceOk = false
      break
  for i in 0 ..< Ce62eeLen:
    let o = Ce62eeBase + i
    if isMeta[o]:
      ceOk = false
      break
    if isCode[o]:
      ceCode += 1
    elif not claimed[o]:
      ceFree += 1
    else:
      ceOk = false
      break
  if ceOk and Ce62eeLen == 550:
    emit("ekTable", &"table_ce5far_carve_w107_0x{Ce62eeBase:06X}", Ce62eeBase, Ce62eeLen,
      "CE62EE 110×5B [far][00][type1..6] loader $C2EBDF LDA.L,X; free+false-code carve; wave107")
    mark(claimed, Ce62eeBase, Ce62eeLen)
    bump("ce5far", Ce62eeLen)
  else:
    echo &"  # WARNING: CE62EE carve rejected ceOk={ceOk} free={ceFree} code={ceCode}"

  var rem = 0
  var rn = 0
  var sandwich = 0
  for r in freeRuns(claimed):
    rem += r.n
    rn += 1
    let leftCode = r.o > 0 and isCode[r.o - 1]
    let rightCode = r.o + r.n < isCode.len and isCode[r.o + r.n]
    if leftCode and rightCode:
      sandwich += r.n

  echo &"  # WAVE107 TOTAL: {total} B in {spanCount} spans (free residual {freeOnlyTotal + ceFree} B structure+hole; carve total includes code reclass)"
  echo &"  # free-only structure: {freeOnlyTotal} B / {freeOnlySpans} spans; CE62EE free hole {ceFree} B + code reclass {ceCode} B"
  var keys = toSeq(totals.keys)
  keys.sort()
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}={totals[k]}/{nSpans[k]}"
  echo &"  # breakdown: {parts.join(\" \")}"
  echo &"  # residual left after wave107: {rem} B in {rn} runs (sandwich ~{sandwich})"
  let exact = (3145728 - rem).float * 100.0 / 3145728.0
  echo &"  # expected coverage ~{exact:.4f}%"

main()
