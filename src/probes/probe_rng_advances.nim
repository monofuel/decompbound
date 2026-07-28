## Action → RNG-advances evidence table for Sword of Kings Layer 0.
##
## Loads a local savestate (CLI arg or defaults) and scripts inputs headlessly
## while counting $C08E9A entries (return-address callers + seed write PCs).
## Never commits states; paths are local-only CLI defaults.
##
## Usage:
##   nim r src/probes/probe_rng_advances.nim [rom] [overworld.state] [battle.state] [menu.state]
##
## Defaults pick first existing local state from known free-walk / mid-battle /
## menu-open candidates under bin/states/ (and optional secret paths if present).

import
  std/[os, strformat, strutils, tables, algorithm],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  RngPbr = 0xC0'u8
  RngPc = 0x8E9A'u16
  RngPcEnd = 0x8ED1'u16
  SeedWram = 0x0024
  WindowHeader0 = 0x8650
  WindowHeader1 = 0x8654
  ## Free-walk / overworld candidates (prefer outdoor for A→command menu).
  OverworldCandidates = [
    "bin/states/llm/leave_onett_walkable.state",
    "bin/states/llm/fourside60_freewalk.state",
    "bin/states/llm/poo_free_outdoor.state",
    "bin/states/llm/onett_start.state",
    "bin/states/llm/home_indoor.state",
    "bin/states/llm/home_door.state",
    "bin/states/game_start.state",
  ]
  ## States already sitting on overworld command menu ($8650 == $01).
  MenuOpenCandidates = [
    "bin/states/llm/poo_deep_south.state",
    "bin/states/llm/poo_high_bitpop.state",
    "bin/states/llm/fourside_deep_prepoo.state",
    "bin/states/llm/south_freeze_fr90.state",
    "bin/states/slot130.state",
    "bin/states/slot73.state",
    "bin/states/slot76.state",
    "bin/states/slot77.state",
  ]
  BattleCandidates = [
    "bin/states/battle_menu_healthy.state",
    "bin/states/battle_fixture.state",
    "bin/states/live_battle_catch.state",
    "bin/states/slot1_battle.state",
  ]
  ## Dialogue-ish slot1 open.
  DialogueCandidates = [
    "bin/states/llm/home_downstairs_night.state",
    "bin/states/llm/midgame_wander.state",
    "bin/states/llm/pokey_done.state",
    "bin/states/slot79.state",
    "bin/states/slot85.state",
  ]

type
  RngCounter = object
    calls: int
    callers: CountTable[uint32]

proc readSeed(snes: SnesBus): uint32 =
  ## 32-bit LE seed from WRAM $0024.
  let base = 0x7E0000 + SeedWram
  snes.bus.mem[base].uint32 or
    (snes.bus.mem[base + 1].uint32 shl 8) or
    (snes.bus.mem[base + 2].uint32 shl 16) or
    (snes.bus.mem[base + 3].uint32 shl 24)

proc wram8(snes: SnesBus, off: int): uint8 =
  ## Byte at WRAM $7E:off.
  snes.bus.mem[0x7E0000 + off]

proc isCmdMenuOpen(snes: SnesBus): bool =
  ## Overworld command menu signature used by escapeMenu: $8650 == $01.
  wram8(snes, WindowHeader0) == 0x01

proc isAnyWindow0(snes: SnesBus): bool =
  ## Slot 0 allocated (not free).
  wram8(snes, WindowHeader0) != 0xFF

proc isDialogueish(snes: SnesBus): bool =
  ## Slot 1 allocated or live dialogue stream bank in $C0-$CF.
  if wram8(snes, WindowHeader1) != 0xFF:
    return true
  let bank = wram8(snes, 0x96C7)
  bank >= 0xC0 and bank <= 0xCF

proc inRngBody(cpu: Cpu): bool =
  ## True while PC is inside the RNG routine body.
  cpu.pbr == RngPbr and cpu.pc >= RngPc and cpu.pc <= RngPcEnd

proc stepFrameCounting(snes: SnesBus, cpu: var Cpu, img: Image, ctr: var RngCounter) =
  ## One policy-style frame, counting $C08E9A entries and RTL return PCs.
  var
    line = 0
    inRoutine = false
  while line < 262:
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for _ in 0 ..< policy.InstrPerLine:
      if not (cpu.stopped or cpu.waiting):
        if not inRoutine and cpu.pbr == RngPbr and cpu.pc == RngPc:
          inRoutine = true
          inc ctr.calls
        cpu.step(snes.bus)
        if inRoutine and not inRngBody(cpu):
          let ret = (cpu.pbr.uint32 shl 16) or cpu.pc.uint32
          ctr.callers.inc(ret)
          inRoutine = false
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

