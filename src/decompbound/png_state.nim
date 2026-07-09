## PNG ancillary chunk embed/extract for state screenshots ("ebSt").
## Embeds a compressed save-state inside a PNG so the image carries the
## exact emulator state that produced it. The chunk is ancillary (ignored
## by normal viewers) and the PNG remains a valid 256x224 picture.
##
## State bytes come from save_state.serializeState (single path).
## Uses zippy for raw deflate (dfDeflate) + its crc32 for the chunk CRC.
## All outputs (embedded PNGs, states) are user-local and git-ignored.

import
  std/[options],
  zippy,
  zippy/crc,
  ./save_state

const
  EbStType = ['e'.uint8, 'b'.uint8, 'S'.uint8, 't'.uint8]
  EbSsMagic = ['E'.uint8, 'B'.uint8, 'S'.uint8, 'S'.uint8]
  PngSigLen = 8

proc readU32be(data: seq[uint8], off: int): uint32 =
  ## Read big-endian u32 (for PNG chunk length/CRC).
  (data[off].uint32 shl 24) or
  (data[off + 1].uint32 shl 16) or
  (data[off + 2].uint32 shl 8) or
  data[off + 3].uint32

proc readU32le(data: seq[uint8], off: int): uint32 =
  ## Read little-endian u32 (inside ebSt payload).
  data[off].uint32 or
  (data[off + 1].uint32 shl 8) or
  (data[off + 2].uint32 shl 16) or
  (data[off + 3].uint32 shl 24)

proc readU16le(data: seq[uint8], off: int): uint16 =
  ## Read little-endian u16 (version inside ebSt).
  data[off].uint16 or (data[off + 1].uint16 shl 8)

proc makeChunk(typ: array[4, uint8], data: seq[uint8]): seq[uint8] =
  ## Build a well-formed PNG chunk: length(BE) + type + data + crc32(BE).
  ## CRC is over (type || data) using zippy's crc32 (standard poly).
  let dlen = data.len.uint32
  var chunk = newSeq[uint8](4 + 4 + data.len + 4)
  # length big-endian
  chunk[0] = ((dlen shr 24) and 0xFF).uint8
  chunk[1] = ((dlen shr 16) and 0xFF).uint8
  chunk[2] = ((dlen shr 8) and 0xFF).uint8
  chunk[3] = (dlen and 0xFF).uint8
  # type
  chunk[4] = typ[0]; chunk[5] = typ[1]; chunk[6] = typ[2]; chunk[7] = typ[3]
  # data
  if data.len > 0:
    copyMem(addr chunk[8], unsafeAddr data[0], data.len)
  # CRC over type+data (big-endian storage)
  let crc = if (4 + data.len) > 0:
              crc32(addr chunk[4], 4 + data.len)
            else:
              0'u32
  let crcOff = 8 + data.len
  chunk[crcOff + 0] = ((crc shr 24) and 0xFF).uint8
  chunk[crcOff + 1] = ((crc shr 16) and 0xFF).uint8
  chunk[crcOff + 2] = ((crc shr 8) and 0xFF).uint8
  chunk[crcOff + 3] = (crc and 0xFF).uint8
  chunk

proc makeEbStData(state: seq[uint8], romHash: uint32): seq[uint8] =
  ## Build the inner data for ebSt chunk per design:
  ## "EBSS" + version(u16 LE) + romHash(u32 LE) + rawLen(u32 LE) + deflate(state)
  var header: seq[uint8] = @[]
  header.add(EbSsMagic)
  let ver = StateVersion.uint16
  header.add( (ver and 0xFF).uint8 )
  header.add( ((ver shr 8) and 0xFF).uint8 )
  header.add( (romHash and 0xFF).uint8 )
  header.add( ((romHash shr 8) and 0xFF).uint8 )
  header.add( ((romHash shr 16) and 0xFF).uint8 )
  header.add( ((romHash shr 24) and 0xFF).uint8 )
  let rlen = state.len.uint32
  header.add( (rlen and 0xFF).uint8 )
  header.add( ((rlen shr 8) and 0xFF).uint8 )
  header.add( ((rlen shr 16) and 0xFF).uint8 )
  header.add( ((rlen shr 24) and 0xFF).uint8 )
  let compressed =
    if state.len == 0:
      newSeq[uint8]()
    else:
      compress(state, DefaultCompression, dfDeflate)
  header & compressed

