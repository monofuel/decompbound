## Unit tests for the graphics LZ/RLE codec (gfx_lz).
## Synthetic cases always run. Battle-BG layer CHR via the $CAD9A1 far-ptr
## table is verified when the gold ROM is present; otherwise that block is
## skipped cleanly (CI has no copyrighted ROM).

import
  std/[os, sequtils, strformat],
  decompbound/gfx_lz

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  # Alternate path via env for local layouts.
  RomEnvVar = "DECOMPBOUND_ROM"
  # Battle-BG compressed graphics far-pointer table (SNES $CAD9A1).
  GfxPtrTableFile = 0x0AD9A1
  FileOffsetMask = 0x3FFFFF
  # Community catalog is ~103 graphics; table entries are 4 bytes each.
  BattleBgGfxCount = 103
  DecodeWindow = 0x10000
  # Classic cited graphic from docs/graphics.md (not battle-BG, extra smoke).
  CitedGfxFileOff = 0x214EE0
  CitedDecodedLen = 1179

proc resolveRomPath(): string =
  ## Prefer DECOMPBOUND_ROM, else the gold master path under bin/.
  result = getEnv(RomEnvVar)
  if result.len == 0:
    result = GoldMasterRom

proc readRomBytes(path: string): seq[uint8] =
  ## Load ROM bytes, stripping a 512-byte copier header when present.
  let data = readFile(path)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc loadCompressedWindow(rom: seq[uint8], fileOff: int): seq[uint8] =
  ## Slice a decode window from the ROM at a file offset.
  ## 0xFF can appear as stream data, so callers must not scan for terminator.
  if fileOff < 0 or fileOff >= rom.len:
    return @[]
  let hi = min(fileOff + DecodeWindow, rom.len)
  rom[fileOff ..< hi]

proc farPtrFileOff(rom: seq[uint8], tableOff: int, index: int): int =
  ## Read a 3-byte LE SNES far pointer from a 4-byte table entry and map to file.
  let poff = tableOff + index * 4
  if poff + 2 >= rom.len:
    return -1
  let snes =
    int(rom[poff + 0]) or
    (int(rom[poff + 1]) shl 8) or
    (int(rom[poff + 2]) shl 16)
  if snes == 0:
    return -1
  snes and FileOffsetMask

block syntheticRoundtrip:
  ## decode(encode(x)) == x for synthetic inputs (no ROM required).
  doAssert roundtrip(@[])
  doAssert roundtrip(@[0xABu8])
  doAssert roundtrip(@[0x01u8, 0x02, 0x03, 0x04])
  doAssert roundtrip(newSeqWith(100, 0x7Fu8))
  block rle16:
    var d: seq[uint8] = @[]
    for _ in 0..<20:
      d.add(0x12u8)
      d.add(0x34u8)
    doAssert roundtrip(d)
  block incSeq:
    var d: seq[uint8] = @[]
    for i in 0..<60:
      d.add(uint8((0xA0 + i) and 0xFF))
    doAssert roundtrip(d)
  block backref:
    let pat = @[0xDEu8, 0xAD, 0xBE, 0xEF]
    var d: seq[uint8] = @[]
    for _ in 0..<8:
      d.add(pat)
    doAssert roundtrip(d)
  doAssert roundtrip(@[0x00u8, 0x00, 0x00, 0x10, 0x11, 0x12, 0x13,
                       0xAA, 0xBB, 0xAA, 0xBB, 0xFF])
  doAssert roundtrip(newSeqWith(300, 0x55u8))

block battleBgGfxRoundtrip:
  ## Load each battle-BG compressed graphic via $CAD9A1 and prove
  ## decode(encode(decode(stream))) == decode(stream).
  let romPath = resolveRomPath()
  if not fileExists(romPath):
    # CI / clean checkouts: no copyrighted ROM. Synthetic block already ran.
    discard
  else:
    let rom = readRomBytes(romPath)
    var matchCount = 0
    var nonEmpty = 0
    for gi in 0..<BattleBgGfxCount:
      let foff = farPtrFileOff(rom, GfxPtrTableFile, gi)
      if foff < 0 or foff >= rom.len:
        continue
      let window = loadCompressedWindow(rom, foff)
      if window.len == 0:
        continue
      let decoded = decode(window)
      if decoded.len == 0:
        continue
      nonEmpty += 1
      let reEncoded = encode(decoded)
      let reDecoded = decode(reEncoded)
      doAssert reDecoded == decoded,
        &"battle-BG gfx idx {gi} roundtrip failed (decoded={decoded.len})"
      doAssert roundtrip(decoded),
        &"battle-BG gfx idx {gi} roundtrip helper failed"
      matchCount += 1
    doAssert nonEmpty > 0, "no non-empty battle-BG gfx streams found"
    doAssert matchCount == nonEmpty
    doAssert matchCount >= 18,
      &"expected at least explorer GfxPtrCount=18 matches, got {matchCount}"

block citedGraphicSmoke:
  ## Extra smoke on the docs/graphics.md cited stream when ROM is present.
  let romPath = resolveRomPath()
  if fileExists(romPath):
    let rom = readRomBytes(romPath)
    let window = loadCompressedWindow(rom, CitedGfxFileOff)
    let decoded = decode(window)
    doAssert decoded.len == CitedDecodedLen
    doAssert decoded[0] == 0x0C and decoded[1] == 0x0D
    doAssert roundtrip(decoded)
