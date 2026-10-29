import
  ./party_sram

type
  EbConditions* = array[CharConditionsLen, uint8]
  EbUiStatusTables* = object
    icons*: array[CharConditionsLen * CharConditionsLen, uint16]
    palettes*: array[CharConditionsLen * CharConditionsLen, uint16]

const
  ConditionIcons = 0x045A27
  ConditionPalettes = 0x045AEB
  NoConditionIcon = 7'u16
  NoConditionPalette = 4'u16

proc loadEbUiStatusTables*(rom: openArray[uint8]): EbUiStatusTables =
  ## Load the tables indexed by original $C223D9 and $C22474 from this ROM.
  if rom.len < ConditionPalettes + result.palettes.len * 2:
    raise newException(ValueError, "ROM is too short for EarthBound UI status tables")
  for index in 0 ..< result.palettes.len:
    let
      icon = ConditionIcons + index * 2
      palette = ConditionPalettes + index * 2
    result.icons[index] = rom[icon].uint16 or (rom[icon + 1].uint16 shl 8)
    result.palettes[index] = rom[palette].uint16 or (rom[palette + 1].uint16 shl 8)

proc conditionIndex(conditions: EbConditions): int =
  ## Reproduce the condition priority shared by $C223D9 and $C22474.
  var group = -1
  if conditions[0] != 0:
    group = 0
  elif conditions[3] != 0:
    group = 3
  else:
    for index in 1 ..< conditions.len:
      if conditions[index] != 0:
        group = index
        break
  if group < 0: return -1
  let value = conditions[group].int
  if value > CharConditionsLen:
    raise newException(ValueError, "Invalid EarthBound condition value: " & $value)
  group * CharConditionsLen + value - 1

proc conditionIcon*(tables: EbUiStatusTables, conditions: EbConditions): uint16 =
  ## Return the original status icon selector, including the empty selector.
  let index = conditionIndex(conditions)
  if index < 0: NoConditionIcon else: tables.icons[index]

proc conditionPalette*(tables: EbUiStatusTables, conditions: EbConditions): int =
  ## Return the original status interior palette number, with four for normal.
  let index = conditionIndex(conditions)
  int(if index < 0: NoConditionPalette else: tables.palettes[index])
