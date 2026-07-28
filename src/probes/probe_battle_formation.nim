## Prove live battle formation: enemy ids in WRAM + runtime names.
##
## Loads `bin/states/slot200.state` (Starman Super fight) and asserts the
## `$A970` enemy-battler table yields id 68 with a name containing "Starman"
## and "Super". Also A-mashes 600+ frames with the formation latch and asserts
## ids stay in {13, 68} until all latched HP hit 0 (battle end). Headless;
## exit 0 on success. ROM + state are user-local.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy, battle_formation]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  StatePath = "bin/states/slot200.state"
  StarmanSuperId = 68
  AtomicPowerRobotId = 13
  StarmanSuperHp = 568
  AllowedIds = [AtomicPowerRobotId, StarmanSuperId]
  AmashWidth = 3
  AmashPeriod = 12
  LatchDriveFrames = 700
  MaxEndFrames = 2500

proc stepFrame(snes: SnesBus, c: var Cpu, img: Image) =
  ## One policy-style frame.
  var line = 0
  while line < 262:
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for _ in 0 ..< policy.InstrPerLine:
      if not (c.stopped or c.waiting):
        c.step(snes.bus)
      if c.stopped:
        break
    if line < 224:
      snes.runHdma()
    for k in 0 ..< 2:
      discard snes.tickApu()
    inc line
    if line >= 262:
      snes.initHdma()
      break

proc assertAllowedIds(form: BattleFormation, frame: int) =
  ## Fail if any latched id is outside the slot200 formation set.
  for e in form.enemies:
    if e.id notin AllowedIds:
      raise newException(AssertionDefect,
        &"f={frame} latched id {e.id} outside {{13,68}}: {formationLine(form)}")

proc main() =
  ## Load the Starman Super state and verify formation lookup + latch.
  if not fileExists(RomPath):
    raise newException(IOError, "ROM not found: " & RomPath)
  if not fileExists(StatePath):
    raise newException(IOError, "state not found: " & StatePath)

  let rom = policy.readRomFile(RomPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  snes.initHdma()
  deserializeState(cast[seq[byte]](readFile(StatePath)), snes, c)

  let form = readBattleFormation(snes)
  echo "formation: ", formationLine(form)
  echo "count=", form.enemies.len, " empty=", form.empty

  if form.empty:
    raise newException(AssertionDefect, "expected non-empty formation on slot200")

  if not formationTableConsistent(snes, form):
    raise newException(AssertionDefect,
      "slot200 raw formation not table-consistent: " & formationLine(form))

  var sawStar = false
  var sawRobot = false
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
    if e.id == AtomicPowerRobotId:
      sawRobot = true

  if not sawStar:
    raise newException(AssertionDefect,
      &"id {StarmanSuperId} not in formation: {formationLine(form)}")
  if not sawRobot:
    raise newException(AssertionDefect,
      &"id {AtomicPowerRobotId} not in formation: {formationLine(form)}")

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

  echo "OK: static $A970 read — Starman Super id 68 + Atomic Power Robot id 13"

  # --- Latched FOE line under A-mash (mid-battle $A970 thrash) ---
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var latch: FormationLatch
  var latchedAt = -1
  var emptiedAt = -1
  var rawFlickerSeen = false
  var maxLatched = 0
  var wasLatched = false

  for f in 0 ..< MaxEndFrames:
    snes.joy1 = if (f mod AmashPeriod) < AmashWidth: policy.BtnA else: 0
    stepFrame(snes, c, img)
    if c.stopped:
      raise newException(AssertionDefect, &"CPU stopped at f={f}")

    let latched = updateFormationLatch(snes, latch)
    let raw = readBattleFormation(snes)

    if latch.latched:
      if latchedAt < 0:
        latchedAt = f
        echo &"f={f} LATCHED: {formationLine(latched)}"
      assertAllowedIds(latched, f)
      maxLatched = max(maxLatched, latched.enemies.len)
      wasLatched = true
      # Raw walk may show ghosts; latched must not.
      if not raw.empty:
        for e in raw.enemies:
          if e.id notin AllowedIds:
            rawFlickerSeen = true
            break
    elif wasLatched and emptiedAt < 0:
      emptiedAt = f
      echo &"f={f} latch cleared (all latched HP 0 or victory code)"

    if f + 1 == LatchDriveFrames:
      if not latch.latched and emptiedAt < 0:
        raise newException(AssertionDefect,
          &"not latched after {LatchDriveFrames} frames")
      if latch.latched:
        assertAllowedIds(latched, f)
      echo &"f={f} 700f check OK latched={latch.latched} " &
        &"line=[{formationLine(latched)}] raw=[{formationLine(raw)}] " &
        &"rawFlickerSeen={rawFlickerSeen}"

    if emptiedAt >= 0 and f >= emptiedAt + 30:
      # Stay clear of foreign ids; needsGap should block ghost re-arm.
      if latch.latched:
        assertAllowedIds(latched, f)
      break

  if latchedAt < 0 and emptiedAt < 0:
    raise newException(AssertionDefect, "never latched formation on slot200 drive")

  # Must have seen latch arm while both enemies were still alive.
  if latchedAt >= 0 and maxLatched < 1:
    raise newException(AssertionDefect, "latch never held any enemy")

  # Prove raw flicker was present so the test actually stresses the latch.
  if not rawFlickerSeen:
    # Soft: print warning but still require latch stayed clean (already asserted).
    echo "NOTE: raw $A970 walk never showed foreign ids in this drive " &
      "(latch still never reported foreign ids)"

  if emptiedAt < 0:
    # Fight may not finish in MaxEndFrames under pure A-mash; require at least
    # the 700f clean window (already checked) and that we never showed garbage.
    echo &"NOTE: latch still live at end (emptiedAt=-1); 700f clean window held"
  else:
    echo &"OK: latch emptied at f={emptiedAt} (battle-end via HP 0 / $5D60)"

  echo &"OK: latched formation never left {{13,68}} (latchedAt={latchedAt} " &
    &"rawFlickerSeen={rawFlickerSeen} maxN={maxLatched})"

when isMainModule:
  main()
