## Validate the few leftover spans before emit.
import
  std/[strformat],
  ../decompbound/[rom_chunks, baserom_extract, action_script, gfx_lz]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0..<n:
    if o+j>=0 and o+j<c.len: c[o+j]=true

proc main() =
  let g = readGoldBaseromBytes()
  var claimed = newSeq[bool](g.len)
  var nameAt = newSeq[string](g.len)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)
  for s in KnownBaseromExtracts:
    for j in 0..<s.length:
      if s.offset+j < nameAt.len: nameAt[s.offset+j] = s.name

  proc ctx(o, n: int) =
    let L = if o>0: nameAt[o-1] else: "edge"
    let R = if o+n < nameAt.len: nameAt[o+n] else: "edge"
    var hx=""
    for j in 0..<min(24,n): hx.add &"{g[o+j]:02X} "
    echo &"  @0x{o:06X}+{n} L={L} R={R}"
    echo &"  hex={hx}"
    # free check
    var free=true
    for j in 0..<n:
      if claimed[o+j]: free=false
    echo &"  free={free}"

  echo "=== AS 0x1B0730 ==="
  ctx(0x1B0730, 6)
  let w = walkActionScript(g, 0x1B0730, 0x1B0730+16)
  echo &"  walk ended={w.ended} len={w.length} ops={w.ops} sig={w.sig} goodWalk={isGoodActionScriptWalk(w)}"
  echo &"  goodSpan6={isGoodActionScriptSpan(g, 0x1B0730, 6)}"

  echo "=== fix4 0x1F1602 ==="
  ctx(0x1F1602, 12)
  for i in 0..<3:
    let b=0x1F1602 + i*4
    echo &"  rec{i}: {g[b]:02X} {g[b+1]:02X} {g[b+2]:02X} {g[b+3]:02X}"

  echo "=== gfx candidates ==="
  for (o,n) in [(0x1144C9,5),(0x11ECB1,5)]:
    ctx(o,n)
    let slice = g[o ..< o+n]
    let (data, consumed, clean) = decodeWithConsumed(slice)
    echo &"  clean={clean} consumed={consumed} dec={data.len}"
    # also try with more context if claimed after
    let more = g[o ..< min(o+64, g.len)]
    let (d2,c2,cl2) = decodeWithConsumed(more)
    echo &"  with+64: clean={cl2} consumed={c2} dec={d2.len}"

  echo "=== zeros ==="
  for (o,n) in [(0x115DE8,1),(0x14DF5F,1),(0x1A9F07,2),(0x1D771D,1),(0x1E2ADB,1),(0x1E6C48,1)]:
    ctx(o,n)

  # FAR incomplete that are fullish free
  echo "=== fullish FAR free walks ==="
  for (o,n) in [(0x0374F1,6),(0x037506,7),(0x03B91D,7),(0x03B950,6),(0x0B02D2,6)]:
    ctx(o,n)
    let ww = walkActionScript(g, o, o+n)
    echo &"  walk ended={ww.ended} len={ww.length} ops={ww.ops} sig={ww.sig} good={isGoodActionScriptWalk(ww)} span={isGoodActionScriptSpan(g,o,n)}"

  # 15B twin pattern
  echo "=== 15B twins 0x0739AC / 0x073A68 ==="
  ctx(0x0739AC, 15)
  ctx(0x073A68, 15)
  # search AbsoluteLong into these
  for target in [0x0739AC, 0x073A68, 0x073C13]:
    let snesBank = 0xC0 + (target shr 16)
    let snesOff = target and 0xFFFF
    echo &"search LDA.L target bank=${snesBank:02X} off=${snesOff:04X}"
    var hits=0
    for bank in 0..0x2F:
      let base = bank*0x10000
      var pc=base
      while pc+4 <= base+0x10000 and pc+4 <= g.len:
        if g[pc] in [0xAFu8, 0xBFu8]:
          let lo = g[pc+1].int or (g[pc+2].int shl 8)
          let b = g[pc+3].int
          if b == snesBank and lo == snesOff:
            echo &"  hit @0x{pc:06X}"
            hits+=1
          # also window ±32
          let fileOff = ((b-0xC0) shl 16) or lo
          if b >= 0xC0 and abs(fileOff - target) <= 32 and fileOff != target:
            if hits < 5:
              echo &"  near @0x{pc:06X} -> 0x{fileOff:06X} delta={fileOff-target}"
            hits+=1
          pc += 4
        else:
          pc += 1
    echo &"  hits~{hits}"

main()
