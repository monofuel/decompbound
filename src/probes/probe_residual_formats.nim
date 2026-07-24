
## Probe residual free runs for script stream, action script, gfx_lz, zero-pad,
## and pack-table APU free. Also RE scale factors around AbsoluteLong in gen banks.

import
  std/[algorithm, os, strformat, strutils, tables, sets, sequtils],
  ../decompbound/[memmap, rom_chunks, baserom_extract, common, gfx_lz,
                  text_decode, action_script]

const
  PackTableFile = 0x04F947
  PackCount = 170
  MaxPackSize = 0x2800

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
  var rs = -1; var rl = 0
  for o in 0 ..< claimed.len:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0: result.add (rs, rl); rs = -1
  if rs >= 0: result.add (rs, rl)

proc freeRunsIn(claimed: seq[bool]; lo, hi: int): seq[tuple[o, n: int]] =
  result = @[]
  var rs = -1; var rl = 0
  let lim = min(hi, claimed.len)
  for o in lo ..< lim:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0: result.add (rs, rl); rs = -1
  if rs >= 0: result.add (rs, rl)

proc walkApu(g: seq[uint8]; off: int): tuple[ok: bool, size, blocks: int] =
  if off < 0 or off + 4 > g.len: return (false, 0, 0)
  var pos = off
  var blocks = 0
  while pos + 4 <= g.len:
    let ln = g[pos].int or (g[pos+1].int shl 8)
    let tgt = g[pos+2].int or (g[pos+3].int shl 8)
    if ln == 0:
      let size = pos + 4 - off
      if size > MaxPackSize or (blocks == 0 and tgt == 0): return (false, 0, 0)
      return (true, size, blocks)
    if ln > 0xC000 or pos + 4 + ln > g.len: return (false, 0, 0)
    if pos + 4 + ln - off > MaxPackSize: return (false, 0, 0)
    blocks += 1
    pos += 4 + ln
  (false, 0, 0)

