## Sword of Kings recipe generator.
##
## From an overworld F12 (or raw .state) near a Starman Super, scan B-status
## window dwell frames N=0..127 (1 RNG advance/frame via $C13CB4), close the
## window, walk into the enemy, and read the battle-init drop roll at $C24DDC
## into $AA10. Prints a human recipe: target seed at menu-close, dwell N,
## walk direction, formation, item name, and every other hit in range.
##
## Usage:
##   nim r src/tools/sword_recipe.nim <f12.png-or-.state> [--dir=left|right|up|down|auto]
##
## Exit: 0 recipe; 2 no direction reaches battle; 3 no N hits. Never copies
## or commits the input state.

import
  std/[os, options, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, policy, png_state,
    battle_formation, item_table]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  SeedWram = 0x0024
  Aa10Wram = 0xAA10
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
  DwellScanMax = 127
  BPressFrames = 2
  MaxWalkFrames = 600
  PostRollSettle = 300
  PostInitCap = 400

type
  DirChoice = object
    name: string
    btn: uint16

  RunHit = object
    n: int
    aa10: int
    seedAtMenuClose: uint32
    seedAtRoll: uint32
    rollFrame: int
    initFrame: int
    formation: string
    enemyIds: seq[int]

const
  AllDirs = [
    DirChoice(name: "left", btn: BtnLeft),
    DirChoice(name: "right", btn: BtnRight),
    DirChoice(name: "up", btn: BtnUp),
    DirChoice(name: "down", btn: BtnDown),
  ]

proc readSeed(snes: SnesBus): uint32 =
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

proc loadStateBytes(snes: SnesBus, cpu: var Cpu, data: seq[byte]) =
  ## Apply a serialized save-state to a fresh machine.
  deserializeState(data, snes, cpu)

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

proc stepFrameWatching(snes: SnesBus, cpu: var Cpu,
                       initAt, rollAt: var int, frame: int,
                       seedAtRoll: var uint32) =
  ## One headless frame: line-224 NMI, InstrPerLine steps, HDMA, APU×2.
  ## Records first PC hits at battle-init $C2B6FA and drop roll $C24DDC.
  var line = 0
  while line < 262:
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for _ in 0 ..< policy.InstrPerLine:
      if not (cpu.stopped or cpu.waiting):
        if cpu.pbr == BattleInitPbr and cpu.pc == BattleInitPc and initAt < 0:
          initAt = frame
        if cpu.pbr == DropRollPbr and cpu.pc == DropRollPc and rollAt < 0:
          rollAt = frame
          seedAtRoll = readSeed(snes)
      cpu.step(snes.bus)
      if cpu.stopped:
        break
    if line < 224:
      snes.runHdma()
    for k in 0 ..< 2:
      discard snes.tickApu()
    inc line
    if line >= 262:
      snes.initHdma()
      break

proc forkAndLoad(rom: seq[uint8], stateData: seq[byte]): tuple[snes: SnesBus, cpu: Cpu] =
  ## Fresh bus + CPU with the input state applied.
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()
  loadStateBytes(snes, cpu, stateData)
  (snes, cpu)

proc runScript(rom: seq[uint8], stateData: seq[byte], dwellN: int,
               walkBtn: uint16, settleAfterRoll: int): RunHit =
  ## B-open 2f → dwell N → B-close 2f → walk until init/roll → optional settle.
  var machine = forkAndLoad(rom, stateData)
  var snes = machine.snes
  var cpu = machine.cpu
  var
    phase = 0
    phaseFrames = 0
    initAt = -1
    rollAt = -1
    seedAtMenuClose = 0'u32
    seedAtRoll = 0'u32
    menuCloseCaptured = false
  let maxFrames = BPressFrames + dwellN + BPressFrames + MaxWalkFrames +
    max(settleAfterRoll, PostInitCap) + 50
  for f in 0 ..< maxFrames:
    var joy: uint16 = 0
    case phase
    of 0:
      joy = BtnB
      if phaseFrames >= BPressFrames:
        phase = 1
        phaseFrames = -1
    of 1:
      if phaseFrames >= dwellN:
        phase = 2
        phaseFrames = -1
    of 2:
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
    stepFrameWatching(snes, cpu, initAt, rollAt, f, seedAtRoll)
    if rollAt >= 0 and f > rollAt + settleAfterRoll:
      break
    if initAt >= 0 and rollAt < 0 and f > initAt + PostInitCap:
      break
    if phase == 3 and phaseFrames > MaxWalkFrames:
      break
  result.n = dwellN
  result.aa10 = readAa10(snes)
  result.seedAtMenuClose = seedAtMenuClose
  result.seedAtRoll = seedAtRoll
  result.rollFrame = rollAt
  result.initFrame = initAt
  let form = readBattleFormation(snes)
  result.formation = formationLine(form)
  result.enemyIds = @[]
  for e in form.enemies:
    result.enemyIds.add e.id

proc pickDirection(rom: seq[uint8], stateData: seq[byte],
                   requested: string): DirChoice =
  ## Resolve --dir=auto by trying each direction at N=0 until battle init fires.
  if requested != "auto":
    for d in AllDirs:
      if d.name == requested:
        return d
    raise newException(ValueError, &"unknown --dir={requested}")
  for d in AllDirs:
    let r = runScript(rom, stateData, 0, d.btn, 0)
    if r.initFrame >= 0:
      echo &"[auto] battle init via {d.name} at frame {r.initFrame}"
      return d
  DirChoice(name: "", btn: 0)

