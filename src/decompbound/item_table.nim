## ROM item table lookups (names, price, sell rule for inventory display).
##
## Table base SNES `$D55000` / file `0x155000`, `0x27`-byte records indexed
## `id * 0x27` (docs/decompilation.md, verified byte-exact). Name is EB-encoded
## text (ASCII + $30) at `+0x00`, null-terminated; type byte `+0x19`, price u16
## LE `+0x1A`. Names/prices are decoded at runtime from the user's ROM — never
## baked into source (copyright).
##
## Sell offer: routine at `$C14F33` loads `+0x1A` then `LSR A` → floor(price/2).
## Twin buy path at `$C14EF8` loads the same field without LSR. Key/story items
## in our ROM have price 0 (sell offer 0); we expose sellable as price > 0.

import std/os

const
  ItemTableBase* = 0x155000
  ItemRecordSize* = 0x27
  ItemNameMaxLen* = 0x19  # name field runs up to the +0x19 type byte
  ItemTypeOff* = 0x19
  ItemPriceOff* = 0x1A
  DefaultRomPath* = "bin/Earthbound (U) [!].smc"

type
  ItemRecordCache* = object
    ## Cached per-id decode of the ROM item table fields we expose.
    name*: string
    price*: int
    flags*: int

var
  # Per-id cache: filled on first successful lookup so live-party snapshots
  # do not re-decode the same ROM bytes every publish. Threadvar (not shared):
  # item lookups also run on Mummy worker threads in the standalone MCP server,
  # and a shared seq would race on setLen.
  gItemCache {.threadvar.}: seq[ItemRecordCache]
  gItemCached {.threadvar.}: seq[bool]

proc ensureItemCache(id: int) =
  ## Grow the threadvar cache so `id` is a valid index.
  if id >= gItemCache.len:
    gItemCache.setLen(id + 1)
    gItemCached.setLen(id + 1)

proc decodeItemRecord(rom: openArray[uint8], id: int): ItemRecordCache =
  ## Decode name / type / price for `id` from ROM (no cache write).
  ## Returns default empty if the ROM is too short to hold the record.
  let base = ItemTableBase + id * ItemRecordSize
  if base + ItemPriceOff + 1 >= rom.len:
    return result
  for i in 0 ..< ItemNameMaxLen:
    let b = rom[base + i]
    if b == 0:
      break
    let c = char(b - 0x30)
    if c in ' '..'~':
      result.name.add c
  result.flags = rom[base + ItemTypeOff].int
  result.price =
    rom[base + ItemPriceOff].int or (rom[base + ItemPriceOff + 1].int shl 8)

proc itemRecord*(rom: openArray[uint8], id: int): ItemRecordCache =
  ## Full cached record for item `id`. Empty for id 0 / OOB / short ROM.
  ## Short-ROM misses are not cached so a later full ROM can still decode.
  if id <= 0:
    return result
  if id < gItemCached.len and gItemCached[id]:
    return gItemCache[id]
  let base = ItemTableBase + id * ItemRecordSize
  if base + ItemPriceOff + 1 >= rom.len:
    return result
  result = decodeItemRecord(rom, id)
  ensureItemCache(id)
  gItemCache[id] = result
  gItemCached[id] = true

proc itemName*(rom: openArray[uint8], id: int): string =
  ## Decode item `id`'s name from the ROM item table.
  ## "" for id 0 (empty slot), out-of-range ids, or an absent/short ROM.
  ## Names are cached per id after the first decode; signature unchanged.
  itemRecord(rom, id).name

proc itemPrice*(rom: openArray[uint8], id: int): int =
  ## Buy price (u16 LE at record `+0x1A`). 0 for invalid/absent ROM or id 0.
  itemRecord(rom, id).price

proc itemFlags*(rom: openArray[uint8], id: int): int =
  ## Type / flag byte at record `+0x19`. 0 for invalid/absent ROM or id 0.
  itemRecord(rom, id).flags

proc itemSellPrice*(rom: openArray[uint8], id: int): int =
  ## Shop sell offer: floor(buy price / 2), matching `$C14F5A` `LSR A`.
  ## Price 0 or 1 → 0. (Our ROM has no items with price 1.)
  itemPrice(rom, id) shr 1

proc itemSellable*(rom: openArray[uint8], id: int): bool =
  ## True when the shop sell routine would offer a non-zero price.
  ## Key/story items in our ROM have buy price 0 (e.g. ATM card, Sound Stone,
  ## Key to the tower, Franklin badge). Separate +0x19 "unsellable" bit not
  ## yet pinned in the sell-menu path — TODO if a filter exists beyond price.
  itemPrice(rom, id) > 0

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