proc packFo(g: seq[uint8]; i: int): int =
  let b = PackTableFile + i * 3
  let bank = g[b].int
  let a = g[b+1].int or (g[b+2].int shl 8)
  if bank < 0xC0 or bank > 0xEF: return -1
  snesToFile(uint32(a or (bank shl 16)))

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      mark(claimed, c.offset, c.length)

  var runs = freeRuns(claimed)
  runs.sort(proc(a,b: auto): int = cmp(b.n, a.n))
  echo &"residual runs={runs.len}"

  # --- formats on residual ---
  var ssTot, asTot, gfxTot, zeroTot, apuTot = 0
  var claimMask = claimed
  var claimN = 0

  # zero-pad ≥4
  for r in freeRuns(claimMask):
    if r.n < 4: continue
    var allZ = true
    for j in 0 ..< r.n:
      if g[r.o + j] != 0: allZ = false; break
    if not allZ: continue
    echo &"  zeroPad 0x{r.o:06X}+{r.n}"
    mark(claimMask, r.o, r.n)
    zeroTot += r.n
    claimN += 1
  echo &"# zero-pad: {zeroTot} B"

  # pack table free
  for i in 0 ..< PackCount:
    let fo = packFo(g, i)
    if fo < 0: continue
    let (ok, size, blocks) = walkApu(g, fo)
    if not ok: continue
    for r in freeRunsIn(claimMask, fo, fo + size):
      if r.n < 4: continue
      echo &"  apuPack 0x{r.o:06X}+{r.n} pack[{i}]@0x{fo:06X} size={size}"
      mark(claimMask, r.o, r.n)
      apuTot += r.n
      claimN += 1
  echo &"# apu pack free: {apuTot} B"

  # script stream on free runs ≥8
  for r in freeRuns(claimMask):
    if r.n < 8: continue
    # try offsets within first 16 bytes of run
    let consumed = consumeScriptStreamRun(g, r.o, r.n)
    if consumed >= 6:
      echo &"  scriptStream 0x{r.o:06X}+{consumed}"
      mark(claimMask, r.o, consumed)
      ssTot += consumed
      claimN += 1
  echo &"# script stream: {ssTot} B"

  # action script
  for r in freeRuns(claimMask):
    if r.n < 6: continue
    var best = 0
    var bestOff = -1
    for d in 0 ..< min(4, r.n):
      let w = walkActionScript(g, r.o + d, r.o + r.n)
      if isGoodActionScriptWalk(w) and w.length >= 4 and w.length <= r.n - d:
        if w.length > best:
          best = w.length
          bestOff = r.o + d
    if bestOff >= 0 and best >= 4:
      echo &"  actionScript 0x{bestOff:06X}+{best}"
      mark(claimMask, bestOff, best)
      asTot += best
      claimN += 1
  echo &"# action script: {asTot} B"

  # gfx_lz on large free
  for r in freeRuns(claimMask):
    if r.n < 32: continue
    for d in countup(0, min(64, r.n - 16), 8):
      let hi = min(r.o + d + 0x4000, g.len)
      let (decoded, consumed, clean) = decodeWithConsumed(g[r.o + d ..< hi])
      if clean and consumed >= 16 and decoded.len >= 64 and consumed <= r.n - d:
        let ratio = decoded.len.float / consumed.float
        if ratio >= 1.1 and ratio <= 40.0:
          echo &"  gfxLz 0x{r.o+d:06X}+{consumed} decoded={decoded.len}"
          mark(claimMask, r.o + d, consumed)
          gfxTot += consumed
          claimN += 1
          break
  echo &"# gfx_lz: {gfxTot} B"

  # --- AbsoluteLong scale RE from gen banks C0-CF (banks 00-0F) ---
  echo "\n# --- gen bank AbsoluteLong scale RE (banks 00-0F) ---"
  var scaleHits: seq[tuple[fo, scale, bank: int, mnem, line: string]] = @[]
  for bi in 0..0x0F:
    let path = &"src/decompbound/generated/code_bank{bi:02X}.nim"
    if not fileExists(path): continue
    let lines = readFile(path).splitLines()
    for li, line in lines:
      if "AbsoluteLong" notin line and "AbsoluteLongX" notin line: continue
      let upper = line.toUpperAscii
      if not ("LDA" in upper or "ADC" in upper or "AND" in upper or "CMP" in upper or
              "ORA" in upper or "EOR" in upper or "SBC" in upper):
        continue
      # find $xxxxxx
      var snes = -1
      var j = 0
      while j < line.len:
        if line[j] == '$' and j + 7 <= line.len:
          let digs = line[j+1 ..< j+7]
          var ok = true
          for c in digs:
            if c notin HexDigits: ok = false
          if ok:
            snes = parseHexInt(digs)
            break
        j += 1
      if snes < 0: continue
      let bank = (snes shr 16) and 0xFF
      if bank < 0xC0 or bank > 0xEF: continue
      let fo = snesToFile(snes.uint32)
      if fo < 0 or fo >= g.len or claimMask[fo]: continue
      # look back ~15 lines for ASL / scale comments
      var scale = 0
      let lo = max(0, li - 20)
      let window = lines[lo .. li].join("\n").toUpperAscii
      # common patterns: ASL (×2), double ASL (×4), *17, *14 etc.
      # also "ASL" count and "ADC" with same register
      let aslCount = window.count("ASL")
      if "ADC" in window and aslCount >= 1:
        # id*2 + id = *3; id*4+id=*5; id*8+id=*9; id*16+id=*17
        if aslCount == 4 and "ADC" in window: scale = 17  # common CADCA1 pattern
        elif aslCount == 3: scale = 8
        elif aslCount == 2: scale = 4
        elif aslCount == 1: scale = 2
      # also look for literal multiply comments
      if "#$" in window:
        discard
      if scale == 0 and aslCount == 1: scale = 2
      if scale == 0: continue
      if isFree(claimMask, fo, scale):
        scaleHits.add (fo, scale, bi, "LDA", line.strip)

  echo &"scale-inferred free residual hits: {scaleHits.len}"
  # group by base (rounded down to scale)
  var byBase = initTable[int, tuple[scale, count, maxFo: int]]()
  for h in scaleHits:
    let base = h.fo - (h.fo mod h.scale)
    if base notin byBase:
      byBase[base] = (h.scale, 1, h.fo)
    else:
      var t = byBase[base]
      t.count += 1
      t.maxFo = max(t.maxFo, h.fo)
      byBase[base] = t

  var tableTot = 0
  for base, t in byBase:
    # expand free run around base covering hits
    var lo = base
    var hi = t.maxFo + t.scale
    # snap to free run containing base
    if not isFree(claimMask, base, 1): continue
    # find free run bounds
    while lo > 0 and not claimMask[lo - 1]: lo -= 1
    while hi < claimMask.len and not claimMask[hi]: hi += 1
    # only claim portion that is multiple of scale from base
    let start = base
    var endO = min(hi, start + ((hi - start) div t.scale) * t.scale)
    # also extend backward aligned
    var start2 = start
    while start2 - t.scale >= lo and isFree(claimMask, start2 - t.scale, t.scale):
      start2 -= t.scale
    let n = endO - start2
    if n < t.scale * 2: continue
    if not isFree(claimMask, start2, n): continue
    echo &"  table scale={t.scale} 0x{start2:06X}+{n} hits~{t.count} bank~{0xC0}"
    mark(claimMask, start2, n)
    tableTot += n
    claimN += 1
  echo &"# scale tables: {tableTot} B"

  # CF30F7 5B residual
  block:
    const Rec = 5
    const Off = 0x0F30F7
    const RunLen = 14
    var o = Off
    var n = 0
    while o + Rec <= Off + RunLen and isFree(claimMask, o, Rec):
      # pattern soft: byte0==0x0A and byte2..3 == 00 80 often
      if g[o] == 0x0A and g[o+2] == 0x00 and g[o+3] == 0x80:
        n += Rec
        o += Rec
      else:
        break
    if n >= Rec:
      echo &"  table_cf5 0x{Off:06X}+{n}"
      mark(claimMask, Off, n)
      tableTot += n
      claimN += 1

  # CC7371 first 3×4B FF-term
  block:
    const Off = 0x0C7371
    var n = 0
    var o = Off
    while o + 4 <= Off + 401 and isFree(claimMask, o, 4) and g[o+3] == 0xFF:
      n += 4
      o += 4
    if n >= 8:
      echo &"  table_ccFF 0x{Off:06X}+{n}"
      mark(claimMask, Off, n)
      tableTot += n
      claimN += 1

  # C0B0A6
  if isFree(claimMask, 0x00B0A6, 4):
    echo "  table_c0BitMask 0x00B0A6+4"
    mark(claimMask, 0x00B0A6, 4)
    tableTot += 4
    claimN += 1

  # CC6ADA 6B pattern: xx 01 E6 E7 9C yy  (after optional first)
  block:
    let lo = 0x0C6ADA
    let hi = lo + 355
    # find runs of 6B matching * 01 E6 E7 9C *
    var o = lo
    var claimedHere = 0
    while o + 6 <= hi:
      if not isFree(claimMask, o, 6):
        o += 1
        continue
      if g[o+1] == 0x01 and g[o+2] == 0xE6 and g[o+3] == 0xE7 and g[o+4] == 0x9C:
        var n = 0
        var p = o
        while p + 6 <= hi and isFree(claimMask, p, 6) and
              g[p+1] == 0x01 and g[p+2] == 0xE6 and g[p+3] == 0xE7 and g[p+4] == 0x9C:
          n += 6
          p += 6
        if n >= 12:
          echo &"  table_cc6 0x{o:06X}+{n}"
          mark(claimMask, o, n)
          tableTot += n
          claimedHere += n
          claimN += 1
          o = p
          continue
      o += 1
    echo &"# CC6 6B pattern: {claimedHere} B"

  let total = zeroTot + apuTot + ssTot + asTot + gfxTot + tableTot
  echo &"\n# WAVE TOTAL: {total} B in {claimN} spans"
  echo &"#   zero={zeroTot} apu={apuTot} ss={ssTot} as={asTot} gfx={gfxTot} table={tableTot}"

main()
