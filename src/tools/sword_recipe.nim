## Sword of Kings recipe generator.
##
## From an overworld F12 (or raw .state) near a Starman Super, detect the
## window state class, scan B-status dwell frames N (1 RNG advance/frame via
## $C13CB4), close the window, approach the enemy, and read the battle-init
## drop roll at $C24DDC into $AA10. Prints human recipes for frame-advance
## and freehand seed targeting. Read-only: never pokes game state.
##
## Usage:
##   nim r src/tools/sword_recipe.nim <f12.png-or-.state> \
##     [--dir=left|right|up|down|up-left|up-right|down-left|down-right|wait|auto] \
##     [--max-n=127] [--horizon=900] [--rom=path]
##
## Exit: 0 recipe; 2 no approach reaches battle; 3 no N hits. Never copies
## or commits the input state.

import
  std/[os, options, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, policy, png_state,
    battle_formation, item_table]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  SeedWram = 0x0024
  Aa10Wram = 0xAA10
  WindowHeader0 = 0x8650
  WindowHeader1 = 0x8654
  WindowHeader2 = 0x8658
  WindowFocus = 0x8958
  BattleInitPbr = 0xC2'u8
  BattleInitPc = 0xB6FA'u16
  DropRollPbr = 0xC2'u8
  DropRollPc = 0x4DDC'u16
  BtnB = 0x8000'u16
  BtnUp = 0x0800'u16
  BtnDown = 0x0400'u16
  BtnLeft = 0x0200'u16
  BtnRight = 0x0100'u16
  StarmanSuperId = 68
  SwordItemId = 0x23
  DefaultMaxN = 127
  DefaultHorizon = 900
  BPressFrames = 2
  BReleaseFrames = 10
  MaxClosePulses = 12
  PostRollSettle = 300
  PostInitCap = 400
  BStatusType = 0x0A'u8
  CommandMenuType = 0x01'u8
  WindowFree = 0xFF'u8

type
  StateClass* = enum
    ## Overworld window state at F12 load (drives open/close script).
    scParkedOverworld ## Menus closed; B-open → dwell → B-close → walk.
    scBStatusOpen     ## $8654=0A spinner already free-running 1/frame.
    scCommandMenu     ## $8650=01; close first, then parked flow.
    scOther           ## Unknown headers; warn and treat like parked.

  WindowHeaders* = object
    ## Live text/window slot headers used for state-class detection.
    h8650*: uint8
    h8654*: uint8
    h8658*: uint8
    h8958*: uint8

  Approach* = object
    ## Walk (or wait) strategy to reach battle init from the parked spot.
    name*: string
    btn*: uint16

  StrategyResult* = object
    ## One approach attempt during auto-pick (exit-2 detail).
    name*: string
    initFrame*: int
    rollFrame*: int
    reached*: bool

  RunHit* = object
    ## One successful N scan / validation result.
    n*: int
    aa10*: int
    seedAtMenuClose*: uint32
    seedAtRoll*: uint32
    rollFrame*: int
    initFrame*: int
    formation*: string
    enemyIds*: seq[int]
    closePulses*: int
    stateClass*: StateClass
    approach*: string

const
  AllApproaches* = [
    Approach(name: "left", btn: BtnLeft),
    Approach(name: "right", btn: BtnRight),
    Approach(name: "up", btn: BtnUp),
    Approach(name: "down", btn: BtnDown),
    Approach(name: "up-left", btn: BtnUp or BtnLeft),
    Approach(name: "up-right", btn: BtnUp or BtnRight),
    Approach(name: "down-left", btn: BtnDown or BtnLeft),
    Approach(name: "down-right", btn: BtnDown or BtnRight),
    Approach(name: "wait", btn: 0),
  ]

proc readSeed*(snes: SnesBus): uint32 =
  ## 32-bit LE seed from WRAM $0024/$0026.
  let base = 0x7E0000 + SeedWram
  snes.bus.mem[base].uint32 or
    (snes.bus.mem[base + 1].uint32 shl 8) or
    (snes.bus.mem[base + 2].uint32 shl 16) or
    (snes.bus.mem[base + 3].uint32 shl 24)

