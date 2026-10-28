## Bestiary backbone: named enemy records plus lazy battle portraits.
##
## Table base SNES `$D59589` / file `0x159589`, `0x5E`-byte records, indexed
## `id × $5E` (`LDY #$005E` + `JSL $C08FF7` at `$C24D88`; init copy `$C2B6FA`
## loads far `$D59589`). Names reuse `battle_formation.decodeEnemyName`.
##
## Field consumers (offsets from the record base):
## - HP u16 `+0x21`, PP u16 `+0x23` — battle-init copy `$C2B6FA` seeds battler
##   HP from `+0x21` (`battle_formation.EnemyRomHpOff`).
## - EXP u32 `+0x25`, money u16 `+0x29` — drop-table RE (`probe_drop_table`).
## - Music u8 `+0x37` — `$C24A56` `ADC #$0037` / `LDA $D59589,X` / `JSL $C4FBBD`
##   (`battle_music.nim`). 0 and unused song rows are legitimate "no theme".
## - Drop item u8 `+0x58` — `$C24D92` `ADC #$0058`, lands in `$AA10`.
## - Drop freq u8 `+0x57` — `$C24DAD` `ADC #$0057`; CMP 0..6 then BRA always.
##   0: `AND #$007F` → 1/128; 1: `AND #$003F` → 1/64; 2..6 follow 32..2;
##   `>= 7` keeps `$AA10` (always). Item 0 is none.
##
## `EnemyMaxId` is the named-record window shared with `decodeEnemyName`, not
## a proven engine clamp. Item names are decoded per call from the item table
## format without `item_table`'s process-global cache.

import
  std/[strformat, tables],
  ./[battle_bg_catalog, battle_formation, battle_music, enemy_sprites,
     item_table, music_player]

type
  EnemyRecord* = object
    ## Structured decode of one enemy configuration row.
    id*: int
    name*: string
    hp*, pp*, exp*, money*, dropFreq*, dropItemId*, musicId*: int
    dropItemName*: string

  PortraitKey = tuple[spriteId, paletteId: int]

  BestiaryLibrary* = ref object
    ## ROM-backed enemy catalog with a per-library portrait cache.
    catalog*: BackgroundCatalog
    enemies*: seq[EnemyRecord]
    music*: MusicLibrary
    portraits: Table[PortraitKey, EnemySprite]

const
  EnemyMinId* = 1
  EnemyMaxId* = 230
  EnemyHpOff = 0x21
  EnemyPpOff = 0x23
  EnemyExpOff = 0x25
  EnemyMoneyOff = 0x29
  EnemyDropFreqOff = 0x57
  EnemyDropItemOff = 0x58
  ## Freq 0..6 denominators from `$C24DBA` CMP/AND chain.
  DropFreqDenominators = [128, 64, 32, 16, 8, 4, 2]

when EnemyMaxId != EnemyIdMax:
  {.error: "bestiary EnemyMaxId drifted from battle_formation.EnemyIdMax".}

proc readU16(rom: openArray[uint8], off: int): int =
  ## Little-endian u16 at `off`, or `ValueError` if it would run past the ROM.
  if off < 0 or off + 1 >= rom.len:
    raise newException(ValueError, &"u16 read at 0x{off:06X} is outside the ROM")
  result = rom[off].int or (rom[off + 1].int shl 8)

proc readU32(rom: openArray[uint8], off: int): int =
  ## Little-endian u32 at `off`, or `ValueError` if it would run past the ROM.
  if off < 0 or off + 3 >= rom.len:
    raise newException(ValueError, &"u32 read at 0x{off:06X} is outside the ROM")
  result = rom[off].int or (rom[off + 1].int shl 8) or
    (rom[off + 2].int shl 16) or (rom[off + 3].int shl 24)

proc requireEnemyId(id: int) =
  ## Reject ids outside the named-record window `1..230`.
  if id < EnemyMinId or id > EnemyMaxId:
    raise newException(
      ValueError,
      &"enemy id {id} is outside {EnemyMinId}..{EnemyMaxId}"
    )

