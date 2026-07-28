## Prove live battle formation: enemy ids in WRAM + runtime names.
##
## Loads `bin/states/slot200.state` (Starman Super fight) and asserts the
## `$A970` enemy-battler table yields id 68 with a name containing "Starman"
## and "Super". Headless; exit 0 on success. ROM + state are user-local.

import
  std/[os, strformat, strutils],
  ../decompbound/[snesbus, save_state, policy, battle_formation]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  StatePath = "bin/states/slot200.state"
  StarmanSuperId = 68
  StarmanSuperHp = 568

proc main() =
  ## Load the Starman Super state and verify formation lookup.
  if not fileExists(RomPath):
    raise newException(IOError, "ROM not found: " & RomPath)
  if not fileExists(StatePath):
    raise newException(IOError, "state not found: " & StatePath)

  let rom = policy.readRomFile(RomPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(StatePath)), snes, c)

  let form = readBattleFormation(snes)
  echo "formation: ", formationLine(form)
  echo "count=", form.enemies.len, " empty=", form.empty

  if form.empty:
    raise newException(AssertionDefect, "expected non-empty formation on slot200")

  var sawStar = false
  for e in form.enemies:
    echo &"  id={e.id} name=[{e.name}] HP={e.hp} battler=${e.battlerAddr:04X}"
    if e.id == StarmanSuperId:
      sawStar = true
      if e.hp != StarmanSuperHp:
        raise newException(AssertionDefect,
          &"Starman Super HP want {StarmanSuperHp} got {e.hp}")
      let n = e.name.toLowerAscii
      if "starman" notin n:
        raise newException(AssertionDefect, "name missing Starman: " & e.name)
      if "super" notin n:
        raise newException(AssertionDefect, "name missing Super: " & e.name)

  if not sawStar:
    raise newException(AssertionDefect,
      &"id {StarmanSuperId} not in formation: {formationLine(form)}")

  # Structural cross-check: ROM decode alone for id 68 matches WRAM name.
  let romName = decodeEnemyName(rom, StarmanSuperId)
  var wramName = ""
  for e in form.enemies:
    if e.id == StarmanSuperId:
      wramName = e.name
      break
  if romName != wramName:
    raise newException(AssertionDefect,
      &"ROM vs WRAM name mismatch: [{romName}] vs [{wramName}]")

  echo "OK: Starman Super id 68 present via $A970 battler+0"

when isMainModule:
  main()