proc readAa10(snes: SnesBus): int =
  ## Drop carry slot $AA10 as u16 LE.
  let base = 0x7E0000 + Aa10Wram
  snes.bus.mem[base].int or (snes.bus.mem[base + 1].int shl 8)

proc wramU8(snes: SnesBus, off: int): uint8 =
  ## One WRAM byte at 16-bit offset under bank $7E.
  snes.bus.mem[0x7E0000 + off]

proc readWindowHeaders*(snes: SnesBus): WindowHeaders =
  ## Snapshot window slot headers $8650/$8654/$8658 and focus $8958.
  WindowHeaders(
    h8650: wramU8(snes, WindowHeader0),
    h8654: wramU8(snes, WindowHeader1),
    h8658: wramU8(snes, WindowHeader2),
    h8958: wramU8(snes, WindowFocus),
  )

proc setWindowHeaders*(snes: SnesBus, h: WindowHeaders) =
  ## Write window headers (test harness / synthetic state class setup).
  snes.bus.mem[0x7E0000 + WindowHeader0] = h.h8650
  snes.bus.mem[0x7E0000 + WindowHeader1] = h.h8654
  snes.bus.mem[0x7E0000 + WindowHeader2] = h.h8658
  snes.bus.mem[0x7E0000 + WindowFocus] = h.h8958

proc detectStateClass*(snes: SnesBus): StateClass =
  ## Classify load-time window state for the open/dwell/close script branch.
  ##
  ## Priority: B-status spinner ($8654=0A) → command menu ($8650=01) →
  ## parked overworld (primary slots free) → other.
  let h = readWindowHeaders(snes)
  if h.h8654 == BStatusType:
    return scBStatusOpen
  if h.h8650 == CommandMenuType:
    return scCommandMenu
  if h.h8650 == WindowFree and h.h8654 == WindowFree:
    return scParkedOverworld
  scOther

proc stateClassName*(c: StateClass): string =
  ## Human label for a state class.
  case c
  of scParkedOverworld: "parked overworld (no menu)"
  of scBStatusOpen: "B-status window open (spinner 1/frame)"
  of scCommandMenu: "command menu open"
  of scOther: "other / unknown windows"

proc headersLine*(h: WindowHeaders): string =
  ## One-line header dump for logs.
  &"$8650={h.h8650:02X} $8654={h.h8654:02X} $8658={h.h8658:02X} $8958={h.h8958:02X}"

proc menusClosed*(snes: SnesBus): bool =
  ## True when primary window slots and focus are free.
  ##
  ## $8658 can stick non-FF after a clean close on some states; do not
  ## require it or B-pulse loops never terminate.
  let h = readWindowHeaders(snes)
  h.h8650 == WindowFree and h.h8654 == WindowFree and h.h8958 == WindowFree

proc loadStateBytes(snes: SnesBus, c: var Cpu, data: seq[byte]) =
  ## Apply a serialized save-state to a fresh machine.
  deserializeState(data, snes, c)

proc loadInputState(path: string): seq[byte] =
  ## Load state bytes from an F12 PNG (ebSt chunk) or raw .state file.
  if not fileExists(path):
    raise newException(IOError, &"input not found: {path}")
  let raw = cast[seq[uint8]](readFile(path))
  let ext = path.splitFile.ext.toLowerAscii
  if ext == ".png":
    let stOpt = extractState(raw)
    if stOpt.isNone:
      raise newException(IOError, &"no ebSt save-state embedded in {path}")
    return cast[seq[byte]](stOpt.get)
  cast[seq[byte]](raw)

