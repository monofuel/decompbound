## Enemy → battle-group → background-variant catalog.
##
## A background is a property of a battle GROUP, not of an enemy record.
## This module walks the group table on the user's ROM and records, for each
## enemy, the distinct `(layerA, layerB, letterbox)` triples of groups that
## actually spawn that enemy.
##
## Group table: file `0x10C60D` (SNES `$D0C60D`), 484 × 8-byte entries.
## 484 = (`0x10D52D` − `0x10C60D`) / 8. `$C2C309` / `$C2C236` `CMP #$01E3`
## names index 483; that is table-span evidence, not a separate scanned cap.
## Entry `+0..+2` is a 24-bit far pointer (bank `$D0`) to the member list in
## `0x10D52D .. 0x10DFB4`; lists are `[u8 spawnCount, u16le enemyId]*` then
## `$FF`. Letterbox is byte `+7` masked with 3, matching `$C2D121`
## `AND #$0003` (file `0x02D148`).
##
## Background pair table: file `0x0BD89A` (SNES `$CBD89A`), 484 × 4 bytes,
## `(u16 layerA, u16 layerB)` per group id. Loader at file `0x02489D`
## (`$C2489D`) does `LDA #$D89A` / `LDA #$00CB` then `groupId*4`. Those words
## are layer ids for `$C2D121`, which indexes the 17-byte layer table
## `$CADCA1` by `id*17` (`LDA.L $CADCA1,X` at `$C2D1CF` / file `0x02D1CF`).
## 327 = (`0x0AF258` − `0x0ADCA1`) / 17. Layer 0 and pair `(0, 0)` are
## stored as-is; an empty pair is a legitimate configuration.
##
## Spawn rule: the expander at `$C1E3CF` loads `spawnCount` into `$14` and
## branches to the countdown (`LDX $14` / `TXY` / `DEX` / `CPY #$0000`)
## *before* the first `STA $9F8C,X`. Count 0 therefore appends nobody.
## Only `spawnCount > 0` associates an enemy with that group's background.
## Gold has 24 count-0 records; they stay in the list and are not mapped.
##
## Enemy window is `1..230`, matching `decodeEnemyName` / `EnemyIdMax`.
## Gold id 230 still decodes as EB text; id 231 does not. Spawned member
## ids on gold are `1..229`. That is a named-record / decode window, not an
## in-code `CMP` clamp — no expander bound at 230 is claimed here.
##
## Unmapped ids in `1..230` still get a record with empty `variants`.
## Everything is decoded at runtime from the user's ROM.

import
  std/[algorithm, os, strformat],
  ./[battle_formation, common]

type
  BackgroundVariant* = object
    ## One distinct background a spawned enemy can appear against.
    groupIds*: seq[int]
    layerA*, layerB*, letterbox*: int

  EnemyBackgroundEntry* = object
    ## Catalog row for one enemy id in `1..230`, including unmapped ids.
    id*: int
    name*: string
    variants*: seq[BackgroundVariant]

  BackgroundCatalog* = ref object
    ## Enemy-indexed background variants decoded from one ROM image.
    rom*: seq[uint8]
    enemies*: seq[EnemyBackgroundEntry]

const
  CopierHeaderSize = 512
  GroupTableFile = 0x10C60D
  GroupEntrySize = 8
  MemberListFileBase = 0x10D52D
  MemberListFileEnd = 0x10DFB4
  BgPairTableFile = 0x0BD89A
  BgPairEntrySize = 4
  GroupLetterboxOff = 7
  LetterboxMask = 3
  MemberTerm = 0xFF
  FarPtrBank = 0xD0
  LayerTableFile = 0x0ADCA1
  LayerEntrySize = 17
  ScrollTableFile = 0x0AF258
  CatalogEnemyMin = 1
  ## 484 groups: member-list base minus group-table base, 8 bytes per entry.
  BattleGroupCount* = (MemberListFileBase - GroupTableFile) div GroupEntrySize
  ## 327 layers: scroll-table base minus layer-table base, 17 bytes per entry.
  BackgroundLayerCount* = (ScrollTableFile - LayerTableFile) div LayerEntrySize

proc readU16(rom: openArray[uint8], off: int): int =
  ## Little-endian u16 at `off`, or `ValueError` if it would run past the ROM.
  if off < 0 or off + 1 >= rom.len:
    raise newException(ValueError, &"u16 read at 0x{off:06X} is outside the ROM")
  result = rom[off].int or (rom[off + 1].int shl 8)

proc readU24(rom: openArray[uint8], off: int): int =
  ## Little-endian 24-bit far pointer at `off`, or `ValueError` if truncated.
  if off < 0 or off + 2 >= rom.len:
    raise newException(ValueError, &"u24 read at 0x{off:06X} is outside the ROM")
  result = readU16(rom, off) or (rom[off + 2].int shl 16)

proc romBody(bytes: openArray[uint8]): seq[uint8] =
  ## Strip an optional 512-byte copier header and require a 3 MiB body.
  var start = 0
  if bytes.len mod 1024 == CopierHeaderSize:
    start = CopierHeaderSize
  let bodyLen = bytes.len - start
  if bodyLen != EarthboundRomSize:
    raise newException(
      ValueError,
      &"ROM size {bodyLen} != {EarthboundRomSize} (optional {CopierHeaderSize}-byte copier header stripped)"
    )
  result = newSeq[uint8](EarthboundRomSize)
  for i in 0 ..< EarthboundRomSize:
    result[i] = bytes[start + i]

