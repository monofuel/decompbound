## Graphics LZ/RLE codec matching the EarthBound decompressor at file 0x041AC1.
## decode expands the command stream exactly per the spec in docs/graphics.md.
## encode produces a valid stream such that decode(encode(raw)) == raw for any input.
## Backrefs are relative to start of the output buffer (as the game's $CF base + BE offset).

const
  TerminateByte = 0xFFu8
  ShortLenMask = 0x1F
  LongMarker = 0xE0u8
  LongLenHighMask = 0x03
  BackrefBase = 0
  MaxBackrefLen = 1024
  MaxRunLen = 1024

proc decode*(compressed: openArray[uint8]): seq[uint8] =
  ## Decode a graphics LZ/RLE stream per the EarthBound 0x041AC1 routine spec.
  ## Command byte: short cmd=byte>>5, len=(byte&0x1F)+1; long when byte&0xE0==0xE0
  ## -> cmd=(byte>>2)&7, len=((byte&3)<<8|next)+1. 0xFF terminates.
  ## Commands: 0=literal, 1=8bit RLE, 2=16bit RLE, 3=inc seq, 4/7=backref forward,
  ## 5=bitrev backref, 6=reverse backref.
  var i = 0
  while i < compressed.len:
    let b = compressed[i]
    i += 1
    if b == TerminateByte:
      break
    var cmd: uint8
    var ln: int
    if (b and LongMarker) == LongMarker:
      cmd = (b shr 2) and 7
      if i >= compressed.len:
        break
      let lenHigh = int(b and LongLenHighMask)
      let lenLow = int(compressed[i])
      i += 1
      ln = ((lenHigh shl 8) or lenLow) + 1
    else:
      cmd = b shr 5
      ln = int(b and ShortLenMask) + 1
    case cmd
    of 0:
      for _ in 0..<ln:
        if i >= compressed.len:
          break
        result.add(compressed[i])
        i += 1
    of 1:
      if i >= compressed.len:
        break
      let v = compressed[i]
      i += 1
      for _ in 0..<ln:
        result.add(v)
    of 2:
      if i + 1 >= compressed.len:
        break
      let v0 = compressed[i]
      let v1 = compressed[i + 1]
      i += 2
      for _ in 0..<ln:
        result.add(v0)
        result.add(v1)
    of 3:
      if i >= compressed.len:
        break
      var v = compressed[i]
      i += 1
      for _ in 0..<ln:
        result.add(v)
        v = (v + 1u8) and 0xFFu8
    of 4, 7:
      if i + 1 >= compressed.len:
        break
      let off = (int(compressed[i]) shl 8) or int(compressed[i + 1])
      i += 2
      for k in 0..<ln:
        let sidx = BackrefBase + off + k
        if sidx >= 0 and sidx < result.len:
          result.add(result[sidx])
        else:
          result.add(0u8)
    of 5:
      if i + 1 >= compressed.len:
        break
      let off = (int(compressed[i]) shl 8) or int(compressed[i + 1])
      i += 2
      for k in 0..<ln:
        let sidx = BackrefBase + off + k
        if sidx >= 0 and sidx < result.len:
          var v = result[sidx]
          var r = 0u8
          for _ in 0..<8:
            r = (r shl 1) or (v and 1u8)
            v = v shr 1
          result.add(r)
        else:
          result.add(0u8)
    of 6:
      if i + 1 >= compressed.len:
        break
      let off = (int(compressed[i]) shl 8) or int(compressed[i + 1])
      i += 2
      for k in 0..<ln:
        let sidx = BackrefBase + off - k
        if sidx >= 0 and sidx < result.len:
          result.add(result[sidx])
        else:
          result.add(0u8)
    else:
      discard

proc emitLiteral(res: var seq[uint8], data: openArray[uint8]) =
  ## Emit a literal run using short or long form as needed.
  let ln = data.len
  if ln == 0:
    return
  let lm1 = ln - 1
  if lm1 <= ShortLenMask:
    res.add( (0u8 shl 5) or uint8(lm1) )
  else:
    let lh = (lm1 shr 8) and 3
    res.add( LongMarker or (0u8 shl 2) or uint8(lh) )
    res.add( uint8(lm1 and 0xFF) )
  for b in data:
    res.add(b)

