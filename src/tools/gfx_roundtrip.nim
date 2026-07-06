## Driver to verify the gfx_lz codec round-trips byte-exact on the real ROM graphic
## and on synthetic cases. Definition of done for the graphics compression track.
## Run directly: nix develop -c nim r src/tools/gfx_roundtrip.nim

import
  std/[os, sequtils, strformat, strutils],
  ../decompbound/gfx_lz

const
  GoldRom = "bin/Earthbound (U) [!].smc"
  GfxCompressedOff = 0x214EE0
  ExpectedDecodedLen = 1179
  ExpectedPrefix: array[8, uint8] = [0x0C'u8, 0x0D, 0x0E, 0x0F, 0x00, 0x00, 0x00, 0x00]

proc readRom(path: string): seq[uint8] =
  ## Read ROM file into byte seq. This ROM has no copier header.
  if not fileExists(path):
    stderr.writeLine &"ROM not found: {path}"
    quit(1)
  let s = readFile(path)
  result = newSeq[uint8](s.len)
  for i in 0..<s.len:
    result[i] = uint8(s[i])

proc extractStream(rom: seq[uint8], off: int): seq[uint8] =
  ## Extract compressed stream from off until and including the 0xFF terminator.
  result = @[]
  var j = off
  while j < rom.len:
    let b = rom[j]
    result.add(b)
    j += 1
    if b == 0xFFu8:
      break

proc main() =
  echo "gfx_lz roundtrip verification"
  echo "=============================="

  # real graphic from ROM at cited offset
  let rom = readRom(GoldRom)
  let comp = extractStream(rom, GfxCompressedOff)
  echo &"compressed stream at 0x{GfxCompressedOff:06X}: {comp.len} bytes (incl term)"

  let decoded = decode(comp)
  echo &"decode(0x214EE0 stream) -> {decoded.len} bytes"
  var leadStr = ""
  for i in 0..<8:
    if i > 0: leadStr.add(" ")
    leadStr.add(decoded[i].toHex(2))
  echo &"leading bytes: {leadStr}"
  doAssert decoded.len == ExpectedDecodedLen, "decoded len mismatch"
  for i in 0..<8:
    doAssert decoded[i] == ExpectedPrefix[i], &"prefix byte {i} mismatch"
  echo "decode sizes + prefix: PASS"

  # roundtrip the decoded via our encoder
  let reEncoded = encode(decoded)
  echo &"encode(decoded) -> {reEncoded.len} bytes"
  let reDecoded = decode(reEncoded)
  echo &"decode(encode(decoded)) -> {reDecoded.len} bytes"
  let rtOk = reDecoded == decoded
  echo &"full roundtrip decode(encode(decode(rom))) == decode(rom): {rtOk}"
  doAssert rtOk, "ROM graphic roundtrip failed"
  echo "ROM graphic roundtrip: PASS"

  # also verify encode(decode(rom stream)) re-decodes identical
  let encDec = encode(decoded)
  let decAgain = decode(encDec)
  doAssert decAgain == decoded
  echo "encode(decode(rom)) re-decode equal: PASS"

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
  echo "ALL PASS: gfx codec roundtrips byte-exact on cited graphic and fuzz cases."

when isMainModule:
  main()
