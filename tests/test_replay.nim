## Tests for the DBTAS1 input-replay format (serialize/parse round-trip).
## Drives real procs in decompbound/replay — no format reimplementation here.

import
  std/[os, strutils, tables],
  decompbound/replay

const
  SyntheticRomHash = 0xDEADBEEF'u32
  SyntheticStartRef = "bin/replays/start.state"

proc assertHeadersEqual(a, b: ReplayHeader, label: string) =
  ## Compare header fields with a useful failure label.
  doAssert a.magic == b.magic, label & " magic: " & a.magic & " vs " & b.magic
  doAssert a.romHash == b.romHash,
    label & " romHash: 0x" & a.romHash.toHex(8) & " vs 0x" & b.romHash.toHex(8)
  doAssert a.startStateRef == b.startStateRef,
    label & " startStateRef: " & a.startStateRef & " vs " & b.startStateRef

proc assertDeltasEqual(a, b: seq[ReplayDelta], label: string) =
  ## Compare delta sequences field-by-field.
  doAssert a.len == b.len, label & " delta count: " & $a.len & " vs " & $b.len
  for i in 0 ..< a.len:
    doAssert a[i].frame == b[i].frame,
      label & " delta[" & $i & "].frame: " & $a[i].frame & " vs " & $b[i].frame
    doAssert a[i].joy1 == b[i].joy1,
      label & " delta[" & $i & "].joy1: 0x" & a[i].joy1.toHex(4) &
        " vs 0x" & b[i].joy1.toHex(4)

block serializeParseRoundTrip:
  # Tiny synthetic movie: neutral, Down, Right+A, release.
  let header = ReplayHeader(
    magic: ReplayMagic,
    romHash: SyntheticRomHash,
    startStateRef: SyntheticStartRef
  )
  let deltas = @[
    ReplayDelta(frame: 0, joy1: 0x0000'u16),
    ReplayDelta(frame: 12, joy1: 0x0400'u16),   # Down
    ReplayDelta(frame: 48, joy1: 0x0180'u16),   # Right | A (typical SNES bits)
    ReplayDelta(frame: 90, joy1: 0x0000'u16)
  ]

  let text = serializeReplay(header, deltas)
  doAssert text.startsWith(ReplayMagic & "\n"), "serialize must start with magic line"
  doAssert "rom_hash 0xDEADBEEF" in text
  doAssert "start_state " & SyntheticStartRef in text
  doAssert "0 0000" in text
  doAssert "12 0400" in text
  doAssert "48 0180" in text
  doAssert "90 0000" in text

  let (parsedHeader, parsedDeltas) = parseReplayString(text)
  assertHeadersEqual(header, parsedHeader, "string round-trip")
  assertDeltasEqual(deltas, parsedDeltas, "string round-trip")

  # Second hop: re-serialize parsed data and parse again (idempotent).
  let text2 = serializeReplay(parsedHeader, parsedDeltas)
  let (h2, d2) = parseReplayString(text2)
  assertHeadersEqual(header, h2, "double round-trip")
  assertDeltasEqual(deltas, d2, "double round-trip")
  doAssert text2 == text, "serialize must be stable across re-encode"

block fileWriteParseRoundTrip:
  # Exercise the live-recording File path (writeReplayHeader + appendReplayDelta)
  # then parseReplay from disk — same procs play.nim / tools/replay use.
  let path = getTempDir() / "decompbound_test_replay.tas"
  defer:
    if fileExists(path):
      removeFile(path)

  var f: File
  doAssert open(f, path, fmWrite), "open temp .tas for write"
  writeReplayHeader(f, SyntheticRomHash, SyntheticStartRef)
  appendReplayDelta(f, 0, 0x0000'u16)
  appendReplayDelta(f, 5, 0x0800'u16)   # Up
  appendReplayDelta(f, 20, 0x1000'u16)  # Start
  appendReplayDelta(f, 21, 0x0000'u16)
  f.close()

  let (header, deltas) = parseReplay(path)
  doAssert header.magic == ReplayMagic
  doAssert header.romHash == SyntheticRomHash
  doAssert header.startStateRef == SyntheticStartRef
  doAssert deltas.len == 4
  doAssert deltas[0] == ReplayDelta(frame: 0, joy1: 0x0000'u16)
  doAssert deltas[1] == ReplayDelta(frame: 5, joy1: 0x0800'u16)
  doAssert deltas[2] == ReplayDelta(frame: 20, joy1: 0x1000'u16)
  doAssert deltas[3] == ReplayDelta(frame: 21, joy1: 0x0000'u16)

  # File bytes must also parse via the string path and re-serialize cleanly.
  let diskText = readFile(path)
  let (sh, sd) = parseReplayString(diskText)
  assertHeadersEqual(header, sh, "disk vs string parse")
  assertDeltasEqual(deltas, sd, "disk vs string parse")
  let reserialized = serializeReplay(sh, sd)
  let (rh, rd) = parseReplayString(reserialized)
  assertHeadersEqual(header, rh, "disk re-serialize")
  assertDeltasEqual(deltas, rd, "disk re-serialize")

block joyTokenForms:
  # parseReplayString must accept 0x-prefixed and bare-hex joy tokens.
  let content = """
DBTAS1
rom_hash 0xABCDEF01
start_state slots/1
0 0x0400
10 0800
20 256
"""
  let (header, deltas) = parseReplayString(content)
  doAssert header.romHash == 0xABCDEF01'u32
  doAssert header.startStateRef == "slots/1"
  doAssert deltas.len == 3
  doAssert deltas[0].joy1 == 0x0400'u16
  doAssert deltas[1].joy1 == 0x0800'u16
  doAssert deltas[2].joy1 == 256'u16  # decimal when not 4-char hex

block deltasToTableAndHold:
  let deltas = @[
    ReplayDelta(frame: 0, joy1: 0x0000'u16),
    ReplayDelta(frame: 10, joy1: 0x0400'u16),
    ReplayDelta(frame: 20, joy1: 0x0000'u16)
  ]
  let tab = deltasToTable(deltas)
  doAssert tab[0] == 0x0000'u16
  doAssert tab[10] == 0x0400'u16
  doAssert tab[20] == 0x0000'u16
  doAssert joyAtFrame(deltas, 0) == 0x0000'u16
  doAssert joyAtFrame(deltas, 9) == 0x0000'u16
  doAssert joyAtFrame(deltas, 10) == 0x0400'u16
  doAssert joyAtFrame(deltas, 19) == 0x0400'u16
  doAssert joyAtFrame(deltas, 20) == 0x0000'u16
  doAssert joyAtFrame(deltas, 999) == 0x0000'u16

block missingFileRaises:
  var raised = false
  try:
    discard parseReplay(getTempDir() / "decompbound_no_such_replay.tas")
  except IOError:
    raised = true
  doAssert raised, "parseReplay must raise IOError for missing path"

block commentsAndBlanksIgnored:
  let content = """
DBTAS1
rom_hash 0x1
start_state x

# a comment between header and body
0 0000

# mid-movie note
3 0400
"""
  let (header, deltas) = parseReplayString(content)
  doAssert header.magic == ReplayMagic
  doAssert header.romHash == 1'u32
  doAssert deltas.len == 2
  doAssert deltas[1] == ReplayDelta(frame: 3, joy1: 0x0400'u16)