proc emitRle8(res: var seq[uint8], v: uint8, ln: int) =
  ## Emit 8-bit RLE.
  if ln <= 0:
    return
  let lm1 = ln - 1
  if lm1 <= ShortLenMask:
    res.add( (1u8 shl 5) or uint8(lm1) )
  else:
    let lh = (lm1 shr 8) and 3
    res.add( LongMarker or (1u8 shl 2) or uint8(lh) )
    res.add( uint8(lm1 and 0xFF) )
  res.add(v)

proc emitRle16(res: var seq[uint8], v0: uint8, v1: uint8, ln: int) =
  ## Emit 16-bit RLE (pair repeated ln times).
  if ln <= 0:
    return
  let pairs = ln div 2
  if pairs <= 0:
    return
  let lm1 = pairs - 1
  if lm1 <= ShortLenMask:
    res.add( (2u8 shl 5) or uint8(lm1) )
  else:
    let lh = (lm1 shr 8) and 3
    res.add( LongMarker or (2u8 shl 2) or uint8(lh) )
    res.add( uint8(lm1 and 0xFF) )
  res.add(v0)
  res.add(v1)

proc emitInc(res: var seq[uint8], base: uint8, ln: int) =
  ## Emit increasing sequence.
  if ln <= 0:
    return
  let lm1 = ln - 1
  if lm1 <= ShortLenMask:
    res.add( (3u8 shl 5) or uint8(lm1) )
  else:
    let lh = (lm1 shr 8) and 3
    res.add( LongMarker or (3u8 shl 2) or uint8(lh) )
    res.add( uint8(lm1 and 0xFF) )
  res.add(base)

proc emitBackref(res: var seq[uint8], off: int, ln: int) =
  ## Emit forward backref (cmd 4 or 7, treated same).
  if ln <= 0 or off < 0:
    return
  let lm1 = ln - 1
  # always long form for backrefs
  let lh = (lm1 shr 8) and 3
  res.add( LongMarker or (4u8 shl 2) or uint8(lh) )
  res.add( uint8(lm1 and 0xFF) )
  res.add( uint8((off shr 8) and 0xFF) )
  res.add( uint8(off and 0xFF) )

proc encode*(raw: openArray[uint8]): seq[uint8] =
  ## Encode raw bytes into a gfx_lz command stream.
  ## Guarantees decode(encode(raw)) == raw. Greedy longest-match selection
  ## among literal, 8/16 RLE, inc-seq, and forward backref. Does not need to
  ## reproduce the game's exact choices.
  var p = 0
  while p < raw.len:
    var bestLen = 1
    var bestCmd: uint8 = 0
    var bestExtra: seq[uint8] = @[raw[p]]
    var useLit = true
    # 8-bit RLE
    var r8 = 1
    while p + r8 < raw.len and raw[p + r8] == raw[p] and r8 < MaxRunLen:
      r8 += 1
    if r8 > bestLen:
      bestLen = r8
      bestCmd = 1
      bestExtra = @[raw[p]]
      useLit = false
    # 16-bit RLE
    if p + 1 < raw.len:
      let va = raw[p]
      let vb = raw[p + 1]
      var r16 = 1
      while p + r16 * 2 + 1 < raw.len and raw[p + r16 * 2] == va and raw[p + r16 * 2 + 1] == vb and r16 < MaxRunLen div 2:
        r16 += 1
      let adv = r16 * 2
      if adv > bestLen:
        bestLen = adv
        bestCmd = 2
        bestExtra = @[va, vb]
        useLit = false
    # inc sequence
    var ri = 1
    var expect = (int(raw[p]) + 1) and 0xFF
    while p + ri < raw.len and int(raw[p + ri]) == expect and ri < MaxRunLen:
      ri += 1
      expect = (expect + 1) and 0xFF
    if ri > bestLen:
      bestLen = ri
      bestCmd = 3
      bestExtra = @[raw[p]]
      useLit = false
    # backref (forward from prior in output)
    var bestOff = -1
    var bestBl = 1
    for po in 0..<p:
      var ml = 0
      while p + ml < raw.len and po + ml < p and raw[po + ml] == raw[p + ml] and ml < MaxBackrefLen:
        ml += 1
      if ml > bestBl:
        bestBl = ml
        bestOff = po
    if bestBl > bestLen and bestOff >= 0:
      bestLen = bestBl
      bestCmd = 4
      bestExtra = @[ uint8((bestOff shr 8) and 0xFF), uint8(bestOff and 0xFF) ]
      useLit = false
    # emit
    if useLit or bestCmd == 0:
      var lit: seq[uint8] = @[]
      for k in 0..<bestLen:
        lit.add(raw[p + k])
      emitLiteral(result, lit)
    elif bestCmd == 1:
      emitRle8(result, bestExtra[0], bestLen)
    elif bestCmd == 2:
      emitRle16(result, bestExtra[0], bestExtra[1], bestLen)
    elif bestCmd == 3:
      emitInc(result, bestExtra[0], bestLen)
    else:
      # backref 4/7
      let off = (int(bestExtra[0]) shl 8) or int(bestExtra[1])
      emitBackref(result, off, bestLen)
    p += bestLen
  result.add(TerminateByte)