proc stepFrameWatching(snes: SnesBus, c: var Cpu,
                       initAt, rollAt: var int, frame: int,
                       seedAtRoll: var uint32) =
  ## One headless frame: line-224 NMI, InstrPerLine steps, HDMA, APU×2.
  ## Records first PC hits at battle-init $C2B6FA and drop roll $C24DDC.
  var line = 0
  while line < 262:
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for _ in 0 ..< policy.InstrPerLine:
      if not (c.stopped or c.waiting):
        if c.pbr == BattleInitPbr and c.pc == BattleInitPc and initAt < 0:
          initAt = frame
        if c.pbr == DropRollPbr and c.pc == DropRollPc and rollAt < 0:
          rollAt = frame
          seedAtRoll = readSeed(snes)
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

proc stepFrameIdle(snes: SnesBus, c: var Cpu, joy: uint16) =
  ## One headless frame with fixed joypad (no init/roll watch).
  var initAt = -1
  var rollAt = -1
  var seedAtRoll = 0'u32
  snes.joy1 = joy
  stepFrameWatching(snes, c, initAt, rollAt, 0, seedAtRoll)

proc forkAndLoad(rom: seq[uint8], stateData: seq[byte]): tuple[snes: SnesBus, c: Cpu] =
  ## Fresh bus + CPU with the input state applied.
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  snes.initHdma()
  loadStateBytes(snes, c, stateData)
  (snes, c)

proc closeMenusWithB(snes: SnesBus, c: var Cpu): int =
  ## Pulse B until primary windows free; return pulse count used.
  result = 0
  while result < MaxClosePulses and not menusClosed(snes):
    for _ in 0 ..< BPressFrames:
      stepFrameIdle(snes, c, BtnB)
    for _ in 0 ..< BReleaseFrames:
      stepFrameIdle(snes, c, 0)
    inc result

proc runScript(rom: seq[uint8], stateData: seq[byte], dwellN: int,
               walkBtn: uint16, horizon: int, settleAfterRoll: int,
               stateClass: StateClass): RunHit =
  ## State-class-aware script: spinner dwell, approach, latched formation.
  ##
  ##   parked / other:     B-open → dwell N → B-close → approach
  ##   command menu:       B-open (dismisses cmd + opens status) → dwell → close → approach
  ##   B-status already:   dwell N → B-close → approach
  ##
  ## Command-menu note: a B press from $8650=01 leaves the command menu and
  ## opens the type-0A status spinner in one step (live + headless measured).
  ## A multi-pulse "close to free then re-open" path burns a different seed
  ## offset and is not used for the recipe dwell count.
  var machine = forkAndLoad(rom, stateData)
  var snes = machine.snes
  var c = machine.c
  var
    phase = 0
    phaseFrames = 0
    initAt = -1
    rollAt = -1
    seedAtMenuClose = 0'u32
    seedAtRoll = 0'u32
    menuCloseCaptured = false
    closePulses = 0
  let cls = if stateClass == scOther: scParkedOverworld else: stateClass
  # Needs an open phase when spinner is not already free-running.
  let needsOpen = cls in {scParkedOverworld, scCommandMenu, scOther}
  if needsOpen:
    phase = 0
    if cls == scCommandMenu:
      # One logical "open" pulse: B dismisses cmd menu into status.
      closePulses = 1
  else:
    phase = 1
  let maxFrames = BPressFrames + dwellN + BPressFrames + horizon +
    max(settleAfterRoll, PostInitCap) + 50
  for f in 0 ..< maxFrames:
    var joy: uint16 = 0
    case phase
    of 0:
      # B-open status spinner (also dismisses command menu when $8650=01).
      joy = BtnB
      if phaseFrames >= BPressFrames:
        phase = 1
        phaseFrames = -1
    of 1:
      # Dwell: spinner advances 1/frame while $8654=0A.
      if phaseFrames >= dwellN:
        phase = 2
        phaseFrames = -1
    of 2:
      # B-close.
      joy = BtnB
      if phaseFrames >= BPressFrames:
        if not menuCloseCaptured:
          seedAtMenuClose = readSeed(snes)
          menuCloseCaptured = true
        phase = 3
        phaseFrames = -1
    of 3:
      joy = walkBtn
      if initAt >= 0:
        phase = 4
        phaseFrames = -1
    else:
      joy = 0
    inc phaseFrames
    snes.joy1 = joy
    stepFrameWatching(snes, c, initAt, rollAt, f, seedAtRoll)
    if rollAt >= 0 and f > rollAt + settleAfterRoll:
      break
    if initAt >= 0 and rollAt < 0 and f > initAt + PostInitCap:
      break
    if phase == 3 and phaseFrames > horizon:
      break
  # LATCHED formation only after settle — arming mid-init latches $A970 ghosts
  # (Dept. Store Spook etc.). Clear, then poll until table-consistent.
  var latch: FormationLatch
  if initAt >= 0:
    clearFormationLatch(latch)
    for _ in 0 ..< LatchStableFrames + 6:
      stepFrameIdle(snes, c, 0)
      discard updateFormationLatch(snes, latch)
      if latch.latched:
        break
  result.n = dwellN
  result.aa10 = readAa10(snes)
  result.seedAtMenuClose = seedAtMenuClose
  result.seedAtRoll = seedAtRoll
  result.rollFrame = rollAt
  result.initFrame = initAt
  result.closePulses = closePulses
  result.stateClass = stateClass
  let form =
    if latch.latched:
      latchedFormation(latch)
    else:
      BattleFormation(enemies: @[], empty: true)
  result.formation = formationLine(form)
  result.enemyIds = @[]
  for e in form.enemies:
    result.enemyIds.add e.id
