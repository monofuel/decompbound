## Live battle formation: enemy ids in WRAM + names from the ROM table.
##
## Enemy battler pointer table at WRAM `$A970` (null-terminated u16 LE list).
## Each pointer targets an enemy battler struct whose **id is the u16 at `+0`**.
## Verified on `bin/states/slot200.state` (id 68 Starman Super + id 13 Atomic
## Power Robot) and `battle_menu_healthy.state` (Mad Taxi / Crazed Sign).
##
## Battle init `$C2B6FA` indexes enemy config `$D59589` + id×`$5E` and copies
## HP/PP/stats into these structs; the overlay only peeks — never writes.
##
## Mid-battle `$A970` is rewritten as engine scratch (writers `$C2569D`,
## `$C258CC`, `$C25E22`, `$C23E84`, `$C23BB2`, `$C08F0F`, …) while text/actions
## advance — pointer slots briefly aim at low-id ghost structs. The id word
## at each *real* enemy battler (`$A21C`, `$A26A` on slot200) is never rewritten
## for the whole fight. HUD path: latch ids/addrs once when table-consistent,
## then only refresh HP and drop zero-HP entries.

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
  ## ROM max HP lives at enemy record +0x21 (same as init source).
  EnemyRomHpOff* = 0x21
  ## Battle result / end code (victory = `$0078`).
  BattleResultCodeWram* = 0x5D60
  BattleResultVictory* = 0x0078
  ## Consecutive identical valid raw reads required before first latch.
  LatchStableFrames* = 2
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

  FormationLatch* = object
    ## Sticky FOE list: ids/names/addrs captured once; HP refreshed per frame.
    enemies*: seq[BattleEnemy]
    latched*: bool
    ## Pending raw capture while waiting for LatchStableFrames agreement.
    pending*: seq[BattleEnemy]
    pendingHits*: int
    ## After all-dead / victory clear, refuse re-arm until raw is non-consistent
    ## (or empty) for LatchStableFrames — blocks mid-victory ghost re-latch.
    needsGap*: bool
    gapHits*: int

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

proc romEnemyMaxHp*(rom: openArray[uint8], id: int): int =
  ## Table max HP for enemy `id` (record +0x21), or 0 if out of range.
  if id <= 0 or id > EnemyIdMax:
    return 0
  let base = EnemyTableFileBase + id * EnemyRecordSize
  if base + EnemyRomHpOff + 1 >= rom.len:
    return 0
  rom[base + EnemyRomHpOff].int or (rom[base + EnemyRomHpOff + 1].int shl 8)

proc readBattleFormation*(snes: SnesBus): BattleFormation =
  ## Walk `$A970` and collect live enemy ids + decoded names + HP.
  ## Hardened 2026-07-27: during battle-init the tail of the list can
  ## briefly hold stale/duplicate pointers from the previous fight (seen
  ## live: a mid-init read decoded a ghost second enemy). Dedup by battler
  ## address and stop at the first repeat — the real list never aliases.
  ## Mid-battle the list is also rewritten as scratch; HUD must use
  ## `updateFormationLatch` rather than this raw walk every frame.
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

proc formationTableConsistent*(snes: SnesBus, form: BattleFormation): bool =
  ## True when every entry has a ROM name and 0 < HP <= table max HP.
  ## Rejects mid-rewrite ghosts (e.g. Bad Buffalo with HP 588 > rom 341).
  if form.empty or form.enemies.len == 0:
    return false
  let rom = snes.rom
  for e in form.enemies:
    if e.id <= 0 or e.id > EnemyIdMax:
      return false
    if e.name.len == 0:
      return false
    let maxHp = romEnemyMaxHp(rom, e.id)
    if maxHp <= 0:
      return false
    if e.hp <= 0 or e.hp > maxHp:
      return false
    if e.battlerAddr < 0x2000 or e.battlerAddr > 0x1F000:
      return false
  true

proc enemyIdsEqual(a, b: seq[BattleEnemy]): bool =
  ## Compare id + battlerAddr sequences (HP may differ).
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i].id != b[i].id or a[i].battlerAddr != b[i].battlerAddr:
      return false
  true