proc hasStarmanSuper(ids: openArray[int]): bool =
  ## True if formation includes enemy id 68 (Starman Super).
  for id in ids:
    if id == StarmanSuperId:
      return true
  false

proc printUsage() =
  ## CLI usage line.
  echo "Usage: nim r src/tools/sword_recipe.nim <f12.png-or-.state> [--dir=left|right|up|down|auto]"
  echo "  Scans B-status dwell N=0..127, walks into enemy, reports Sword recipe."
  echo "  Exit 0=recipe, 2=no battle entry, 3=no drop hit in range."

proc main() =
  ## CLI entry: load state, pick direction, scan N, validate, print recipe.
  if paramCount() < 1:
    printUsage()
    quit(1)

  var
    inputPath = ""
    dirName = "auto"
    romPath = DefaultRom
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--dir="):
      dirName = a[6 .. ^1].toLowerAscii
    elif a.startsWith("--rom="):
      romPath = a[6 .. ^1]
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
  if not fileExists(romPath):
    echo &"ROM not found: {romPath}"
    quit(1)

  let
    rom = policy.readRomFile(romPath)
    stateData = loadInputState(inputPath)

  echo &"Sword of Kings recipe — input: {inputPath}"
  echo &"ROM: {romPath}"
  echo &"scan: B-status dwell N=0..{DwellScanMax}, dir={dirName}"

  let dir = pickDirection(rom, stateData, dirName)
  if dir.name.len == 0:
    echo ""
    echo "ERROR: no direction reaches battle init ($C2B6FA)."
    echo "F12 closer to the enemy on the overworld, then re-run."
    quit(2)

  echo &"walk direction: {dir.name}"
  echo "scanning..."

  var hits: seq[RunHit] = @[]
  for n in 0 .. DwellScanMax:
    let r = runScript(rom, stateData, n, dir.btn, 2)
    if r.initFrame < 0:
      echo &"  N={n:>3}: no battle init within walk window"
      continue
    if r.rollFrame < 0:
      echo &"  N={n:>3}: init@{r.initFrame} but no $C24DDC roll"
      continue
    let mark = if r.aa10 != 0: "  <<< DROP" else: ""
    if r.aa10 != 0 or n mod 16 == 0:
      echo &"  N={n:>3}: roll@{r.rollFrame:>4} seed@close={r.seedAtMenuClose:08X} " &
        &"AA10={r.aa10:04X}{mark}"
    if r.aa10 != 0:
      hits.add r

  if hits.len == 0:
    echo ""
    echo "ERROR: no N in 0..127 produced a nonzero $AA10 drop roll."
    echo "Should be rare (~impossible for Starman Super 1/128). Re-F12 and retry."
    quit(3)

  let winnerN = hits[0].n
  echo ""
  echo &"re-validating N={winnerN} (settle {PostRollSettle}f post-roll)..."
  let v = runScript(rom, stateData, winnerN, dir.btn, PostRollSettle)
  if v.aa10 == 0:
    echo "WARN: re-run of winning N returned AA10=0 (timing race?); using scan hit."
  let aa10 = if v.aa10 != 0: v.aa10 else: hits[0].aa10
  let seedClose = if v.seedAtMenuClose != 0: v.seedAtMenuClose else: hits[0].seedAtMenuClose
  let formation = if v.formation.len > 0: v.formation else: hits[0].formation
  let enemyIds = if v.enemyIds.len > 0: v.enemyIds else: hits[0].enemyIds
  let itemName = itemName(rom, aa10)
  let itemLabel = if itemName.len > 0: itemName else: &"item_${aa10:02X}"

  var hitNs: seq[string] = @[]
  for h in hits:
    hitNs.add $h.n
  let hitList = hitNs.join(", ")

  echo ""
  echo "======== SWORD OF KINGS RECIPE ========"
  echo &"target seed AT MENU-CLOSE (F8 HUD):  {seedClose:08X}"
  echo &"  (match this seed after closing the B-status window, then bump)"
  echo &"dwell frames (B-status window):      {winnerN}"
  echo &"walk direction:                      {dir.name}"
  echo &"formation:                           {formation}"
  echo &"item rolled ($AA10={aa10:04X}):         {itemLabel}"
  if hits.len > 1:
    echo &"if you overshoot: seeds also work at N={hitList}"
  else:
    echo &"if you overshoot: only hit in 0..{DwellScanMax} is N={winnerN}"
  echo "======================================="

  if not hasStarmanSuper(enemyIds):
    echo ""
    echo "WARNING: enemy id 68 (Starman Super) is NOT in the formation."
    echo "Plain Starman (and other spawns) do not carry the Sword of Kings."
    echo "Find another encounter — map sprites look the same."
  elif aa10 != SwordItemId:
    echo ""
    echo &"NOTE: rolled item id ${aa10:02X} is not Sword of kings ($23)."
    echo "Still a drop hit; recipe is valid for this item."

  echo ""
  echo "How to execute live:"
  echo "  1. Park on overworld next to the enemy (menus closed)."
  echo "  2. Hold B to open the status spinner; dwell until F8 seed is close,"
  echo &"     or open B, wait exactly {winnerN} frames, close with B."
  echo &"  3. Confirm seed on F8 HUD equals {seedClose:08X} at menu close."
  echo &"  4. Walk {dir.name} into the enemy; check $AA10 / Spy / win."
  echo "  5. Miss → flee, re-dial seed, repeat. Never finish the base without it."

when isMainModule:
  main()
