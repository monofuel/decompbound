## Find pointers into top residual islands; measure seq walker yield alone.
import
  std/[algorithm, strformat, strutils, tables],
  ../decompbound/[rom_chunks, baserom_extract, memmap]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

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

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)

  let targets = [0x1B714F, 0x19A48C, 0x1929E4, 0x1A6045, 0x14AC64, 0x0AB1CB, 0x0F7B9E]
  # Scan for 24-bit far ptrs and bank-local u16s pointing near targets
  for tgt in targets:
    let snes = fileToSnes(tgt)
    let lo16 = int(snes and 0xFFFF)
    let bank = int((snes shr 16) and 0xFF)
    echo &"\n=== target 0x{tgt:06X} SNES ${snes:06X} bank=${bank:02X} lo=${lo16:04X} ==="
    var farHits = 0
    var u16Hits = 0
    # scan full ROM for far ptr bytes lo hi bank
    let b0 = uint8(lo16 and 0xFF)
    let b1 = uint8(lo16 shr 8)
    let b2 = uint8(bank)
    for o in 0 ..< g.len - 3:
      if g[o] == b0 and g[o+1] == b1 and g[o+2] == b2:
        # optional pad 00
        let pad = if o+3 < g.len: g[o+3].int else: -1
        if not claimed[o] or true:
          if farHits < 8:
            echo &"  far@0x{o:06X} pad={pad:02X} claimed={claimed[o]}"
          farHits += 1
      # bank-local u16 in same bank
      if (o shr 16) == (tgt shr 16) and g[o] == b0 and g[o+1] == b1:
        if u16Hits < 6:
          echo &"  u16@0x{o:06X} claimed={claimed[o]}"
        u16Hits += 1
    # also search nearby offsets ±0x20 for any far with same bank
    echo &"  exact far hits={farHits} same-bank u16 hits={u16Hits}"
    # search any far with bank matching that lands in residual run containing tgt
    var runLo, runHi = tgt
    # expand to full free run
    while runLo > 0 and not claimed[runLo-1]: runLo -= 1
    while runHi < g.len and not claimed[runHi]: runHi += 1
    echo &"  free run 0x{runLo:06X}..0x{runHi:06X} ({runHi-runLo} B)"
    var into = 0
    for o in 0 ..< g.len - 3:
      if g[o+2].int != bank: continue
      let a = g[o].int or (g[o+1].int shl 8)
      let fo = snesToFile(uint32(a or (bank shl 16)))
      if fo >= runLo and fo < runHi:
        if into < 12:
          echo &"  far@0x{o:06X} -> 0x{fo:06X} (+{fo-runLo})"
        into += 1
    echo &"  far ptrs into run: {into}"

main()