proc battleEndSignaled*(snes: SnesBus): bool =
  ## Victory code `$5D60 == $0078` when the engine posts it.
  wramU16(snes, BattleResultCodeWram) == BattleResultVictory

proc clearFormationLatch*(latch: var FormationLatch; afterBattle = false) =
  ## Drop sticky FOE state (battle over or HUD reset).
  ## When `afterBattle`, block re-arm until a raw gap (see needsGap).
  latch.enemies = @[]
  latch.latched = false
  latch.pending = @[]
  latch.pendingHits = 0
  if afterBattle:
    latch.needsGap = true
    latch.gapHits = 0
  else:
    latch.needsGap = false
    latch.gapHits = 0

proc latchedFormation*(latch: FormationLatch): BattleFormation =
  ## View the latch as a BattleFormation for HUD / logging.
  result.enemies = latch.enemies
  result.empty = latch.enemies.len == 0

proc updateFormationLatch*(snes: SnesBus, latch: var FormationLatch): BattleFormation =
  ## Latch-aware FOE snapshot for the F8 overlay.
  ##
  ## - Not latched: capture when raw `$A970` walk is table-consistent for
  ##   `LatchStableFrames` consecutive polls (ids + battler addrs agree).
  ## - Latched: re-read HP only from latched `battlerAddr`; drop HP<=0;
  ##   clear when all dead or `$5D60==$0078`. Never re-decode ids from `$A970`.
  if latch.latched:
    if battleEndSignaled(snes):
      clearFormationLatch(latch, afterBattle = true)
      return latchedFormation(latch)
    var kept: seq[BattleEnemy] = @[]
    for e in latch.enemies:
      var cur = e
      cur.hp = wramU16(snes, e.battlerAddr + EnemyBattlerHpOff)
      # Id word at real battlers is stable for the whole fight (trace-proven).
      # Re-check only to refuse following a freed/reused slot into garbage.
      let liveId = wramU16(snes, e.battlerAddr + EnemyBattlerIdOff)
      if liveId != e.id:
        continue
      if cur.hp > 0 and cur.hp <= 9999:
        kept.add cur
    latch.enemies = kept
    if latch.enemies.len == 0:
      clearFormationLatch(latch, afterBattle = true)
    return latchedFormation(latch)

  # Not latched — gap after battle-end before any re-arm.
  let raw = readBattleFormation(snes)
  if latch.needsGap:
    if raw.empty or not formationTableConsistent(snes, raw):
      inc latch.gapHits
      if latch.gapHits >= LatchStableFrames:
        latch.needsGap = false
        latch.gapHits = 0
    else:
      latch.gapHits = 0
    latch.pending = @[]
    latch.pendingHits = 0
    return latchedFormation(latch)

  # Arm from a stable table-consistent raw read.
  if formationTableConsistent(snes, raw):
    if latch.pendingHits > 0 and enemyIdsEqual(latch.pending, raw.enemies):
      inc latch.pendingHits
    else:
      latch.pending = raw.enemies
      latch.pendingHits = 1
    if latch.pendingHits >= LatchStableFrames:
      latch.enemies = latch.pending
      latch.latched = true
      latch.pending = @[]
      latch.pendingHits = 0
  else:
    latch.pending = @[]
    latch.pendingHits = 0
  latchedFormation(latch)

proc formationLine*(form: BattleFormation): string =
  ## One-line HUD / log string: `id:name, id:name, ...`.
  if form.empty:
    return ""
  var parts: seq[string]
  for e in form.enemies:
    let n = if e.name.len > 0: e.name else: "?"
    parts.add &"{e.id}:{n}"
  parts.join(", ")

proc formationLineHp*(form: BattleFormation): string =
  ## HUD line with current HP: `id:name HP, ...`.
  if form.empty:
    return ""
  var parts: seq[string]
  for e in form.enemies:
    let n = if e.name.len > 0: e.name else: "?"
    parts.add &"{e.id}:{n} {e.hp}"
  parts.join(", ")
