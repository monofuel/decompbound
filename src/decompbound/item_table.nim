## ROM item table lookups (names for inventory display).
##
## Table base SNES `$D55000` / file `0x155000`, `0x27`-byte records indexed
## `id * 0x27` (docs/decompilation.md, verified byte-exact). Name is EB-encoded
## text (ASCII + $30) at `+0x00`, null-terminated; type byte `+0x19`, price u16
## `+0x1A`. Names are decoded at runtime from the user's ROM — never baked into
## source (copyright).

import std/os

const
  ItemTableBase* = 0x155000
  ItemRecordSize* = 0x27
  ItemNameMaxLen* = 0x19  # name field runs up to the +0x19 type byte
  DefaultRomPath* = "bin/Earthbound (U) [!].smc"

var
  # Per-id name cache: filled on first successful lookup so live-party
  # snapshots do not re-decode the same ROM bytes every publish. Threadvar
  # (not shared): itemName also runs on Mummy worker threads in the
  # standalone MCP server, and a shared seq would race on setLen.
  gItemNameCache {.threadvar.}: seq[string]
  gItemNameCached {.threadvar.}: seq[bool]

proc itemName*(rom: openArray[uint8], id: int): string =
  ## Decode item `id`'s name from the ROM item table.
  ## "" for id 0 (empty slot), out-of-range ids, or an absent/short ROM.
  ## Names are cached per id after the first decode; signature unchanged.
  if id <= 0:
    return ""
  if id < gItemNameCached.len and gItemNameCached[id]:
    return gItemNameCache[id]
  let base = ItemTableBase + id * ItemRecordSize
  if base + ItemNameMaxLen > rom.len:
    return ""
  for i in 0 ..< ItemNameMaxLen:
    let b = rom[base + i]
    if b == 0:
      break
    let c = char(b - 0x30)
    if c in ' '..'~':
      result.add c
  if id >= gItemNameCache.len:
    gItemNameCache.setLen(id + 1)
    gItemNameCached.setLen(id + 1)
  gItemNameCache[id] = result
  gItemNameCached[id] = true

proc loadRomBytes*(path = DefaultRomPath): seq[uint8] =
  ## Read a ROM for table lookups, stripping a 512-byte copier header.
  ## Empty seq if the file is missing (lookups then return "").
  if not fileExists(path):
    return @[]
  let data = readFile(path)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len:
    result[i] = data[start + i].uint8
