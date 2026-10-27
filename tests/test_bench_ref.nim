## Tests for the DBREF1 bench golden format (serialize/parse round-trip and
## row comparison). ROM-free.

import
  std/[os, strutils],
  decompbound/bench_ref

const
  TmpRef = "tests/tmp/test_bench_ref.ref"

proc sampleRef(): BenchRef =
  ## A small synthetic golden with three rows.
  BenchRef(
    tape: "20260101-000000.tas",
    tapeCrc: 0xCAFEBABE'u32,
    romHash: 0xDC9BB451'u32,
    frames: 180,
    hashEvery: 1,
    build: "abc123+dirty",
    rows: @[
      BenchRow(frame: 59, image: 0x11111111'u32, audio: 0x22222222'u32, wram: 0x33333333'u32),
      BenchRow(frame: 119, image: 0x44444444'u32, audio: 0x55555555'u32, wram: 0x66666666'u32),
      BenchRow(frame: 179, image: 0x77777777'u32, audio: 0x88888888'u32, wram: 0x99999999'u32)])

proc assertRefsEqual(a, b: BenchRef) =
  ## Field-by-field equality with a useful failure message.
  doAssert a.tape == b.tape, a.tape & " vs " & b.tape
  doAssert a.tapeCrc == b.tapeCrc
  doAssert a.romHash == b.romHash
  doAssert a.frames == b.frames
  doAssert a.hashEvery == b.hashEvery
  doAssert a.build == b.build, a.build & " vs " & b.build
  doAssert a.rows.len == b.rows.len, $a.rows.len & " vs " & $b.rows.len
  for i in 0 ..< a.rows.len:
    doAssert compareRow(a.rows[i], b.rows[i]).len == 0, "row " & $i & " differs"

block serializeParseRoundTrip:
  let r = sampleRef()
  let text = serializeBenchRef(r)
  doAssert text.startsWith(BenchRefMagic & "\n")
  doAssert "tape_crc 0xcafebabe" in text
  assertRefsEqual(r, parseBenchRefString(text))

block fileRoundTrip:
  createDir("tests/tmp")
  let r = sampleRef()
  writeBenchRef(TmpRef, r)
  assertRefsEqual(r, parseBenchRef(TmpRef))
  removeFile(TmpRef)

block compareRowNamesFields:
  let want = BenchRow(frame: 59, image: 1, audio: 2, wram: 3)
  doAssert compareRow(want, want).len == 0
  doAssert compareRow(want, BenchRow(frame: 59, image: 9, audio: 2, wram: 3)) == @["image"]
  doAssert compareRow(want, BenchRow(frame: 59, image: 1, audio: 9, wram: 9)) == @["audio", "wram"]
  doAssert compareRow(want, BenchRow(frame: 60, image: 1, audio: 2, wram: 3)) == @["frame"]

block foldIsDeterministicAndOrderSensitive:
  let a = foldHash(foldHash(HashSeed, 1), 2)
  let b = foldHash(foldHash(HashSeed, 1), 2)
  let c = foldHash(foldHash(HashSeed, 2), 1)
  doAssert a == b
  doAssert a != c

block badMagicRaises:
  var raised = false
  try:
    discard parseBenchRefString("DBTAS1\n0 0 0 0\n")
  except ValueError:
    raised = true
  doAssert raised

block describeMentionsFields:
  let m = RefMismatch(frame: 119, fields: @["audio"],
    want: BenchRow(frame: 119, audio: 5), got: BenchRow(frame: 119, audio: 6))
  let s = describe(m)
  doAssert "frame 119" in s and "audio" in s
