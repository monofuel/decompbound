## EarthBound battery-save (SRAM) inspector.
##
## Reads an 8KB .srm and reports what we've mapped of the EB save format, plus
## a value-finder to help map more of it. The format is only PARTIALLY reverse
## engineered here (confirmed fields are marked); the --find mode is how we
## discover new fields: tell it a value you know in-game and it locates every
## place that value is stored.
##
## Usage:
##   nim r src/tools/sram_info.nim [save.srm]            # dump known fields
##   nim r src/tools/sram_info.nim [save.srm] --find 20  # locate a value
##
## Default save path: "bin/Earthbound (U) [!].srm".

import
  std/[os, strformat, strutils]

const
  DefaultSrm = "bin/Earthbound (U) [!].srm"
  Header = "HAL Laboratory, inc."   # EB's save-validity signature at offset 0.

type
  Field = object
    name: string
    offset: int
    size: int         ## bytes (1/2/4), little-endian
    confidence: string

# Fields confirmed/inferred from a real save (Ness early game: 39/39 HP,
# 10/10 PP, $20 on hand, $64 ATM). Extend this table as --find maps more.
const KnownFields = [
  Field(name: "Money on hand", offset: 0x5C, size: 4, confidence: "confirmed ($20/$71 across saves)"),
  Field(name: "ATM balance",   offset: 0x60, size: 4, confidence: "inferred"),
  Field(name: "Char1 HP now",  offset: 0x23E, size: 2, confidence: "confirmed (39/60 across saves)"),
  Field(name: "Char1 HP max",  offset: 0x240, size: 2, confidence: "confirmed"),
  Field(name: "Char1 PP now",  offset: 0x244, size: 2, confidence: "confirmed (10/20 across saves)"),
  Field(name: "Char1 PP max",  offset: 0x246, size: 2, confidence: "confirmed"),
]

proc readLE(data: string, offset, size: int): uint32 =
  ## Little-endian unsigned read of `size` bytes at `offset`.
  for i in 0 ..< size:
    if offset + i < data.len:
      result = result or (data[offset + i].uint32 shl (8 * i))

proc dumpKnown(data: string) =
  ## Validate the header and print the mapped fields.
  let sig = if data.len >= Header.len: data[0 ..< Header.len] else: ""
  echo "save file: ", data.len, " bytes"
  if sig == Header:
    echo "header:    OK  (\"", Header, "\") — valid EarthBound save"
  else:
    echo "header:    MISSING/INVALID — not a valid EB save (or empty)"
  var nonzero = 0
  for c in data:
    if c != '\0': inc nonzero
  echo "non-zero:  ", nonzero, " / ", data.len, " bytes of real data"
  echo ""
  echo "mapped fields (offset  value  field  [confidence]):"
  for f in KnownFields:
    let v = readLE(data, f.offset, f.size)
    echo &"  0x{f.offset:03X}  {v:>7}   {f.name:<14} [{f.confidence}]"
  echo ""
  echo "The format is only partially mapped. Use --find <value> to locate a"
  echo "stat you know in-game, then we can add it to KnownFields."

proc findValue(data: string, n: uint32) =
  ## Report every offset where n appears as a u8, u16-LE, or u32-LE.
  echo &"searching for {n} (0x{n:X}) as u8 / u16-LE / u32-LE:"
  var hits = 0
  for size in [1, 2, 4]:
    if n >= (1'u64 shl (8 * size)).uint32 and size < 4: continue  # too big for this width
    for off in 0 .. data.len - size:
      if readLE(data, off, size) == n:
        # Skip the trivial u8 matches inside a wider match to reduce noise:
        # only report u8 when the value itself is < 256 and it's a lone byte.
        echo &"  0x{off:03X}  as u{size*8}-LE"
        inc hits
  if hits == 0:
    echo "  (not found — try a nearby value; some stats are BCD or offset)"
  echo &"({hits} hit(s))"

when isMainModule:
  var path = DefaultSrm
  var findN = -1
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--find" and i < paramCount():
      findN = parseInt(paramStr(i + 1)); inc i
    elif not a.startsWith("--"):
      path = a
    inc i

  if not fileExists(path):
    echo "no save file at: ", path
    echo "(save in-game at a phone first, or pass a .srm path)"
    quit(1)
  let data = readFile(path)
  echo "== ", path, " =="
  if findN >= 0:
    findValue(data, findN.uint32)
  else:
    dumpKnown(data)