proc memberFileOffset(snes: int): int =
  ## HiROM file offset for a 24-bit group member-list pointer.
  result = snes and 0x3FFFFF

proc parseMemberList(rom: openArray[uint8], gid, listOff: int):
    seq[tuple[spawnCount, enemyId: int]] =
  ## Walk `[spawnCount, enemyId]* $FF` at `listOff` and require termination.
  if listOff < MemberListFileBase or listOff >= MemberListFileEnd:
    raise newException(
      ValueError,
      &"group {gid} member-list pointer 0x{listOff:06X} is outside 0x{MemberListFileBase:06X}..0x{MemberListFileEnd:06X}"
    )
  var off = listOff
  while true:
    if off >= MemberListFileEnd:
      raise newException(
        ValueError,
        &"group {gid} member list at 0x{listOff:06X} is missing $FF before 0x{MemberListFileEnd:06X}"
      )
    if rom[off] == MemberTerm:
      break
    if off + 2 >= MemberListFileEnd:
      raise newException(
        ValueError,
        &"group {gid} member record at 0x{off:06X} is truncated before $FF"
      )
    let spawnCount = rom[off].int
    let enemyId = readU16(rom, off + 1)
    if enemyId < CatalogEnemyMin or enemyId > EnemyIdMax:
      raise newException(
        ValueError,
        &"group {gid} member at 0x{off:06X} has enemy id {enemyId} outside {CatalogEnemyMin}..{EnemyIdMax}"
      )
    result.add (spawnCount, enemyId)
    off += 3

proc addGroupVariant(entry: var EnemyBackgroundEntry; gid, layerA, layerB,
    letterbox: int) =
  ## Record `gid` on the matching variant, or append a new variant.
  var found = false
  for v in entry.variants.mitems:
    if v.layerA == layerA and v.layerB == layerB and v.letterbox == letterbox:
      if gid notin v.groupIds:
        v.groupIds.add gid
      found = true
      break
  if not found:
    entry.variants.add BackgroundVariant(
      groupIds: @[gid],
      layerA: layerA,
      layerB: layerB,
      letterbox: letterbox)

proc sortEnemyVariants(entry: var EnemyBackgroundEntry) =
  ## Sort each variant's group ids, then variants by the first group id.
  for v in entry.variants.mitems:
    v.groupIds.sort()
  entry.variants.sort(
    proc (a, b: BackgroundVariant): int =
      cmp(a.groupIds[0], b.groupIds[0]))

proc newBackgroundCatalog*(bytes: openArray[uint8]): BackgroundCatalog =
  ## Decode every group's spawned members into per-enemy background variants.
  let body = romBody(bytes)
  result = BackgroundCatalog(rom: body)
  result.enemies = newSeq[EnemyBackgroundEntry](EnemyIdMax)
  for id in CatalogEnemyMin .. EnemyIdMax:
    result.enemies[id - 1].id = id
    result.enemies[id - 1].name = decodeEnemyName(body, id)

  let pairEnd = BgPairTableFile + BattleGroupCount * BgPairEntrySize
  let groupEnd = GroupTableFile + BattleGroupCount * GroupEntrySize
  if groupEnd > body.len:
    raise newException(ValueError, "group table overruns the ROM")
  if pairEnd > body.len:
    raise newException(ValueError, "background pair table overruns the ROM")

  for gid in 0 ..< BattleGroupCount:
    let entryOff = GroupTableFile + gid * GroupEntrySize
    let snes = readU24(body, entryOff)
    let bank = body[entryOff + 2].int
    if bank != FarPtrBank:
      raise newException(
        ValueError,
        &"group {gid} member-list bank is ${bank:02X}, expected ${FarPtrBank:02X}"
      )
    let listOff = memberFileOffset(snes)
    let letterbox = body[entryOff + GroupLetterboxOff].int and LetterboxMask
    let pairOff = BgPairTableFile + gid * BgPairEntrySize
    let layerA = readU16(body, pairOff)
    let layerB = readU16(body, pairOff + 2)
    if layerA < 0 or layerA >= BackgroundLayerCount:
      raise newException(
        ValueError,
        &"group {gid} layerA {layerA} is outside 0..{BackgroundLayerCount - 1}"
      )
    if layerB < 0 or layerB >= BackgroundLayerCount:
      raise newException(
        ValueError,
        &"group {gid} layerB {layerB} is outside 0..{BackgroundLayerCount - 1}"
      )
    let members = parseMemberList(body, gid, listOff)
    var seen: seq[int] = @[]
    for m in members:
      if m.spawnCount <= 0:
        continue
      if m.enemyId in seen:
        continue
      seen.add m.enemyId
      addGroupVariant(
        result.enemies[m.enemyId - 1], gid, layerA, layerB, letterbox)

  for e in result.enemies.mitems:
    sortEnemyVariants(e)

proc loadBackgroundCatalog*(path: string): BackgroundCatalog =
  ## Load a ROM file and decode its enemy background catalog.
  if not fileExists(path):
    raise newException(IOError, &"ROM not found: {path}")
  let data = readFile(path)
  var bytes = newSeq[uint8](data.len)
  for i in 0 ..< data.len:
    bytes[i] = data[i].uint8
  result = newBackgroundCatalog(bytes)

proc enemyIndex*(catalog: BackgroundCatalog, enemyId: int): int =
  ## Index of `enemyId` in `catalog.enemies`, or `-1` when no row exists.
  result = -1
  if catalog.isNil:
    return
  for i, e in catalog.enemies:
    if e.id == enemyId:
      result = i
      break