proc decodeDropItemName(rom: openArray[uint8], itemId: int): string =
  ## Decode one item name from the ROM table without the process-global cache.
  if itemId == 0:
    return ""
  if itemId < 0:
    raise newException(ValueError, &"drop item id {itemId} is negative")
  let base = ItemTableBase + itemId * ItemRecordSize
  if base < 0 or base + ItemNameMaxLen > rom.len:
    raise newException(
      ValueError,
      &"item {itemId} name at 0x{base:06X} overruns the ROM"
    )
  for i in 0 ..< ItemNameMaxLen:
    let b = rom[base + i]
    if b == 0:
      break
    let c = char(b - 0x30)
    if c in {' '..'~'}:
      result.add c

proc dropFreqLabel*(freq: int): string =
  ## Human rate string for the drop-frequency enum (`1/128` .. `always`).
  if freq < 0:
    raise newException(ValueError, &"drop frequency {freq} is negative")
  if freq < DropFreqDenominators.len:
    result = &"1/{DropFreqDenominators[freq]}"
  else:
    result = "always"

proc enemyRecord*(rom: openArray[uint8], id: int): EnemyRecord =
  ## Decode enemy `id` from `rom`. Out-of-range ids, truncated rows, and
  ## song ids outside `0` plus `1..SongCount` raise `ValueError`.
  requireEnemyId(id)
  let base = EnemyTableFileBase + id * EnemyRecordSize
  if base < 0 or base + EnemyRecordSize > rom.len:
    raise newException(
      ValueError,
      &"enemy {id} record at 0x{base:06X} overruns the ROM"
    )
  result.id = id
  result.name = decodeEnemyName(rom, id)
  result.hp = readU16(rom, base + EnemyHpOff)
  result.pp = readU16(rom, base + EnemyPpOff)
  result.exp = readU32(rom, base + EnemyExpOff)
  result.money = readU16(rom, base + EnemyMoneyOff)
  result.dropFreq = rom[base + EnemyDropFreqOff].int
  result.dropItemId = rom[base + EnemyDropItemOff].int
  result.dropItemName = decodeDropItemName(rom, result.dropItemId)
  result.musicId = rom[base + EnemyMusicOff].int
  if result.musicId != 0 and
      (result.musicId < 1 or result.musicId > music_player.SongCount):
    raise newException(
      ValueError,
      &"enemy {id} music id {result.musicId} is outside 0..{music_player.SongCount}"
    )

proc initLibrary(catalog: BackgroundCatalog): BestiaryLibrary =
  ## Bind `catalog` to a music library and decode every named enemy row.
  if catalog.isNil:
    raise newException(ValueError, "background catalog is nil")
  result = BestiaryLibrary(
    catalog: catalog,
    music: newMusicLibrary(catalog.rom),
    portraits: initTable[PortraitKey, EnemySprite]()
  )
  result.enemies = newSeq[EnemyRecord](EnemyMaxId)
  for id in EnemyMinId .. EnemyMaxId:
    result.enemies[id - 1] = enemyRecord(catalog.rom, id)

proc newBestiaryLibrary*(bytes: openArray[uint8]): BestiaryLibrary =
  ## Build a library from ROM bytes, stripping an optional 512-byte header.
  initLibrary(newBackgroundCatalog(bytes))

proc loadBestiaryLibrary*(path: string): BestiaryLibrary =
  ## Load a ROM file and decode its enemy catalog, portraits, and music table.
  initLibrary(loadBackgroundCatalog(path))

proc portrait*(library: BestiaryLibrary, enemyId: int): EnemySprite =
  ## Lazy-decode the battle portrait for `enemyId`, cached by sprite+palette.
  ## A cache hit still returns `enemyId` matching the requested row.
  if library.isNil:
    raise newException(ValueError, "bestiary library is nil")
  requireEnemyId(enemyId)
  if library.catalog.isNil:
    raise newException(ValueError, "bestiary catalog is nil")
  let
    source = portraitKey(library.catalog.rom, enemyId)
    key = (source.spriteIndex, source.paletteIndex)
  if key in library.portraits:
    result = library.portraits[key]
  else:
    let decoded = decodeEnemySprite(library.catalog.rom, enemyId)
    library.portraits[key] = decoded
    result = decoded
  result.enemyId = enemyId