proc findApproach(name: string): Approach =
  ## Look up a named approach strategy.
  for a in AllApproaches:
    if a.name == name:
      return a
  raise newException(ValueError, &"unknown --dir={name}")

proc pickApproach(rom: seq[uint8], stateData: seq[byte], requested: string,
                  horizon: int, stateClass: StateClass): tuple[
                    approach: Approach, attempts: seq[StrategyResult]] =
  ## Resolve --dir=auto by trying each approach at N=0.
  ##
  ## Prefer approaches that hit both battle init and the $C24DDC drop roll.
  ## Init-only paths (no roll) are flaky — keep them as fallback only.
  result.attempts = @[]
  result.approach = Approach(name: "", btn: 0)
  var fallback: Approach
  if requested != "auto":
    let a = findApproach(requested)
    let h = if a.name == "wait": max(horizon, 2400) else: horizon
    let r = runScript(rom, stateData, 0, a.btn, h, 0, stateClass)
    var sr = StrategyResult(
      name: a.name,
      initFrame: r.initFrame,
      rollFrame: r.rollFrame,
      reached: r.initFrame >= 0,
    )
    result.attempts.add sr
    if r.initFrame >= 0 and r.rollFrame >= 0:
      result.approach = a
    elif r.initFrame >= 0:
      result.approach = a
    return
  for a in AllApproaches:
    let h = if a.name == "wait": max(horizon, 2400) else: horizon
    let r = runScript(rom, stateData, 0, a.btn, h, 0, stateClass)
    var sr = StrategyResult(
      name: a.name,
      initFrame: r.initFrame,
      rollFrame: r.rollFrame,
      reached: r.initFrame >= 0,
    )
    result.attempts.add sr
    let mark =
      if r.initFrame >= 0 and r.rollFrame >= 0: "REACHED+roll"
      elif r.initFrame >= 0: "init-only (no roll)"
      else: "miss"
    echo &"[auto] {a.name:>10}: init@{r.initFrame} roll@{r.rollFrame}  {mark}"
    if r.initFrame >= 0 and r.rollFrame >= 0 and result.approach.name.len == 0:
      result.approach = a
    elif r.initFrame >= 0 and fallback.name.len == 0:
      fallback = a
  if result.approach.name.len == 0:
    result.approach = fallback

proc hasStarmanSuper(ids: openArray[int]): bool =
  ## True if formation includes enemy id 68 (Starman Super).
  for id in ids:
    if id == StarmanSuperId:
      return true
  false

