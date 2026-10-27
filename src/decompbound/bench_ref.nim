## DBREF1: the golden file for bench_replay. One row per checkpoint interval
## holding running hashes of the rendered frames, the APU sample stream and the
## WRAM image. Hashes only, never game bytes, so refs are safe anywhere; they
## live beside their tape in decompbound_secret because they are meaningless
## without it.

import
  std/[strformat, strutils]

const
  BenchRefMagic* = "DBREF1"
  HashSeed* = 0x811c9dc5'u32
  HashPrime* = 0x01000193'u32

type
  BenchRow* = object
    frame*: int
    image*: uint32
    audio*: uint32
    wram*: uint32

  BenchRef* = object
    tape*: string
    tapeCrc*: uint32
    romHash*: uint32
    frames*: int
    hashEvery*: int
    build*: string
    rows*: seq[BenchRow]

  RefMismatch* = object
    frame*: int
    fields*: seq[string]
    want*: BenchRow
    got*: BenchRow

proc foldHash*(acc, h: uint32): uint32 {.inline.} =
  ## Mix one hash into a running hash (FNV-1a style fold of a 32-bit word).
  (acc xor h) * HashPrime

proc serializeBenchRef*(r: BenchRef): string =
  ## Render a ref as the DBREF1 text format.
  var lines: seq[string] = @[]
  lines.add(BenchRefMagic)
  lines.add(&"tape {r.tape}")
  lines.add(&"tape_crc 0x{r.tapeCrc:08x}")
  lines.add(&"rom_hash 0x{r.romHash:08x}")
  lines.add(&"frames {r.frames}")
  lines.add(&"hash_every {r.hashEvery}")
  if r.build.len > 0:
    lines.add(&"build {r.build}")
  lines.add("# frame image audio wram")
  for row in r.rows:
    lines.add(&"{row.frame} {row.image:08x} {row.audio:08x} {row.wram:08x}")
  lines.join("\n") & "\n"

proc parseHex32(s: string): uint32 =
  ## Parse a hex word with or without a 0x prefix.
  var t = s
  if t.startsWith("0x") or t.startsWith("0X"):
    t = t[2 .. ^1]
  parseHexInt(t).uint32

proc parseBenchRefString*(content: string): BenchRef =
  ## Parse DBREF1 text. Raises ValueError on a bad magic or malformed row.
  var first = true
  for raw in content.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if first:
      if line != BenchRefMagic:
        raise newException(ValueError, "bad bench ref magic: " & line)
      first = false
      continue
    let parts = line.splitWhitespace()
    case parts[0]
    of "tape":
      result.tape = line[4 .. ^1].strip()
    of "tape_crc":
      result.tapeCrc = parseHex32(parts[1])
    of "rom_hash":
      result.romHash = parseHex32(parts[1])
    of "frames":
      result.frames = parseInt(parts[1])
    of "hash_every":
      result.hashEvery = parseInt(parts[1])
    of "build":
      result.build = line[5 .. ^1].strip()
    else:
      if parts.len != 4:
        raise newException(ValueError, "bad bench ref row: " & line)
      result.rows.add(BenchRow(
        frame: parseInt(parts[0]),
        image: parseHex32(parts[1]),
        audio: parseHex32(parts[2]),
        wram: parseHex32(parts[3])))
  if first:
    raise newException(ValueError, "empty bench ref")

proc parseBenchRef*(path: string): BenchRef =
  ## Read and parse a DBREF1 file.
  parseBenchRefString(readFile(path))

proc writeBenchRef*(path: string, r: BenchRef) =
  ## Write a ref file.
  writeFile(path, serializeBenchRef(r))

proc compareRow*(want, got: BenchRow): seq[string] =
  ## Names of the fields that differ between two rows (empty when equal).
  if want.frame != got.frame:
    result.add("frame")
  if want.image != got.image:
    result.add("image")
  if want.audio != got.audio:
    result.add("audio")
  if want.wram != got.wram:
    result.add("wram")

proc describe*(m: RefMismatch): string =
  ## One-line human summary of a mismatch.
  &"MISMATCH frame {m.frame}: {m.fields.join(\"|\")} " &
    &"want image={m.want.image:08x} audio={m.want.audio:08x} wram={m.want.wram:08x} " &
    &"got image={m.got.image:08x} audio={m.got.audio:08x} wram={m.got.wram:08x}"
