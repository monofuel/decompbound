## Enemy drop-table parse: Starman Super + cross-check rows from the user ROM.
##
## Verifies configuration table base $D59589 / file 0x159589, stride 0x5E,
## drop freq at +0x57 and drop item at +0x58. Names and item labels are decoded
## at runtime only — nothing copyrighted is hardcoded as source data.
##
## Evidence: /tmp/rng_layer0b_summary.md (Layer 0b drop RE).

import
  std/[os, strformat, strutils],
  ../decompbound/item_table

const
  ## Enemy configuration table — SNES $D59589, verified via $C24D7C far-ptr load.
  EnemyTableFileBase = 0x159589
  ## Record stride — LDY #$005E then JSL $C08FF7 at $C24D88.
  EnemyRecordSize = 0x5E
  EnemyNameOff = 0x01
  EnemyNameMaxLen = 0x19
  EnemyHpOff = 0x21
  EnemyPpOff = 0x23
  EnemyExpOff = 0x25
  EnemyMoneyOff = 0x29
  ## Drop frequency enum — ADC #$57 at $C24DAD.
  EnemyDropFreqOff = 0x57
  ## Drop item id — ADC #$58 at $C24D92; result lands in $AA10.
  EnemyDropItemOff = 0x58
  ## Structural id checks (not name strings).
  StarmanSuperId = 68
  StarmanSuperHp = 568
  ## Freq enum → denominator (0 is special: 1/128, not "never").
  FreqDenominators = [128, 64, 32, 16, 8, 4, 2, 1]

type
  EnemyRecord = object
    id: int
    name: string
    hp: int
    pp: int
    exp: int
    money: int
    dropFreq: int
    dropItemId: int
    dropItemName: string

proc readU16Le(rom: openArray[uint8], off: int): int =
  ## Little-endian u16 from ROM file offset.
  rom[off].int or (rom[off + 1].int shl 8)

proc readU32Le(rom: openArray[uint8], off: int): int =
  ## Little-endian u32 from ROM file offset.
  rom[off].int or (rom[off + 1].int shl 8) or
    (rom[off + 2].int shl 16) or (rom[off + 3].int shl 24)

proc decodeEnemyName(rom: openArray[uint8], recBase: int): string =
  ## Decode EB text at record +0x01 (storage = ASCII + 0x30), NUL-terminated.
  for i in 0 ..< EnemyNameMaxLen:
    let b = rom[recBase + EnemyNameOff + i]
    if b == 0:
      break
    let c = char(b - 0x30)
    if c in {' '..'~'}:
      result.add c

proc enemyRecord(rom: openArray[uint8], id: int): EnemyRecord =
  ## Parse one enemy configuration row by id.
  let base = EnemyTableFileBase + id * EnemyRecordSize
  if base + EnemyRecordSize > rom.len:
    raise newException(ValueError, fmt"enemy id {id} past ROM end")
  result.id = id
  result.name = decodeEnemyName(rom, base)
  result.hp = readU16Le(rom, base + EnemyHpOff)
  result.pp = readU16Le(rom, base + EnemyPpOff)
  result.exp = readU32Le(rom, base + EnemyExpOff)
  result.money = readU16Le(rom, base + EnemyMoneyOff)
  result.dropFreq = rom[base + EnemyDropFreqOff].int
  result.dropItemId = rom[base + EnemyDropItemOff].int
  result.dropItemName = itemName(rom, result.dropItemId)

proc freqLabel(freq: int): string =
  ## Human rate string for the drop-frequency enum.
  if freq >= 0 and freq < FreqDenominators.len:
    if FreqDenominators[freq] == 1:
      return "always"
    return fmt"1/{FreqDenominators[freq]}"
  return fmt"enum={freq} (always if >=7)"

proc printEnemy(e: EnemyRecord; tag = "") =
  ## One-line dump of a parsed enemy record.
  let prefix = if tag.len > 0: tag & " " else: ""
  let recOff = EnemyTableFileBase + e.id * EnemyRecordSize
  echo prefix, "id=", e.id, " name=[", e.name, "] HP=", e.hp,
    " PP=", e.pp, " EXP=", e.exp, " $=", e.money
  echo "  dropFreq=", e.dropFreq, " (", freqLabel(e.dropFreq),
    ") dropItem=0x", toHex(e.dropItemId, 2), " [", e.dropItemName, "]"
  echo "  recordFile=0x", toHex(recOff, 6)

