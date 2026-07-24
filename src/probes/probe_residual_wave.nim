## Probe residual SS/AS and format claims for this wave.
import
  std/[strformat, strutils, algorithm, os],
  ../decompbound/[baserom_extract, text_decode, action_script, rom_chunks]

proc main() =
  ## Run residual format probes against gold + chunk inventory.
  let g = readGoldBaseromBytes()
  let chunks = allRomChunksMeta()

  echo "===== named gap SS/AS ====="
  for (off, glen) in [
    (0x09EE90, 379), (0x05980E, 141), (0x05ACD3, 365), (0x0E6746, 446),
    (0x0AB440, 396), (0x053AF6, 96), (0x054065, 128), (0x05A2A4, 33),
    (0x0C6ADA, 355), (0x0C6DCF, 368), (0x0C7371, 401)
  ]:
    let lim = off + glen
    let w = walkScriptStream(g, off, lim)
    let a = walkActionScript(g, off, lim)
    echo &"0x{off:06X}: SS len={w.length} ended={w.ended} glyphs={w.glyphs} ctrl={w.controls} bad={w.badGlyphs} good={isGoodScriptStream(w)} | AS len={a.length} good={isGoodActionScriptWalk(a)}"
    # try scan inside gap for any good SS
    var pos = off
    var ss = 0
    var asb = 0
    while pos < lim:
      let w2 = walkScriptStream(g, pos, lim)
      if isGoodScriptStream(w2):
        ss += w2.length
        pos += w2.length
        continue
      let a2 = walkActionScript(g, pos, lim)
      if isGoodActionScriptWalk(a2):
        asb += a2.length
        pos += a2.length
        continue
      pos += 1
    if ss > 0 or asb > 0:
      echo &"  inner SS={ss} AS={asb}"

  echo "\n===== full unclaimed SS/AS rescan ====="
  var totalSS = 0
  var totalAS = 0
  var ssN = 0
  var asN = 0
  var ssClaims: seq[(int,int)] = @[]
  var asClaims: seq[(int,int)] = @[]
  for c in chunks:
    if c.kind != ckUnclaimed or c.length < 6: continue
    var pos = c.offset
    let lim = c.offset + c.length
    while pos < lim:
      let w = walkScriptStream(g, pos, lim)
      if isGoodScriptStream(w):
        # merge runs
        if ssClaims.len > 0 and ssClaims[^1][0] + ssClaims[^1][1] == pos:
          ssClaims[^1][1] += w.length
        else:
          ssClaims.add (pos, w.length)
        totalSS += w.length
        ssN += 1
        pos += w.length
        continue
      let a = walkActionScript(g, pos, lim)
      if isGoodActionScriptWalk(a):
        if asClaims.len > 0 and asClaims[^1][0] + asClaims[^1][1] == pos:
          asClaims[^1][1] += a.length
        else:
          asClaims.add (pos, a.length)
        totalAS += a.length
        asN += 1
        pos += a.length
        continue
      pos += 1
  echo &"SS claimable: {totalSS} B in {ssClaims.len} spans ({ssN} streams)"
  echo &"AS claimable: {totalAS} B in {asClaims.len} spans ({asN} walks)"
  ssClaims.sort(proc(x,y:(int,int)):int = cmp(y[1], x[1]))
  asClaims.sort(proc(x,y:(int,int)):int = cmp(y[1], x[1]))
  echo "top SS:"
  for i in 0 .. min(15, ssClaims.high):
    echo &"  0x{ssClaims[i][0]:06X}+{ssClaims[i][1]}"
  echo "top AS:"
  for i in 0 .. min(15, asClaims.high):
    echo &"  0x{asClaims[i][0]:06X}+{asClaims[i][1]}"

  # C59400 anim residual walk experiment
  echo "\n===== anim stream walk experiment @0x05980E ====="
  block:
    let start = 0x05980E
    let lim = start + 141
    var pos = start
    var ok = true
    while pos < lim and ok:
      let op = g[pos]
      case op
      of 0x04:
        if pos + 3 > lim: break
        pos += 3
      of 0x05:
        if pos + 3 > lim: break
        pos += 3
      of 0x18:
        if pos + 1 >= lim: break
        if g[pos+1] == 0x07:
          # fixed 13-byte form seen in stream
          if pos + 13 > lim: break
          pos += 13
        else:
          echo &"  unknown 18 {g[pos+1]:02X} at +{pos-start}"
          ok = false
      of 0x02:
        # seen near end: 02 70 ...
        echo &"  hit 02 at +{pos-start}, stop (maybe term)"
        break
      else:
        echo &"  unknown {op:02X} at +{pos-start}"
        ok = false
    echo &"  walked to +{pos-start} of {141} ok={ok}"

main()