proc loadMachine(rom: seq[uint8], statePath: string): tuple[snes: SnesBus, cpu: Cpu] =
  ## Fresh bus + CPU, optional savestate.
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()
  if statePath.len > 0 and fileExists(statePath):
    deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)
  (snes, cpu)

proc findFirst(paths: openArray[string]): string =
  ## First existing path, or empty.
  for p in paths:
    if fileExists(p):
      return p
  ""

proc topCallers(ctr: RngCounter, n = 8): string =
  ## Format top-N return addresses with counts.
  var pairs: seq[(uint32, int)] = @[]
  for k, v in ctr.callers:
    pairs.add (k, v)
  pairs.sort(proc(a, b: (uint32, int)): int = cmp(b[1], a[1]))
  if pairs.len == 0:
    return "(none)"
  var parts: seq[string] = @[]
  for i in 0 ..< min(n, pairs.len):
    let (pcFull, cnt) = pairs[i]
    parts.add &"${pcFull:06X}×{cnt}"
  parts.join(", ")

proc always(btn: uint16): proc(f: int): uint16 =
  ## Constant joy1.
  result = proc(f: int): uint16 = btn

proc pulse(btn: uint16, every: int, width: int): proc(f: int): uint16 =
  ## Pulse `btn` for `width` frames every `every` frames.
  result = proc(f: int): uint16 =
    if every > 0 and (f mod every) < width: btn else: 0'u16

proc runSegment(label: string, rom: seq[uint8], statePath: string,
                frames: int, joySchedule: proc(f: int): uint16): RngCounter =
  ## Load state, run `frames` with joySchedule(f), report call counts.
  var (snes, cpu) = loadMachine(rom, statePath)
  var ctr: RngCounter
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let seed0 = readSeed(snes)
  for f in 0 ..< frames:
    snes.joy1 = joySchedule(f)
    stepFrameCounting(snes, cpu, img, ctr)
    if cpu.stopped:
      break
  let seed1 = readSeed(snes)
  echo &"[{label}] frames={frames} calls={ctr.calls} " &
    &"seed {seed0:08X}→{seed1:08X} " &
    &"8650={wram8(snes, WindowHeader0):02X} " &
    &"callers=[{topCallers(ctr)}]"
  ctr