proc printUsage() =
  ## CLI usage line.
  echo "Usage: nim r src/tools/sword_recipe.nim <f12.png-or-.state> [options]"
  echo "  --dir=left|right|up|down|up-left|up-right|down-left|down-right|wait|auto"
  echo "  --max-n=N       dwell scan range 0..N (default 127; freehand often wants 511)"
  echo "  --horizon=N     approach frames before giving up (default 900; wait tries 2400)"
  echo "  --rom=path      path to EarthBound (U) ROM"
  echo "  Scans B-status dwell, approaches enemy, reports Sword recipe."
  echo "  Exit 0=recipe, 2=no battle entry, 3=no drop hit in range."

proc printFrameAdvanceScript(hit: RunHit, approach: string, horizon: int) =
  ## Exact frame-advance tap sequence for Space-pause play.
  echo ""
  echo "-------- (a) FRAME-ADVANCE SCRIPT --------"
  echo "REQUIRED: restore-then-execute. Live enemies drift from the captured"
  echo "positions even when the seed is parked. Space-pause → drag this PNG/state"
  echo "onto the play window (or load the .state) → then run the script."
  echo ""
  case hit.stateClass
  of scCommandMenu:
    echo &"  1. Restore F12/state (command menu is open — $8650=01)."
    echo &"  2. Hold B {BPressFrames} frames: dismisses command menu AND opens"
    echo &"     the B-status spinner ($8654=0A). One open pulse, not a free close."
    echo &"  3. Dwell {hit.n} frames (seed free-runs 1/frame; no buttons)."
    echo &"  4. Close spinner: hold B {BPressFrames} frames, release."
    echo &"  5. Confirm F8 seed == {hit.seedAtMenuClose:08X} at the close frame."
  of scBStatusOpen:
    echo &"  1. Restore F12/state (B-status spinner ALREADY open — seed spinning)."
    echo &"  2. Dwell {hit.n} frames (no buttons; 1 advance/frame)."
    echo &"  3. Close spinner: hold B {BPressFrames} frames, release."
    echo &"  4. Confirm F8 seed == {hit.seedAtMenuClose:08X} at the close frame."
  of scParkedOverworld, scOther:
    echo &"  1. Restore F12/state (menus closed / parked overworld)."
    echo &"  2. Open B-status spinner: hold B {BPressFrames} frames, release."
    echo &"  3. Dwell {hit.n} frames (seed free-runs 1/frame)."
    echo &"  4. Close spinner: hold B {BPressFrames} frames, release."
    echo &"  5. Confirm F8 seed == {hit.seedAtMenuClose:08X} at the close frame."
  if approach == "wait":
    echo &"  NEXT: wait in place (no walk) up to {horizon} frames for enemy chase."
  else:
    echo &"  NEXT: hold {approach} until battle swirl (init ≤{horizon}f horizon)."
  echo "  Then check $AA10 / Spy / win. Miss → flee, RESTORE again, re-dial."
  echo "------------------------------------------"

proc printFreehandTargets(hits: seq[RunHit], maxN: int) =
  ## Freehand seed targets + backup list for HUD dialing.
  echo ""
  echo "-------- (b) FREEHAND SEED TARGETS --------"
  echo "Dial the spinner (open B-status) until F8 is near the target, close B,"
  echo "confirm seed AT MENU-CLOSE, then execute the approach. Restore first."
  echo ""
  if hits.len == 0:
    echo "  (no hits)"
  else:
    echo &"  primary seed@close: {hits[0].seedAtMenuClose:08X}  (N={hits[0].n})"
    if hits.len > 1:
      echo "  backups (seed@close for every hit in range):"
      for h in hits:
        echo &"    N={h.n:>4}  seed@close={h.seedAtMenuClose:08X}  AA10={h.aa10:04X}"
    else:
      echo &"  only hit in 0..{maxN}: N={hits[0].n} seed@close={hits[0].seedAtMenuClose:08X}"
  echo "-------------------------------------------"

