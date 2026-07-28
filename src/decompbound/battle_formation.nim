## Live battle formation: enemy ids in WRAM + names from the ROM table.
##
## Enemy battler pointer table at WRAM `$A970` (null-terminated u16 LE list).
## Each pointer targets an enemy battler struct whose **id is the u16 at `+0`**.
## Verified on `bin/states/slot200.state` (id 68 Starman Super + id 13 Atomic
## Power Robot) and `battle_menu_healthy.state` (Mad Taxi / Crazed Sign).
##
## Battle init `$C2B6FA` indexes enemy config `$D59589` + id×`$5E` and copies
## HP/PP/stats into these structs; the overlay only peeks — never writes.

import
  std/[strformat, strutils],
  ./snesbus

const
  ## Null-terminated enemy battler pointer table (u16 LE each).
  EnemyBattlerPtrTable* = 0xA970
  ## Max enemies we will walk (formation UI bound; table is short).
  EnemyBattlerPtrMax* = 6
  ## Enemy id lives at battler base + 0 (u16 LE; high byte usually 0).
  EnemyBattlerIdOff* = 0x00
  ## Runtime HP triple starts here (init from ROM record +0x21).
  EnemyBattlerHpOff* = 0x11
  ## Max plausible enemy id (table has ~200+ rows; 230 is a soft clamp).
  EnemyIdMax* = 230
  ## Enemy configuration table — file offset, stride 0x5E (Layer 0b).
  EnemyTableFileBase* = 0x159589
  EnemyRecordSize* = 0x5E
  EnemyNameOff* = 0x01
  EnemyNameMaxLen* = 0x19
  WramBase = 0x7E0000

type
  BattleEnemy* = object
    ## One enemy present in the live formation.
    id*: int
    name*: string
    hp*: int
    battlerAddr*: int

  BattleFormation* = object
    ## Snapshot of enemies currently loaded for a fight.
    enemies*: seq[BattleEnemy]
    empty*: bool

proc wramU8(snes: SnesBus, off: int): uint8 {.inline.} =
  ## Read one WRAM byte at 16-bit offset under bank `$7E`.
  let ea = WramBase + (off and 0x1FFFF)
  if ea >= 0 and ea < snes.bus.mem.len:
    result = snes.bus.mem[ea]
  else:
    result = 0

proc wramU16(snes: SnesBus, off: int): int {.inline.} =
  ## Little-endian u16 at 16-bit WRAM offset.
  wramU8(snes, off).int or (wramU8(snes, off + 1).int shl 8)

proc decodeEnemyName*(rom: openArray[uint8], id: int): string =
  ## Runtime EB name from the enemy configuration table (ASCII + `$30`).
  if id <= 0 or id > EnemyIdMax:
    return ""
  let base = EnemyTableFileBase + id * EnemyRecordSize
  if base + EnemyRecordSize > rom.len:
    return ""
  for i in 0 ..< EnemyNameMaxLen:
    let b = rom[base + EnemyNameOff + i]
    if b == 0:
      break
    let c = char(b - 0x30)
    if c in {' '..'~'}:
      result.add c

proc readBattleFormation*(snes: SnesBus): BattleFormation =
  ## Walk `$A970` and collect live enemy ids + decoded names + HP.
  ## Hardened 2026-07-27: during battle-init the tail of the list can
  ## briefly hold stale/duplicate pointers from the previous fight (seen
  ## live: a mid-init read decoded a ghost second enemy). Dedup by battler
  ## address and stop at the first repeat — the real list never aliases.
  result.enemies = @[]
  let rom = snes.rom
  var seen: seq[int] = @[]
  for i in 0 ..< EnemyBattlerPtrMax:
    let p = wramU16(snes, EnemyBattlerPtrTable + i * 2)
    if p == 0 or p == 0xFFFF:
      break
    # Reject non-WRAM-ish pointers (noise past the terminator).
    if p < 0x2000 or p > 0x1F000:
      break
    if p in seen:
      break
    seen.add p
    let id = wramU16(snes, p + EnemyBattlerIdOff)
    if id <= 0 or id > EnemyIdMax:
      break
    let hp = wramU16(snes, p + EnemyBattlerHpOff)
    if hp <= 0 or hp > 9999:
      # Empty / garbage slot — stop rather than invent enemies.
      break
    result.enemies.add BattleEnemy(
      id: id,
      name: decodeEnemyName(rom, id),
      hp: hp,
      battlerAddr: p
    )
  result.empty = result.enemies.len == 0

proc formationLine*(form: BattleFormation): string =
  ## One-line HUD / log string: `id:name, id:name, ...`.
  if form.empty:
    return ""
  var parts: seq[string]
  for e in form.enemies:
    let n = if e.name.len > 0: e.name else: "?"
    parts.add &"{e.id}:{n}"
  parts.join(", ")