proc expect(cond: bool; msg: string) =
  ## Fail the probe with a clear message when a structural check fails.
  if not cond:
    raise newException(AssertionDefect, msg)

proc main() =
  ## Load the user ROM, dump Starman Super + cross-checks, assert structure.
  let romPath = if paramCount() >= 1: paramStr(1) else: DefaultRomPath
  if not fileExists(romPath):
    raise newException(IOError, fmt"ROM not found: {romPath}")
  let rom = loadRomBytes(romPath)
  if rom.len < EnemyTableFileBase + 256 * EnemyRecordSize:
    raise newException(ValueError, "ROM too short for enemy table")

  echo "enemy table base file 0x", toHex(EnemyTableFileBase, 6),
    " SNES $D59589 stride 0x", toHex(EnemyRecordSize, 2)
  echo "fields: name+0x01 HP+0x21 PP+0x23 EXP+0x25 money+0x29 dropFreq+0x57 dropItem+0x58"
  echo ""

  let star = enemyRecord(rom, StarmanSuperId)
  printEnemy(star, "PRIMARY")

  expect(star.hp == StarmanSuperHp,
    fmt"id {StarmanSuperId} HP want {StarmanSuperHp} got {star.hp}")
  expect(star.dropFreq == 0,
    fmt"id {StarmanSuperId} dropFreq want 0 (1/128 path) got {star.dropFreq}")
  expect(star.dropItemId != 0, "Starman Super drop item id is 0")
  expect("Sword" in star.dropItemName,
    "drop item name should contain Sword, got: " & star.dropItemName)
  expect("king" in star.dropItemName.toLowerAscii,
    "drop item name should contain king, got: " & star.dropItemName)

  # Cross-checks: known differing drops (structural, not name literals in asserts).
  # ids: Bionic Kraken, Chomposaur, Black Antoid, Scalding Coffee Cup, Spiteful Crow.
  const CrossIds = [50, 36, 5, 43, 159]
  echo ""
  echo "CROSS-CHECKS"
  var seenFreqs: set[uint8]
  var seenItems: seq[int]
  for id in CrossIds:
    let e = enemyRecord(rom, id)
    printEnemy(e)
    expect(e.name.len > 0, fmt"id {id} empty name")
    expect(e.hp > 0, fmt"id {id} HP==0")
    seenFreqs.incl e.dropFreq.uint8
    if e.dropItemId notin seenItems:
      seenItems.add e.dropItemId

  expect(0.uint8 in seenFreqs or star.dropFreq == 0, "need a freq=0 (1/128) row")
  expect(seenFreqs.len + (if star.dropFreq.uint8 in seenFreqs: 0 else: 1) >= 3,
    fmt"cross-checks should span multiple freq enums, got {seenFreqs}")
  expect(seenItems.len >= 3,
    fmt"cross-checks should span multiple drop items, got {seenItems.len}")

  # Freq=5 → Cookie path, freq=7 → always: structural presence.
  let antoid = enemyRecord(rom, 5)
  expect(antoid.dropFreq == 5, fmt"id 5 freq want 5 got {antoid.dropFreq}")
  let crow = enemyRecord(rom, 159)
  expect(crow.dropFreq == 7, fmt"id 159 freq want 7 (always) got {crow.dropFreq}")
  let kraken = enemyRecord(rom, 50)
  expect(kraken.dropFreq == 0 and kraken.hp == 900,
    fmt"id 50 expect freq0 HP900 got freq={kraken.dropFreq} HP={kraken.hp}")
  let chomp = enemyRecord(rom, 36)
  expect(chomp.dropFreq == 0 and chomp.hp == 1288,
    fmt"id 36 expect freq0 HP1288 got freq={chomp.dropFreq} HP={chomp.hp}")

  # Mirror row 185 shares Starman Super stats/drop (formation alt id).
  let mirror = enemyRecord(rom, 185)
  expect(mirror.hp == StarmanSuperHp and mirror.dropItemId == star.dropItemId,
    "id 185 should mirror Starman Super HP/drop item")

  echo ""
  echo "OK probe_drop_table — Starman Super + cross-checks passed"

when isMainModule:
  main()