proc main() =
  ## Measure RNG advances for overworld / menu / dialogue / battle action classes.
  let
    romPath = if paramCount() >= 1: paramStr(1) else: DefaultRom
    owArg = if paramCount() >= 2: paramStr(2) else: ""
    battleArg = if paramCount() >= 3: paramStr(3) else: ""
    menuArg = if paramCount() >= 4: paramStr(4) else: ""
  if not fileExists(romPath):
    echo &"ROM not found: {romPath}"
    quit(1)
  let rom = policy.readRomFile(romPath)
  let owState =
    if owArg.len > 0: owArg
    else: findFirst(OverworldCandidates)
  let battleState =
    if battleArg.len > 0: battleArg
    else: findFirst(BattleCandidates)
  let menuState =
    if menuArg.len > 0: menuArg
    else: findFirst(MenuOpenCandidates)
  let dlgState = findFirst(DialogueCandidates)

  echo "=== probe_rng_advances (Layer 0 action → advances) ==="
  echo &"rom={romPath}"
  echo &"overworld_state={owState}"
  echo &"menu_open_state={menuState}"
  echo &"dialogue_state={dlgState}"
  echo &"battle_state={battleState}"
  if owState.len == 0:
    echo "ERROR: no overworld state found (pass path as arg 2)"
    quit(1)

  # --- Overworld idle ---
  discard runSegment("overworld_idle_60f", rom, owState, 60, always(0))
  discard runSegment("overworld_idle_180f", rom, owState, 180, always(0))

  # --- Walking ---
  discard runSegment("overworld_walk_right_60f", rom, owState, 60, always(policy.BtnRight))
  discard runSegment("overworld_walk_down_60f", rom, owState, 60, always(policy.BtnDown))

  # --- Menu open via A (overworld command menu: Talk/Goods/…) ---
  block menuOpenAttempt:
    var (snes, cpu) = loadMachine(rom, owState)
    var ctr: RngCounter
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    for f in 0 ..< 10:
      snes.joy1 = 0
      stepFrameCounting(snes, cpu, img, ctr)
    let before = ctr.calls
    # Short A pulse then wait (rising-edge style)
    for f in 0 ..< 3:
      snes.joy1 = policy.BtnA
      stepFrameCounting(snes, cpu, img, ctr)
    var openedAt = -1
    for f in 0 ..< 90:
      snes.joy1 = 0
      stepFrameCounting(snes, cpu, img, ctr)
      if isCmdMenuOpen(snes) and openedAt < 0:
        openedAt = f
    echo &"[menu_open_A] openedAt={openedAt} calls={ctr.calls - before} " &
      &"8650={wram8(snes, WindowHeader0):02X} callers=[{topCallers(ctr)}]"

  # --- CRITICAL: menu-open DWELL from a state already on the command menu ---
  if menuState.len > 0:
    block menuDwell:
      var (snes, cpu) = loadMachine(rom, menuState)
      if not isAnyWindow0(snes):
        echo &"[menu_open_dwell] state {menuState} has 8650={wram8(snes, WindowHeader0):02X} (not open?)"
      var dwell: RngCounter
      let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
      let seedD0 = readSeed(snes)
      const DwellFrames = 120
      for f in 0 ..< DwellFrames:
        snes.joy1 = 0
        stepFrameCounting(snes, cpu, img, dwell)
      let seedD1 = readSeed(snes)
      let perFrame = dwell.calls.float / DwellFrames.float
      echo &"[menu_open_dwell_{DwellFrames}f] state={menuState.splitPath.tail} " &
        &"calls={dwell.calls} per_frame={perFrame:.4f} " &
        &"seed {seedD0:08X}→{seedD1:08X} " &
        &"8650={wram8(snes, WindowHeader0):02X} callers=[{topCallers(dwell)}]"
      if dwell.calls == 0:
        echo "  → open menu idle does NOT consume RNG (event-driven; dwell-safe for human timing)"
      else:
        echo &"  → open menu idle DOES consume RNG ({dwell.calls} in {DwellFrames}f)"

      # Cursor move (Down pulses) while menu open
      var cur: RngCounter
      let seedC0 = readSeed(snes)
      for f in 0 ..< 60:
        snes.joy1 = if (f mod 12) < 3: policy.BtnDown else: 0'u16
        stepFrameCounting(snes, cpu, img, cur)
      echo &"[menu_cursor_down_60f] calls={cur.calls} seed {seedC0:08X}→{readSeed(snes):08X} " &
        &"8650={wram8(snes, WindowHeader0):02X} callers=[{topCallers(cur)}]"

      # Close with B
      var clo: RngCounter
      let seedCl0 = readSeed(snes)
      for f in 0 ..< 4:
        snes.joy1 = policy.BtnB
        stepFrameCounting(snes, cpu, img, clo)
      var closedAt = -1
      for f in 0 ..< 60:
        snes.joy1 = 0
        stepFrameCounting(snes, cpu, img, clo)
        if not isAnyWindow0(snes) and closedAt < 0:
          closedAt = f
      echo &"[menu_close_B] calls={clo.calls} closedAt={closedAt} " &
        &"seed {seedCl0:08X}→{readSeed(snes):08X} " &
        &"8650={wram8(snes, WindowHeader0):02X} callers=[{topCallers(clo)}]"
  else:
    echo "[menu_open_dwell] BLOCKED — no local state with overworld menu open ($8650=$01)"

  # --- Dialogue ---
  if dlgState.len > 0:
    discard runSegment("dialogue_idle_60f", rom, dlgState, 60, always(0))
    discard runSegment("dialogue_A_tick_90f", rom, dlgState, 90,
      pulse(policy.BtnA, every = 20, width = 3))
  else:
    echo "[dialogue_*] no dialogue-open state found; A-mash on overworld:"
    discard runSegment("dialogue_attempt_A_120f", rom, owState, 120,
      pulse(policy.BtnA, every = 16, width = 4))

  # --- Battle ---
  if battleState.len > 0 and fileExists(battleState):
    discard runSegment("battle_menu_idle_60f", rom, battleState, 60, always(0))
    discard runSegment("battle_menu_idle_120f", rom, battleState, 120, always(0))
    discard runSegment("battle_attack_A_mash_180f", rom, battleState, 180,
      pulse(policy.BtnA, every = 12, width = 3))
    discard runSegment("battle_menu_cursor_60f", rom, battleState, 60,
      pulse(policy.BtnDown, every = 12, width = 3))
  else:
    echo "[battle_*] BLOCKED — no mid-battle state (headless entry aborts; need F12)"

  echo "=== done ==="

when isMainModule:
  main()