proc main() =
  ## CLI entry: load state, classify windows, pick approach, scan N, print recipe.
  if paramCount() < 1:
    printUsage()
    quit(1)

  var
    inputPath = ""
    dirName = "auto"
    romPath = DefaultRom
    maxN = DefaultMaxN
    horizon = DefaultHorizon
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--dir="):
      dirName = a[6 .. ^1].toLowerAscii
    elif a.startsWith("--rom="):
      romPath = a[6 .. ^1]
    elif a.startsWith("--max-n="):
      maxN = parseInt(a[8 .. ^1])
    elif a.startsWith("--horizon="):
      horizon = parseInt(a[10 .. ^1])
    elif a == "-h" or a == "--help":
      printUsage()
      quit(0)
    elif inputPath.len == 0:
      inputPath = a
    else:
      echo &"unexpected arg: {a}"
      printUsage()
      quit(1)

  if inputPath.len == 0:
    printUsage()
    quit(1)
  if maxN < 0:
    echo "--max-n must be >= 0"
    quit(1)
  if horizon < 1:
    echo "--horizon must be >= 1"
    quit(1)
  if not fileExists(romPath):
    echo &"ROM not found: {romPath}"
    quit(1)

  let
    rom = policy.readRomFile(romPath)
    stateData = loadInputState(inputPath)

  # State-class detection on a fresh load (no script side effects).
  let probe = forkAndLoad(rom, stateData)
  let headers = readWindowHeaders(probe.snes)
  let stateClass = detectStateClass(probe.snes)
  let seed0 = readSeed(probe.snes)

  echo &"Sword of Kings recipe — input: {inputPath}"
  echo &"ROM: {romPath}"
  echo &"load seed: {seed0:08X}"
  echo &"window headers: {headersLine(headers)}"
  echo &"state class: {stateClassName(stateClass)}"
  echo &"scan: B-status dwell N=0..{maxN}, dir={dirName}, horizon={horizon}"

  let pick = pickApproach(rom, stateData, dirName, horizon, stateClass)
  if pick.approach.name.len == 0:
    echo ""
    echo "ERROR: no approach reaches battle init ($C2B6FA)."
    echo "Per-strategy detail (re-F12 closer if all walk dirs miss; try"
    echo "--horizon=2400 or --dir=wait if the enemy chases):"
    for sr in pick.attempts:
      let mark = if sr.reached: "REACHED" else: "miss"
      echo &"  {sr.name:>10}: init@{sr.initFrame} roll@{sr.rollFrame}  {mark}"
    echo ""
    echo "Player guidance: if some wait/diagonal nearly hit, stand closer and"
    echo "re-F12; if every approach is a clean miss, the Starman may be out of"
    echo "reach from this park — re-F12 next to the spawn."
    quit(2)

  let approach = pick.approach
  var approachHorizon = horizon
  if approach.name == "wait":
    approachHorizon = max(horizon, 2400)
  echo &"approach: {approach.name} (horizon {approachHorizon}f)"
  echo "scanning..."

  var hits: seq[RunHit] = @[]
  for n in 0 .. maxN:
    var r = runScript(rom, stateData, n, approach.btn, approachHorizon, 2,
                      stateClass)
    r.approach = approach.name
    if r.initFrame < 0:
      if n mod 32 == 0:
        echo &"  N={n:>4}: no battle init within horizon"
      continue
    if r.rollFrame < 0:
      echo &"  N={n:>4}: init@{r.initFrame} but no $C24DDC roll"
      continue
    let mark = if r.aa10 != 0: "  <<< DROP" else: ""
    if r.aa10 != 0 or n mod 16 == 0:
      echo &"  N={n:>4}: roll@{r.rollFrame:>4} seed@close={r.seedAtMenuClose:08X} " &
        &"AA10={r.aa10:04X}{mark}"
    if r.aa10 != 0:
      hits.add r

  # Guarantee every hit printed seed@close (also when not on 16-grid).
  if hits.len > 0:
    echo ""
    echo "all hits (seed@close for every N):"
    for h in hits:
      echo &"  N={h.n:>4}  seed@close={h.seedAtMenuClose:08X}  AA10={h.aa10:04X}  " &
        &"roll@{h.rollFrame}"

  if hits.len == 0:
    echo ""
    echo &"ERROR: no N in 0..{maxN} produced a nonzero $AA10 drop roll."
    echo "Should be rare for Starman Super 1/128. Re-F12 and retry, or raise --max-n."
    quit(3)

  let winnerN = hits[0].n
  echo ""
  echo &"re-validating N={winnerN} (settle {PostRollSettle}f post-roll, LATCHED formation)..."
  let v = runScript(rom, stateData, winnerN, approach.btn, approachHorizon,
                    PostRollSettle, stateClass)
  if v.aa10 == 0:
    echo "WARN: re-run of winning N returned AA10=0 (timing race?); using scan hit."
  let aa10 = if v.aa10 != 0: v.aa10 else: hits[0].aa10
  let seedClose = if v.seedAtMenuClose != 0: v.seedAtMenuClose else: hits[0].seedAtMenuClose
  let formation = if v.formation.len > 0: v.formation else: hits[0].formation
  let enemyIds = if v.enemyIds.len > 0: v.enemyIds else: hits[0].enemyIds
  let closePulses = if v.closePulses > 0: v.closePulses else: hits[0].closePulses
  let itemName = itemName(rom, aa10)
  let itemLabel = if itemName.len > 0: itemName else: &"item_${aa10:02X}"

  var winner = hits[0]
  winner.aa10 = aa10
  winner.seedAtMenuClose = seedClose
  winner.formation = formation
  winner.enemyIds = enemyIds
  winner.closePulses = closePulses
  winner.approach = approach.name
  if v.aa10 != 0:
    winner.rollFrame = v.rollFrame
    winner.initFrame = v.initFrame
    winner.seedAtRoll = v.seedAtRoll

  echo ""
  echo "======== SWORD OF KINGS RECIPE ========"
  echo &"state class:                         {stateClassName(stateClass)}"
  echo &"target seed AT MENU-CLOSE (F8 HUD):  {seedClose:08X}"
  echo &"  (match this seed after closing the B-status window, then approach)"
  echo &"dwell frames (B-status window):      {winnerN}"
  echo &"approach:                            {approach.name}"
  echo &"formation (LATCHED):                 {formation}"
  echo &"item rolled ($AA10={aa10:04X}):         {itemLabel}"
  if hits.len > 1:
    var parts: seq[string] = @[]
    for h in hits:
      parts.add &"N={h.n}/{h.seedAtMenuClose:08X}"
    echo "if you overshoot: also " & parts.join(", ")
  else:
    echo &"if you overshoot: only hit in 0..{maxN} is N={winnerN}"
  echo "======================================="

  if formation.len == 0:
    echo ""
    echo "WARNING: LATCHED formation empty after settle — raw $A970 may have been"
    echo "ghost-only; treat enemy id as unverified for this run."
  elif not hasStarmanSuper(enemyIds):
    echo ""
    echo "WARNING: enemy id 68 (Starman Super) is NOT in the latched formation."
    echo "Plain Starman (and other spawns) do not carry the Sword of Kings."
    echo "Find another encounter — map sprites look the same."
  elif aa10 != SwordItemId:
    echo ""
    echo &"NOTE: rolled item id ${aa10:02X} is not Sword of kings ($23)."
    echo "Still a drop hit; recipe is valid for this item."

  printFrameAdvanceScript(winner, approach.name, approachHorizon)
  printFreehandTargets(hits, maxN)

  echo ""
  echo "How to execute live (summary):"
  echo "  0. ALWAYS restore the F12/state first — live enemies drift."
  echo "  1. Match state class + open/close taps from the frame-advance script."
  echo &"  2. Land seed@close {seedClose:08X} (or a backup), then {approach.name}."
  echo "  3. Miss → flee, restore, re-dial. Never finish the base without the sword."

when isMainModule:
  main()
