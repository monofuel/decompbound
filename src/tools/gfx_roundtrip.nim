## Driver to verify the gfx_lz codec round-trips on real ROM graphics and
## synthetic cases. Covers the docs/graphics.md cited stream and the battle-BG
## CHR far-pointer table at $CAD9A1 (file 0x0AD9A1).
## Run: nix develop -c nim r src/tools/gfx_roundtrip.nim
## Exit 0 with match counts; no asset dumps written.

import
  std/[os, sequtils, strformat, strutils],
  ../decompbound/gfx_lz

const
  GoldRom = "bin/Earthbound (U) [!].smc"
  RomEnvVar = "DECOMPBOUND_ROM"
  GfxCompressedOff = 0x214EE0
  ExpectedDecodedLen = 1179
  ExpectedPrefix: array[8, uint8] = [0x0C'u8, 0x0D, 0x0E, 0x0F, 0x00, 0x00, 0x00, 0x00]
  # Battle-BG compressed graphics far-pointer table (SNES $CAD9A1).
  GfxPtrTableFile = 0x0AD9A1
  FileOffsetMask = 0x3FFFFF
  BattleBgGfxCount = 103
  DecodeWindow = 0x10000

proc resolveRomPath(): string =
  ## Prefer DECOMPBOUND_ROM, else the default gold path under bin/.
  result = getEnv(RomEnvVar)
  if result.len == 0:
    result = GoldRom

proc readRom(path: string): seq[uint8] =
  ## Read ROM file into byte seq, stripping a 512-byte copier header if present.
  if not fileExists(path):
    stderr.writeLine &"ROM not found: {path}"
    quit(1)
  let s = readFile(path)
  var start = 0
  if s.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](s.len - start)
  for i in 0..<result.len:
    result[i] = uint8(s[start + i])

proc loadCompressedWindow(rom: seq[uint8], off: int): seq[uint8] =
  ## Slice a decode window. Do not scan for 0xFF: it appears as data mid-stream.
  if off < 0 or off >= rom.len:
    return @[]
  let hi = min(off + DecodeWindow, rom.len)
  rom[off ..< hi]

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

proc main() =
  echo "gfx_lz roundtrip verification"
  echo "=============================="

  let romPath = resolveRomPath()
  let rom = readRom(romPath)
  echo &"rom: {romPath} ({rom.len} bytes)"

  # real graphic from ROM at cited offset (docs/graphics.md)
  let comp = loadCompressedWindow(rom, GfxCompressedOff)
  echo &"cited stream window at 0x{GfxCompressedOff:06X}: {comp.len} bytes"

  let decoded = decode(comp)
  echo &"decode(0x214EE0) -> {decoded.len} bytes"
  var leadStr = ""
  for i in 0..<8:
    if i > 0: leadStr.add(" ")
    leadStr.add(decoded[i].toHex(2))
  echo &"leading bytes: {leadStr}"
  doAssert decoded.len == ExpectedDecodedLen, "decoded len mismatch"
  for i in 0..<8:
    doAssert decoded[i] == ExpectedPrefix[i], &"prefix byte {i} mismatch"
  echo "decode sizes + prefix: PASS"

  # roundtrip the decoded via our encoder (lossless on raw, not bit-identical pack)
  let reEncoded = encode(decoded)
  echo &"encode(decoded) -> {reEncoded.len} bytes"
  let reDecoded = decode(reEncoded)
  echo &"decode(encode(decoded)) -> {reDecoded.len} bytes"
  let rtOk = reDecoded == decoded
  echo &"full roundtrip decode(encode(decode(rom))) == decode(rom): {rtOk}"
  doAssert rtOk, "ROM graphic roundtrip failed"
  echo "cited graphic roundtrip: PASS"

  # battle-BG layer CHR via $CAD9A1 far-ptr table
  echo ""
  echo &"battle-BG gfx table $CAD9A1 (file 0x{GfxPtrTableFile:06X}), {BattleBgGfxCount} entries:"
  var battleMatches = 0
  var battleEmpty = 0
  var battleBadPtr = 0
  for gi in 0..<BattleBgGfxCount:
    let foff = farPtrFileOff(rom, GfxPtrTableFile, gi)
    if foff < 0 or foff >= rom.len:
      battleBadPtr += 1
      continue
    let window = loadCompressedWindow(rom, foff)
    let d = decode(window)
    if d.len == 0:
      battleEmpty += 1
      continue
    let again = decode(encode(d))
    doAssert again == d, &"battle-BG gfx idx {gi} roundtrip failed (decoded={d.len})"
    battleMatches += 1
    if gi < 5 or gi mod 25 == 0:
      echo &"  idx {gi}: file=0x{foff:06X} decoded={d.len} ROUNDTRIP=PASS"
  echo &"  matches={battleMatches} empty={battleEmpty} bad_ptr={battleBadPtr}"
  doAssert battleMatches >= 18,
    &"expected at least 18 battle-BG gfx matches, got {battleMatches}"
  echo "battle-BG gfx table roundtrip: PASS"

  # fuzz synthetic cases for arbitrary input roundtrip
  echo ""
  echo "fuzz decode(encode(x)) == x :"

  proc testCase(name: string, data: seq[uint8]) =
    let e = encode(data)
    let d = decode(e)
    let ok = d == data
    echo &"  {name}: raw={data.len} enc={e.len} rt={ok}"
    doAssert ok, &"fuzz {name} failed"

  testCase("empty", @[])
  testCase("single", @[0xABu8])
  testCase("lit_run4", @[0x01u8, 0x02, 0x03, 0x04])
  testCase("rle8_100", newSeqWith(100, 0x7Fu8))
  testCase("rle16_20pairs", block:
    var d: seq[uint8] = @[]
    for i in 0..<20:
      d.add(0x12u8); d.add(0x34u8)
    d
  )
  testCase("incseq_60", block:
    var d: seq[uint8] = @[]
    for i in 0..<60: d.add( uint8( (0xA0 + i) and 0xFF ) )
    d
  )
  testCase("backref_block", block:
    let pat = @[0xDEu8, 0xAD, 0xBE, 0xEF]
    var d: seq[uint8] = @[]
    for _ in 0..<8: d.add(pat)
    d
  )
  testCase("mixed", @[0x00u8,0x00,0x00, 0x10,0x11,0x12,0x13, 0xAA,0xBB,0xAA,0xBB, 0xFF])
  testCase("long_rle", newSeqWith(300, 0x55u8))

  echo ""
  echo &"ALL PASS: cited graphic + battle-BG matches={battleMatches} + fuzz."

when isMainModule:
  main()