proc findIendPos(png: seq[uint8]): int =
  ## Return byte offset of the IEND chunk's length field, or -1.
  if png.len < PngSigLen + 12:
    return -1
  var pos = PngSigLen
  while pos + 12 <= png.len:
    let clen = readU32be(png, pos)
    if pos + 8 + clen.int + 4 > png.len:
      break
    let t0 = png[pos + 4]
    let t1 = png[pos + 5]
    let t2 = png[pos + 6]
    let t3 = png[pos + 7]
    if t0 == 'I'.uint8 and t1 == 'E'.uint8 and t2 == 'N'.uint8 and t3 == 'D'.uint8:
      return pos
    pos += 8 + clen.int + 4
  -1

proc embedState*(png: seq[uint8], state: seq[uint8], romHash: uint32): seq[uint8] =
  ## Inject a private ancillary "ebSt" chunk immediately before IEND.
  ## Chunk layout (inside data): EBSS + u16LE ver + u32LE romHash + u32LE rawLen + deflate(state)
  ## The returned PNG is still a valid image (chunk is ancillary/safe-to-copy).
  let chunkData = makeEbStData(state, romHash)
  let ebChunk = makeChunk(EbStType, chunkData)
  let iendPos = findIendPos(png)
  if iendPos >= 0:
    png[0 ..< iendPos] & ebChunk & png[iendPos .. ^1]
  else:
    # Input lacked IEND (unusual for pixie output); append chunk at end
    # so caller can still round-trip the state even if PNG is odd.
    png & ebChunk

proc extractState*(png: seq[uint8]): Option[seq[uint8]] =
  ## Walk PNG chunks looking for "ebSt". Validate inner "EBSS" magic + version
  ## (u16 matches StateVersion), read rawLen, uncompress the deflate payload.
  ## Returns the raw state bytes or none on missing chunk / any validation fail.
  ## NEVER raises on a normal PNG that simply lacks the chunk.
  if png.len < PngSigLen + 12:
    return none(seq[uint8])
  var pos = PngSigLen
  while pos + 12 <= png.len:
    let clen = readU32be(png, pos)
    if pos + 8 + clen.int + 4 > png.len:
      break
    let t0 = png[pos + 4]
    let t1 = png[pos + 5]
    let t2 = png[pos + 6]
    let t3 = png[pos + 7]
    if t0 == 'e'.uint8 and t1 == 'b'.uint8 and t2 == 'S'.uint8 and t3 == 't'.uint8:
      # found ebSt
      let dataStart = pos + 8
      let dataEnd = dataStart + clen.int
      if dataEnd > png.len:
        return none(seq[uint8])
      let d = png[dataStart ..< dataEnd]
      if d.len < 14 or d[0..3] != EbSsMagic:
        return none(seq[uint8])
      let ver = readU16le(d, 4)
      # Accept state versions the deserializer understands (v1 hang-prone
      # blobs still load; recoverTimers runs inside readState for v1).
      if ver.uint32 < StateVersionMin or ver.uint32 > StateVersion:
        return none(seq[uint8])
      # romHash at 6, we ignore for extract (caller verifies if wanted)
      let rawLen = readU32le(d, 10)
      let compStart = 14
      if compStart > d.len:
        if rawLen == 0'u32:
          return some(newSeq[uint8]())
        return none(seq[uint8])
      let compPayload = d[compStart .. ^1]
      try:
        let unc =
          if compPayload.len == 0:
            newSeq[uint8]()
          else:
            uncompress(compPayload, dfDeflate)
        if unc.len.uint32 != rawLen:
          return none(seq[uint8])
        var outState = newSeq[uint8](unc.len)
        if outState.len > 0:
          copyMem(addr outState[0], unsafeAddr unc[0], outState.len)
        return some(outState)
      except:
        return none(seq[uint8])
    pos += 8 + clen.int + 4
  none(seq[uint8])

proc romHashOf*(rom: seq[uint8]): uint32 =
  ## Simple stable hash of the ROM bytes (for tagging/verifying state screenshots).
  ## Uses zippy crc32 so it is fast and deterministic across runs.
  if rom.len == 0:
    return 0'u32
  crc32(addr rom[0], rom.len)