proc roundtrip*(data: openArray[uint8]): bool =
  ## Helper: returns true if decode(encode(data)) == data exactly.
  decode(encode(data)) == @data

proc decodeWithConsumed*(compressed: openArray[uint8]): tuple[data: seq[uint8], consumed: int, clean: bool] =
  ## Decode like `decode`, also reporting how many input bytes were consumed.
  ## `clean` is true when the stream ended on the 0xFF terminator without
  ## running out of input mid-command (well-defined stream length = consumed).
  var i = 0
  var decoded: seq[uint8] = @[]
  while i < compressed.len:
    let b = compressed[i]
    i += 1
    if b == TerminateByte:
      return (decoded, i, true)
    var cmd: uint8
    var ln: int
    if (b and LongMarker) == LongMarker:
      cmd = (b shr 2) and 7
      if i >= compressed.len:
        return (decoded, i, false)
      let lenHigh = int(b and LongLenHighMask)
      let lenLow = int(compressed[i])
      i += 1
      ln = ((lenHigh shl 8) or lenLow) + 1
    else:
      cmd = b shr 5
      ln = int(b and ShortLenMask) + 1
    case cmd
    of 0:
      for _ in 0..<ln:
        if i >= compressed.len:
          return (decoded, i, false)
        decoded.add(compressed[i])
        i += 1
    of 1:
      if i >= compressed.len:
        return (decoded, i, false)
      let v = compressed[i]
      i += 1
      for _ in 0..<ln:
        decoded.add(v)
    of 2:
      if i + 1 >= compressed.len:
        return (decoded, i, false)
      let v0 = compressed[i]
      let v1 = compressed[i + 1]
      i += 2
      for _ in 0..<ln:
        decoded.add(v0)
        decoded.add(v1)
    of 3:
      if i >= compressed.len:
        return (decoded, i, false)
      var v = compressed[i]
      i += 1
      for _ in 0..<ln:
        decoded.add(v)
        v = (v + 1u8) and 0xFFu8
    of 4, 7:
      if i + 1 >= compressed.len:
        return (decoded, i, false)
      let off = (int(compressed[i]) shl 8) or int(compressed[i + 1])
      i += 2
      for k in 0..<ln:
        let sidx = BackrefBase + off + k
        if sidx >= 0 and sidx < decoded.len:
          decoded.add(decoded[sidx])
        else:
          decoded.add(0u8)
    of 5:
      if i + 1 >= compressed.len:
        return (decoded, i, false)
      let off = (int(compressed[i]) shl 8) or int(compressed[i + 1])
      i += 2
      for k in 0..<ln:
        let sidx = BackrefBase + off + k
        if sidx >= 0 and sidx < decoded.len:
          var v = decoded[sidx]
          var r = 0u8
          for _ in 0..<8:
            r = (r shl 1) or (v and 1u8)
            v = v shr 1
          decoded.add(r)
        else:
          decoded.add(0u8)
    of 6:
      if i + 1 >= compressed.len:
        return (decoded, i, false)
      let off = (int(compressed[i]) shl 8) or int(compressed[i + 1])
      i += 2
      for k in 0..<ln:
        let sidx = BackrefBase + off - k
        if sidx >= 0 and sidx < decoded.len:
          decoded.add(decoded[sidx])
        else:
          decoded.add(0u8)
    else:
      discard
  (decoded, i, false)
