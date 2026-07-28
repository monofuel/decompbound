## PRNG menu-context reconciliation: pin caller PCs per menu type × action.
##
## Fresh Stonehenge overworld F12s (slots 210+) vs prior probe_rng_advances
## command-menu numbers. Live F8 play saw B-stat per-frame churn (~60/s), A
## open/close +1, nav +1, and ≥1/s with any menu open. This probe scripts
## those paths headlessly with step-loop PC watch at $C08E9A + seed writeHook
## on $0024-$0027, and writes evidence incrementally to
## /tmp/rng_reconcile_summary.md.
##
## Usage:
##   nim r src/probes/probe_rng_reconcile.nim [rom] [overworld.state] [menu_open.state]
##
## Defaults: Stonehenge free-overworld slot210; command-menu-open slot219.
## Never commits states. Exit 0 on success.

import
  std/[os, strformat, strutils, tables, algorithm],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  SummaryPath = "/tmp/rng_reconcile_summary.md"
  RngPbr = 0xC0'u8
  RngPc = 0x8E9A'u16
  RngPcEnd = 0x8ED1'u16
  SeedWram = 0x0024
  WindowHeader0 = 0x8650
  WindowHeader1 = 0x8654
  WindowHeader2 = 0x8658
  WindowFocus = 0x8958
  ## Free overworld (8650=FF, 8654=FF) from tonight's Stonehenge session.
  DefaultOverworld = "bin/states/slot210.state"
  ## Command menu already open (8650=01) from same session.
  DefaultMenuOpen = "bin/states/slot219.state"
  OverworldFallbacks = [
    "bin/states/slot214.state",
    "bin/states/slot213.state",
    "bin/states/slot218.state",
    "bin/states/llm/poo_free_outdoor.state",
    "bin/states/llm/fourside60_freewalk.state",
  ]
  MenuOpenFallbacks = [
    "bin/states/slot224.state",
    "bin/states/slot225.state",
    "bin/states/llm/poo_deep_south.state",
  ]
  DwellFrames = 300
  PulseWidth = 3
  WaitAfterPulse = 90

type
  CallEvent = object
    frame: int
    retPc: uint32
    parentPc: uint32   ## Return addr of the JSL that entered $C12DD5 (stack L2).
    grandPc: uint32    ## One level further out (stack L3), if present.
    seedBefore: uint32
    seedAfter: uint32

  WriterEvent = object
    frame: int
    writerPc: uint32
    waddr: uint32
    value: uint8

  RngTraceObj = object
    calls: int
    callers: CountTable[uint32]
    parents: CountTable[uint32]
    grands: CountTable[uint32]
    writers: CountTable[uint32]
    events: seq[CallEvent]
    writeEvents: seq[WriterEvent]
    frameCallCounts: seq[int]
  RngTrace = ref RngTraceObj

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

proc windowSnap(snes: SnesBus): string =
  ## Compact window-header snapshot for logs.
  &"8650={wram8(snes, WindowHeader0):02X} " &
    &"8654={wram8(snes, WindowHeader1):02X} " &
    &"8658={wram8(snes, WindowHeader2):02X} " &
    &"8958={wram8(snes, WindowFocus):02X}"

proc isCmdMenuOpen(snes: SnesBus): bool =
  ## Overworld command menu: slot0 header $01.
  wram8(snes, WindowHeader0) == 0x01

proc isAnyWindow(snes: SnesBus): bool =
  ## Slot0 or slot1 allocated.
  wram8(snes, WindowHeader0) != 0xFF or wram8(snes, WindowHeader1) != 0xFF

proc isFreeOverworld(snes: SnesBus): bool =
  ## No primary windows open.
  wram8(snes, WindowHeader0) == 0xFF and wram8(snes, WindowHeader1) == 0xFF

proc inRngBody(cpu: Cpu): bool =
  ## True while PC is inside the RNG routine body.
  cpu.pbr == RngPbr and cpu.pc >= RngPc and cpu.pc <= RngPcEnd

proc stackRetLong(snes: SnesBus, cpu: Cpu, level: int): uint32 =
  ## Read the `level`-th 24-bit JSL return address from the stack.
  ## level 0 = immediate return from current JSL (into $C08E9A); level 1 = its
  ## caller; level 2 = grandparent. Returns 0 if S would wrap oddly.
  ##
  ## After JSL: [S+1]=PCL, [S+2]=PCH, [S+3]=PBR (native 24-bit return).
  let base = (cpu.s.int + 1) + level * 3
  if base < 0 or base + 2 > 0xFFFF:
    return 0
  let
    lo = snes.bus.mem[0x7E0000 + (base and 0xFFFF)].uint32
    hi = snes.bus.mem[0x7E0000 + ((base + 1) and 0xFFFF)].uint32
    bk = snes.bus.mem[0x7E0000 + ((base + 2) and 0xFFFF)].uint32
  (bk shl 16) or (hi shl 8) or lo

proc topCallers(tab: CountTable[uint32], n = 10): string =
  ## Format top-N addresses with counts.
  var pairs: seq[(uint32, int)] = @[]
  for k, v in tab:
    pairs.add (k, v)
  pairs.sort(proc(a, b: (uint32, int)): int = cmp(b[1], a[1]))
  if pairs.len == 0:
    return "(none)"
  var parts: seq[string] = @[]
  for i in 0 ..< min(n, pairs.len):
    let (pcFull, cnt) = pairs[i]
    parts.add &"${pcFull:06X}×{cnt}"
  parts.join(", ")

proc periodStats(events: seq[CallEvent]): string =
  ## Inter-call frame gaps for sparse sources (blink / 1-per-N-frames).
  if events.len < 2:
    return "n/a (need ≥2 calls)"
  var gaps: seq[int] = @[]
  for i in 1 ..< events.len:
    gaps.add events[i].frame - events[i - 1].frame
  var sum = 0
  var minG = gaps[0]
  var maxG = gaps[0]
  for g in gaps:
    sum += g
    if g < minG: minG = g
    if g > maxG: maxG = g
  let mean = sum.float / gaps.len.float
  # Mode
  var gapCounts: CountTable[int]
  for g in gaps:
    gapCounts.inc(g)
  var modeG = gaps[0]
  var modeC = 0
  for g, c in gapCounts:
    if c > modeC:
      modeC = c
      modeG = g
  &"n={gaps.len} mean={mean:.2f}f min={minG} max={maxG} mode={modeG} (×{modeC})"

proc perFrameHistogram(frameCounts: seq[int]): string =
  ## How many frames had 0, 1, 2, … calls.
  var hist: CountTable[int]
  for c in frameCounts:
    hist.inc(c)
  var keys: seq[int] = @[]
  for k in hist.keys:
    keys.add k
  keys.sort()
  var parts: seq[string] = @[]
  for k in keys:
    parts.add &"{k}/f→{hist[k]}frames"
  parts.join(", ")

proc loadMachine(rom: seq[uint8], statePath: string): tuple[snes: SnesBus, cpu: Cpu] =
  ## Fresh bus + CPU, optional savestate.
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()
  if statePath.len > 0 and fileExists(statePath):
    deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)
  (snes, cpu)

proc installSeedHook(snes: SnesBus, cpu: var Cpu, frameRef: ptr int,
                     trace: RngTrace) =
  ## Chain-wrap writeHook on seed bytes $0024-$0027 (WRAM + low mirrors).
  let prev = snes.bus.writeHook
  # Capture cpu by ptr so the closure always sees live PC.
  let cpuPtr = addr cpu
  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let bank = address shr 16
    let off = address and 0xFFFF
    var woff = -1
    if bank == 0x7E or bank == 0x7F:
      woff = off.int
    elif (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and off < 0x2000:
      woff = off.int
    if woff >= SeedWram and woff <= SeedWram + 3:
      let writer = (cpuPtr[].pbr.uint32 shl 16) or cpuPtr[].pc.uint32
      trace.writers.inc(writer)
      if trace.writeEvents.len < 4000:
        trace.writeEvents.add WriterEvent(
          frame: frameRef[],
          writerPc: writer,
          waddr: address,
          value: value)
    if prev != nil:
      return prev(address, value)
    false

proc stepFrameTracing(snes: SnesBus, cpu: var Cpu, img: Image,
                      frame: int, trace: RngTrace) =
  ## One policy-style frame; count $C08E9A entries, RTL return PCs, stack parents.
  var
    line = 0
    inRoutine = false
    seedBefore = 0'u32
    parentAtEntry = 0'u32
    grandAtEntry = 0'u32
    frameCalls = 0
  while line < 262:
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for _ in 0 ..< policy.InstrPerLine:
      if not (cpu.stopped or cpu.waiting):
        if not inRoutine and cpu.pbr == RngPbr and cpu.pc == RngPc:
          inRoutine = true
          seedBefore = readSeed(snes)
          # Stack still has JSL frames: L0→$C12DDB, L1→caller of $C12DD5, …
          parentAtEntry = stackRetLong(snes, cpu, 1)
          grandAtEntry = stackRetLong(snes, cpu, 2)
          inc trace.calls
          inc frameCalls
        cpu.step(snes.bus)
        if inRoutine and not inRngBody(cpu):
          let ret = (cpu.pbr.uint32 shl 16) or cpu.pc.uint32
          trace.callers.inc(ret)
          if parentAtEntry != 0:
            trace.parents.inc(parentAtEntry)
          if grandAtEntry != 0:
            trace.grands.inc(grandAtEntry)
          if trace.events.len < 8000:
            trace.events.add CallEvent(
              frame: frame,
              retPc: ret,
              parentPc: parentAtEntry,
              grandPc: grandAtEntry,
              seedBefore: seedBefore,
              seedAfter: readSeed(snes))
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
  trace.frameCallCounts.add frameCalls

proc findFirst(paths: openArray[string]): string =
  ## First existing path, or empty.
  for p in paths:
    if fileExists(p):
      return p
  ""

proc appendSummary(lines: openArray[string]) =
  ## Append lines to the incremental summary file.
  let f = open(SummaryPath, fmAppend)
  defer: f.close()
  for line in lines:
    f.writeLine(line)

proc initSummary(romPath, owState, menuState: string) =
  ## Truncate and write the summary header.
  let f = open(SummaryPath, fmWrite)
  defer: f.close()
  f.writeLine("# RNG reconcile — menu-context evidence")
  f.writeLine("")
  f.writeLine(&"Generated: 2026-07-27 (probe_rng_reconcile)")
  f.writeLine(&"ROM: `{romPath}`")
  f.writeLine(&"Overworld state: `{owState}`")
  f.writeLine(&"Menu-open state: `{menuState}`")
  f.writeLine("")
  f.writeLine("Counts = `$C08E9A` entries (step-loop PC watch). " &
    "Caller = return PC after RTL (JSL+4). " &
    "Writer PCs are inside the RNG body (seed STA).")
  f.writeLine("")
  f.writeLine("## Evidence table (incremental)")
  f.writeLine("")
  f.writeLine("| Context | Action | Frames | Advances | Calls/f | " &
    "Top callers (return PC) | Notes |")
  f.writeLine("|---|---|---:|---:|---:|---|---|")

proc reportSegment(label: string, frames: int, tr: RngTrace,
                   seed0, seed1: uint32, winBefore, winAfter: string,
                   extra = "") =
  ## Echo + append one evidence row with detail block.
  let
    nCalls = tr.calls
    perF = if frames > 0: nCalls.float / frames.float else: 0.0
    callersStr = topCallers(tr.callers, 6)
    callersAll = topCallers(tr.callers)
    parentsAll = topCallers(tr.parents)
    grandsAll = topCallers(tr.grands)
    writersAll = topCallers(tr.writers)
    histStr = perFrameHistogram(tr.frameCallCounts)
    periodStr = periodStats(tr.events)
    notes =
      if extra.len > 0: extra
      else: &"seed {seed0:08X}→{seed1:08X}"
    row = &"| {label} | (see label) | {frames} | {nCalls} | {perF:.4f} | " &
      &"`{callersStr}` | {notes} |"
  echo &"[{label}] frames={frames} calls={nCalls} per_frame={perF:.4f} " &
    &"seed {seed0:08X}→{seed1:08X}"
  echo &"  win before: {winBefore}"
  echo &"  win after:  {winAfter}"
  echo &"  callers(L0)=[{callersAll}]"
  echo &"  parents(L1)=[{parentsAll}]"
  echo &"  grands(L2)=[{grandsAll}]"
  echo &"  writers=[{writersAll}]"
  echo &"  hist=[{histStr}]"
  if nCalls > 0 and nCalls < frames:
    echo &"  period: {periodStr}"
  # Per-parent period for multi-source segments.
  var byParent: Table[uint32, seq[CallEvent]]
  for e in tr.events:
    let key = if e.parentPc != 0: e.parentPc else: e.retPc
    byParent.mgetOrPut(key, @[]).add e
  var callerDetail: seq[string] = @[]
  for pc, evs in byParent.pairs:
    let per = periodStats(evs)
    let n = evs.len
    callerDetail.add &"  - parent `${pc:06X}` x{n} period={per}"
  callerDetail.sort()
  for line in callerDetail:
    echo line

  appendSummary([
    row,
    "",
    &"### {label}",
    "",
    &"- frames={frames} calls={nCalls} per_frame={perF:.4f}",
    &"- seed `{seed0:08X}` → `{seed1:08X}`",
    &"- windows before: `{winBefore}`",
    &"- windows after: `{winAfter}`",
    &"- callers L0 (ret from RNG): `{callersAll}`",
    &"- parents L1 (caller of `$C12DD5`): `{parentsAll}`",
    &"- grands L2: `{grandsAll}`",
    &"- writers (seed STA PC): `{writersAll}`",
    &"- per-frame hist: `{histStr}`",
    &"- inter-call period: `{periodStr}`",
  ])
  if callerDetail.len > 0:
    appendSummary(["", "Per-parent:"])
    for line in callerDetail:
      appendSummary([line])
  if extra.len > 0:
    appendSummary(["", &"Notes: {extra}", ""])
  else:
    appendSummary([""])

proc newTrace(): RngTrace =
  ## Empty heap-backed trace (capture-safe for writeHook closures).
  RngTrace()

proc runFrames(snes: SnesBus, cpu: var Cpu, img: Image,
               frames: int, joy: proc(f: int): uint16,
               startFrame = 0): RngTrace =
  ## Run `frames` with joy schedule; return full trace.
  let tr = newTrace()
  var frameNow = startFrame
  installSeedHook(snes, cpu, addr frameNow, tr)
  for i in 0 ..< frames:
    frameNow = startFrame + i
    snes.joy1 = joy(i)
    stepFrameTracing(snes, cpu, img, frameNow, tr)
    if cpu.stopped:
      break
  tr

proc pulseJoy(btn: uint16, width = PulseWidth): proc(f: int): uint16 =
  ## Hold btn for first `width` frames, then release.
  result = proc(f: int): uint16 =
    if f < width: btn else: 0'u16

proc alwaysJoy(btn: uint16): proc(f: int): uint16 =
  ## Constant joy1.
  result = proc(f: int): uint16 = btn

proc main() =
  ## Reconcile menu-context RNG advances with caller-PC evidence.
  let
    romPath = if paramCount() >= 1: paramStr(1) else: DefaultRom
    owArg = if paramCount() >= 2: paramStr(2) else: ""
    menuArg = if paramCount() >= 3: paramStr(3) else: ""
  if not fileExists(romPath):
    echo &"ROM not found: {romPath}"
    quit(1)
  let rom = policy.readRomFile(romPath)
  let owState =
    if owArg.len > 0: owArg
    elif fileExists(DefaultOverworld): DefaultOverworld
    else: findFirst(OverworldFallbacks)
  let menuState =
    if menuArg.len > 0: menuArg
    elif fileExists(DefaultMenuOpen): DefaultMenuOpen
    else: findFirst(MenuOpenFallbacks)

  if owState.len == 0 or not fileExists(owState):
    echo "ERROR: no overworld state (pass as arg 2)"
    quit(1)

  echo "=== probe_rng_reconcile (menu-context caller PCs) ==="
  echo &"rom={romPath}"
  echo &"overworld={owState}"
  echo &"menu_open={menuState}"
  initSummary(romPath, owState, menuState)

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)

  # ------------------------------------------------------------------
  # 0) Classify starting states
  # ------------------------------------------------------------------
  block classify:
    var (snes, cpu) = loadMachine(rom, owState)
    echo &"[classify] OW  inBattle={policy.isInBattle(snes)} {windowSnap(snes)} " &
      &"seed={readSeed(snes):08X} mode={snes.ppuRegs[0x05] and 7}"
    appendSummary([
      "## State classification",
      "",
      &"- OW `{owState}`: inBattle={policy.isInBattle(snes)} " &
        &"`{windowSnap(snes)}` seed=`{readSeed(snes):08X}`",
    ])
    if menuState.len > 0 and fileExists(menuState):
      var (s2, c2) = loadMachine(rom, menuState)
      echo &"[classify] MENU inBattle={policy.isInBattle(s2)} {windowSnap(s2)} " &
        &"seed={readSeed(s2):08X} mode={s2.ppuRegs[0x05] and 7}"
      appendSummary([
        &"- MENU `{menuState}`: inBattle={policy.isInBattle(s2)} " &
          &"`{windowSnap(s2)}` seed=`{readSeed(s2):08X}`",
        "",
      ])
    discard cpu

  # ------------------------------------------------------------------
  # 1) Overworld idle baseline — must be 0
  # ------------------------------------------------------------------
  block idle:
    var (snes, cpu) = loadMachine(rom, owState)
    let win0 = windowSnap(snes)
    let seed0 = readSeed(snes)
    let tr = runFrames(snes, cpu, img, 120, alwaysJoy(0))
    reportSegment("overworld_idle_120f", 120, tr, seed0, readSeed(snes),
      win0, windowSnap(snes), "baseline; expect 0")

  # ------------------------------------------------------------------
  # 2) Empirical: what does B open on free overworld?
  # ------------------------------------------------------------------
  block bOpen:
    var (snes, cpu) = loadMachine(rom, owState)
    # Settle
    discard runFrames(snes, cpu, img, 10, alwaysJoy(0))
    let win0 = windowSnap(snes)
    let seed0 = readSeed(snes)
    let tr = newTrace()
    var frameNow = 0
    installSeedHook(snes, cpu, addr frameNow, tr)
    # B pulse
    for f in 0 ..< PulseWidth:
      frameNow = f
      snes.joy1 = policy.BtnB
      stepFrameTracing(snes, cpu, img, f, tr)
    var openedAt = -1
    var firstNonFree = ""
    for f in 0 ..< WaitAfterPulse:
      frameNow = PulseWidth + f
      snes.joy1 = 0
      stepFrameTracing(snes, cpu, img, frameNow, tr)
      if not isFreeOverworld(snes) and openedAt < 0:
        openedAt = f
        firstNonFree = windowSnap(snes)
    let note = &"B-pulse openAt={openedAt} firstWin=`{firstNonFree}` " &
      &"anyWin={isAnyWindow(snes)} cmd={isCmdMenuOpen(snes)} " &
      &"seed {seed0:08X}→{readSeed(snes):08X}"
    reportSegment("B_pulse_open_attempt", PulseWidth + WaitAfterPulse, tr,
      seed0, readSeed(snes), win0, windowSnap(snes), note)

  # ------------------------------------------------------------------
  # 3) Empirical: what does X open?
  # ------------------------------------------------------------------
  block xOpen:
    var (snes, cpu) = loadMachine(rom, owState)
    discard runFrames(snes, cpu, img, 10, alwaysJoy(0))
    let win0 = windowSnap(snes)
    let seed0 = readSeed(snes)
    let tr = newTrace()
    var frameNow = 0
    installSeedHook(snes, cpu, addr frameNow, tr)
    for f in 0 ..< PulseWidth:
      frameNow = f
      snes.joy1 = policy.BtnX
      stepFrameTracing(snes, cpu, img, f, tr)
    var openedAt = -1
    var firstNonFree = ""
    for f in 0 ..< WaitAfterPulse:
      frameNow = PulseWidth + f
      snes.joy1 = 0
      stepFrameTracing(snes, cpu, img, frameNow, tr)
      if not isFreeOverworld(snes) and openedAt < 0:
        openedAt = f
        firstNonFree = windowSnap(snes)
    let note = &"X-pulse openAt={openedAt} firstWin=`{firstNonFree}` " &
      &"anyWin={isAnyWindow(snes)} cmd={isCmdMenuOpen(snes)}"
    reportSegment("X_pulse_open_attempt", PulseWidth + WaitAfterPulse, tr,
      seed0, readSeed(snes), win0, windowSnap(snes), note)

  # ------------------------------------------------------------------
  # 4) A open command menu + dwell 300f + cursor + close
  # ------------------------------------------------------------------
  block aCmd:
    var (snes, cpu) = loadMachine(rom, owState)
    discard runFrames(snes, cpu, img, 10, alwaysJoy(0))
    let win0 = windowSnap(snes)
    let seed0 = readSeed(snes)
    let trOpen = newTrace()
    var frameNow = 0
    installSeedHook(snes, cpu, addr frameNow, trOpen)
    for f in 0 ..< PulseWidth:
      frameNow = f
      snes.joy1 = policy.BtnA
      stepFrameTracing(snes, cpu, img, f, trOpen)
    var openedAt = -1
    for f in 0 ..< WaitAfterPulse:
      frameNow = PulseWidth + f
      snes.joy1 = 0
      stepFrameTracing(snes, cpu, img, frameNow, trOpen)
      if isCmdMenuOpen(snes) and openedAt < 0:
        openedAt = f
    reportSegment("cmd_menu_open_A", PulseWidth + WaitAfterPulse, trOpen,
      seed0, readSeed(snes), win0, windowSnap(snes),
      &"openedAt={openedAt} cmd={isCmdMenuOpen(snes)}")

    if isCmdMenuOpen(snes) or isAnyWindow(snes):
      # Dwell 300f with menu open — THE ≥1/s / blink test
      let winD0 = windowSnap(snes)
      let seedD0 = readSeed(snes)
      let trDwell = runFrames(snes, cpu, img, DwellFrames, alwaysJoy(0))
      reportSegment("cmd_menu_dwell_300f_after_A", DwellFrames, trDwell,
        seedD0, readSeed(snes), winD0, windowSnap(snes),
        "dwell-safe? or ≥1/s tick")

      # Single cursor downs (rising-edge style: 3f press, 20f release × 5)
      let winC0 = windowSnap(snes)
      let seedC0 = readSeed(snes)
      let trCur = newTrace()
      frameNow = 0
      installSeedHook(snes, cpu, addr frameNow, trCur)
      const NavCycles = 5
      const NavPeriod = 24
      for f in 0 ..< NavCycles * NavPeriod:
        frameNow = f
        snes.joy1 = if (f mod NavPeriod) < PulseWidth: policy.BtnDown else: 0'u16
        stepFrameTracing(snes, cpu, img, f, trCur)
      reportSegment("cmd_menu_cursor_down_x5", NavCycles * NavPeriod, trCur,
        seedC0, readSeed(snes), winC0, windowSnap(snes),
        &"{NavCycles} down pulses; +1/input?")

      # Close with B
      let winCl0 = windowSnap(snes)
      let seedCl0 = readSeed(snes)
      let trClo = newTrace()
      frameNow = 0
      installSeedHook(snes, cpu, addr frameNow, trClo)
      for f in 0 ..< PulseWidth:
        frameNow = f
        snes.joy1 = policy.BtnB
        stepFrameTracing(snes, cpu, img, f, trClo)
      var closedAt = -1
      for f in 0 ..< WaitAfterPulse:
        frameNow = PulseWidth + f
        snes.joy1 = 0
        stepFrameTracing(snes, cpu, img, frameNow, trClo)
        if isFreeOverworld(snes) and closedAt < 0:
          closedAt = f
      reportSegment("cmd_menu_close_B", PulseWidth + WaitAfterPulse, trClo,
        seedCl0, readSeed(snes), winCl0, windowSnap(snes),
        &"closedAt={closedAt} free={isFreeOverworld(snes)}")
    else:
      echo "[cmd_menu] A did not open command menu; skip dwell/cursor/close"
      appendSummary(["| cmd_menu_* | blocked | — | — | — | — | A did not open |", ""])

  # ------------------------------------------------------------------
  # 5) Pre-open command menu state: dwell + cursor (compare prior probe)
  # ------------------------------------------------------------------
  if menuState.len > 0 and fileExists(menuState):
    block preOpen:
      var (snes, cpu) = loadMachine(rom, menuState)
      let win0 = windowSnap(snes)
      let seed0 = readSeed(snes)
      echo &"[preopen] start {win0} cmd={isCmdMenuOpen(snes)}"
      let trDwell = runFrames(snes, cpu, img, DwellFrames, alwaysJoy(0))
      reportSegment("preopen_cmd_menu_dwell_300f", DwellFrames, trDwell,
        seed0, readSeed(snes), win0, windowSnap(snes),
        "prior probe had dwell=0/120f on different states")

      let winC0 = windowSnap(snes)
      let seedC0 = readSeed(snes)
      let trCur = newTrace()
      var frameNow = 0
      installSeedHook(snes, cpu, addr frameNow, trCur)
      const NavCycles = 5
      const NavPeriod = 24
      for f in 0 ..< NavCycles * NavPeriod:
        frameNow = f
        snes.joy1 = if (f mod NavPeriod) < PulseWidth: policy.BtnDown else: 0'u16
        stepFrameTracing(snes, cpu, img, f, trCur)
      reportSegment("preopen_cmd_menu_cursor_down_x5", NavCycles * NavPeriod,
        trCur, seedC0, readSeed(snes), winC0, windowSnap(snes),
        "prior probe: cursor=0")

      let winCl0 = windowSnap(snes)
      let seedCl0 = readSeed(snes)
      let trClo = newTrace()
      frameNow = 0
      installSeedHook(snes, cpu, addr frameNow, trClo)
      for f in 0 ..< PulseWidth:
        frameNow = f
        snes.joy1 = policy.BtnB
        stepFrameTracing(snes, cpu, img, f, trClo)
      var closedAt = -1
      for f in 0 ..< WaitAfterPulse:
        frameNow = PulseWidth + f
        snes.joy1 = 0
        stepFrameTracing(snes, cpu, img, frameNow, trClo)
        if not isAnyWindow(snes) and closedAt < 0:
          closedAt = f
      reportSegment("preopen_cmd_menu_close_B", PulseWidth + WaitAfterPulse,
        trClo, seedCl0, readSeed(snes), winCl0, windowSnap(snes),
        &"closedAt={closedAt}; prior close=64")

  # ------------------------------------------------------------------
  # 6) B-open then isolated dwell — monofuel's "stat menu with B" path
  # ------------------------------------------------------------------
  block bOpenDwell:
    var (snes, cpu) = loadMachine(rom, owState)
    discard runFrames(snes, cpu, img, 10, alwaysJoy(0))
    # Short B pulse to open whatever B opens
    var frameNow = 0
    let trOpen = newTrace()
    installSeedHook(snes, cpu, addr frameNow, trOpen)
    for f in 0 ..< PulseWidth:
      frameNow = f
      snes.joy1 = policy.BtnB
      stepFrameTracing(snes, cpu, img, f, trOpen)
    for f in 0 ..< 30:
      frameNow = PulseWidth + f
      snes.joy1 = 0
      stepFrameTracing(snes, cpu, img, frameNow, trOpen)
    let winOpened = windowSnap(snes)
    let seedD0 = readSeed(snes)
    # Pure dwell of the B-opened state (no input)
    let trDwell = newTrace()
    var fD = 0
    installSeedHook(snes, cpu, addr fD, trDwell)
    for i in 0 ..< DwellFrames:
      fD = i
      snes.joy1 = 0
      stepFrameTracing(snes, cpu, img, i, trDwell)
    reportSegment("B_opened_dwell_300f", DwellFrames, trDwell,
      seedD0, readSeed(snes), winOpened, windowSnap(snes),
      &"after B-pulse openCalls={trOpen.calls} win=`{winOpened}`; " &
        "live F8 'stat menu every frame' candidate")

  # ------------------------------------------------------------------
  # 7) Pre-captured 8654=0A state (slot220) idle dwell
  # ------------------------------------------------------------------
  block preOpen0A:
    let path0A =
      if fileExists("bin/states/slot220.state"): "bin/states/slot220.state"
      else: ""
    if path0A.len > 0:
      var (snes, cpu) = loadMachine(rom, path0A)
      let win0 = windowSnap(snes)
      let seed0 = readSeed(snes)
      let tr = runFrames(snes, cpu, img, DwellFrames, alwaysJoy(0))
      reportSegment("preopen_8654_0A_dwell_300f", DwellFrames, tr,
        seed0, readSeed(snes), win0, windowSnap(snes),
        &"state={path0A}; window type 0x0A idle")
    else:
      echo "[preopen_0A] no slot220"

  # ------------------------------------------------------------------
  # 8) Status path: A open → Down×4 to Status → A confirm → dwell 300f
  #    EarthBound cmd order: Talk, Goods, Equip, PSI, Status, Check
  # ------------------------------------------------------------------
  block statusPath:
    var (snes, cpu) = loadMachine(rom, owState)
    discard runFrames(snes, cpu, img, 10, alwaysJoy(0))
    var frameNow = 0
    let trAll = newTrace()
    installSeedHook(snes, cpu, addr frameNow, trAll)

    proc stepF(btn: uint16) =
      snes.joy1 = btn
      stepFrameTracing(snes, cpu, img, frameNow, trAll)
      inc frameNow

    # Open command menu with A — longer wait (matches working open segment)
    for _ in 0 ..< PulseWidth: stepF(policy.BtnA)
    for _ in 0 ..< WaitAfterPulse: stepF(0)
    let afterA = windowSnap(snes)
    let openCalls = trAll.calls
    echo &"[status_path] after A: {afterA} calls={openCalls} cmd={isCmdMenuOpen(snes)}"

    if not isCmdMenuOpen(snes):
      echo "[status_path] command menu not open; abort path"
      appendSummary(["| status_path | blocked | — | — | — | — | A failed |", ""])
    else:
      # Down × 4 toward Status (Talk→Goods→Equip→PSI→Status)
      for nav in 0 ..< 4:
        for _ in 0 ..< PulseWidth: stepF(policy.BtnDown)
        for _ in 0 ..< 20: stepF(0)
      let afterNav = windowSnap(snes)
      let navCalls = trAll.calls - openCalls
      echo &"[status_path] after 4xDown: {afterNav} dCalls={navCalls}"

      # A to enter Status
      let callsBeforeStatus = trAll.calls
      for _ in 0 ..< PulseWidth: stepF(policy.BtnA)
      for _ in 0 ..< 90: stepF(0)
      let winStatus = windowSnap(snes)
      let statusOpenCalls = trAll.calls - callsBeforeStatus
      echo &"[status_path] after Status A: {winStatus} dCalls={statusOpenCalls} " &
        &"seed={readSeed(snes):08X}"

      appendSummary([
        &"| status_path_open_via_cmd | nav+enter | ~{frameNow} | {trAll.calls} | " &
          &"— | `{topCallers(trAll.callers, 6)}` parents=`{topCallers(trAll.parents, 4)}` | " &
          &"afterA=`{afterA}` afterNav=`{afterNav}` status=`{winStatus}` |",
        "",
      ])

      let seedD0 = readSeed(snes)
      let winD0 = windowSnap(snes)
      let trDwell = newTrace()
      var fD = 0
      installSeedHook(snes, cpu, addr fD, trDwell)
      for i in 0 ..< DwellFrames:
        fD = i
        snes.joy1 = 0
        stepFrameTracing(snes, cpu, img, i, trDwell)
      reportSegment("status_menu_dwell_300f", DwellFrames, trDwell,
        seedD0, readSeed(snes), winD0, windowSnap(snes),
        &"via cmd→4xDown→A; openΔ={statusOpenCalls}")

  # ------------------------------------------------------------------
  # 9) B-hold from free overworld (sustained)
  # ------------------------------------------------------------------
  block bHold:
    var (snes, cpu) = loadMachine(rom, owState)
    discard runFrames(snes, cpu, img, 10, alwaysJoy(0))
    let win0 = windowSnap(snes)
    let seed0 = readSeed(snes)
    let tr = newTrace()
    var frameNow = 0
    installSeedHook(snes, cpu, addr frameNow, tr)
    for f in 0 ..< 60:
      frameNow = f
      snes.joy1 = policy.BtnB
      stepFrameTracing(snes, cpu, img, f, tr)
    let midWin = windowSnap(snes)
    let midCalls = tr.calls
    for f in 0 ..< 240:
      frameNow = 60 + f
      snes.joy1 = 0
      stepFrameTracing(snes, cpu, img, frameNow, tr)
    reportSegment("B_hold_60f_then_idle_240f", 300, tr,
      seed0, readSeed(snes), win0, windowSnap(snes),
      &"mid(after hold B)={midWin} midCalls={midCalls}")

  # ------------------------------------------------------------------
  # 10) X-hold (status is X on some EB maps / muscle memory)
  # ------------------------------------------------------------------
  block xHold:
    var (snes, cpu) = loadMachine(rom, owState)
    discard runFrames(snes, cpu, img, 10, alwaysJoy(0))
    let win0 = windowSnap(snes)
    let seed0 = readSeed(snes)
    let tr = newTrace()
    var frameNow = 0
    installSeedHook(snes, cpu, addr frameNow, tr)
    for f in 0 ..< PulseWidth:
      frameNow = f
      snes.joy1 = policy.BtnX
      stepFrameTracing(snes, cpu, img, f, tr)
    var openedAt = -1
    for f in 0 ..< 60:
      frameNow = PulseWidth + f
      snes.joy1 = 0
      stepFrameTracing(snes, cpu, img, frameNow, tr)
      if not isFreeOverworld(snes) and openedAt < 0:
        openedAt = f
    let afterOpen = windowSnap(snes)
    let openCalls = tr.calls
    # Dwell whatever opened (or idle if nothing)
    let trD = newTrace()
    var fD = 0
    installSeedHook(snes, cpu, addr fD, trD)
    let seedD0 = readSeed(snes)
    for i in 0 ..< DwellFrames:
      fD = i
      snes.joy1 = 0
      stepFrameTracing(snes, cpu, img, i, trD)
    reportSegment("X_open_then_dwell_300f", DwellFrames, trD,
      seedD0, readSeed(snes), afterOpen, windowSnap(snes),
      &"X openAt={openedAt} openCalls={openCalls} afterOpen=`{afterOpen}`")
    # Also report the open segment
    reportSegment("X_open_segment", PulseWidth + 60, tr,
      seed0, seedD0, win0, afterOpen,
      &"openAt={openedAt}")

  # ------------------------------------------------------------------
  # 11) Y button (sometimes status in other RPGs)
  # ------------------------------------------------------------------
  block yOpen:
    var (snes, cpu) = loadMachine(rom, owState)
    discard runFrames(snes, cpu, img, 10, alwaysJoy(0))
    let win0 = windowSnap(snes)
    let seed0 = readSeed(snes)
    let tr = newTrace()
    var frameNow = 0
    installSeedHook(snes, cpu, addr frameNow, tr)
    for f in 0 ..< PulseWidth:
      frameNow = f
      snes.joy1 = policy.BtnY
      stepFrameTracing(snes, cpu, img, f, tr)
    for f in 0 ..< WaitAfterPulse:
      frameNow = PulseWidth + f
      snes.joy1 = 0
      stepFrameTracing(snes, cpu, img, frameNow, tr)
    reportSegment("Y_pulse_open_attempt", PulseWidth + WaitAfterPulse, tr,
      seed0, readSeed(snes), win0, windowSnap(snes),
      &"anyWin={isAnyWindow(snes)}")

  # ------------------------------------------------------------------
  # Caller identity + reconciliation conclusions
  # ------------------------------------------------------------------
  appendSummary([
    "## Caller identity (static + measured)",
    "",
    "- **L0 `$C12DDB`** = return after `JSL $C08E9A` at `$C12DD7` inside " &
      "wrapper `$C12DD5` (`REP #$31; JSL RNG; LDA $968C; … RTL`). " &
      "Every menu-context advance in this run went through this wrapper — " &
      "the L0 return PC alone does not distinguish consumers.",
    "- **L1 parents** (stack return of the JSL into `$C12DD5`) pin the real " &
      "consumer. See per-segment `parents(L1)` rows above.",
    "- Wrapper always burns one RNG draw, then branches on `$968C` " &
      "(nonzero → early RTL; zero → longer path). So every JSL `$C12DD5` " &
      "= exactly +1 advance.",
    "",
    "### `$C13CB1` → L1 `$C13CB4` — B-status free-run (1/frame)",
    "",
    "```",
    "C13CB1: JSL $C12DD5          ; +1 RNG every iteration",
    "C13CB5: LDA $006D            ; pad (joypad.nim: DP new-pad)",
    "C13CB8: AND #$00A0",
    "C13CBB: BEQ C13CC3",
    "C13CBD: JSL $C134A7 / BRA exit",
    "C13CC3: LDA $006D / AND #$A000",
    "C13CC9: BEQ C13CB1           ; spin until face buttons",
    "```",
    "",
    "Status/party window **input-wait loop**. Entered via " &
      "`JSL $C13CA1` from overworld main-loop at `$C0B8FE` " &
      "(grand L2 return `$C0B901`). While window type `0x0A` is focused " &
      "(`8654=0A`, `8958=0A`) this burns **exactly 1 RNG/frame**. " &
      "This is monofuel's live ~60/s B-stat spin — **not** an HP/PP " &
      "rolling-meter consumer (the burn is the wait-loop's unconditional " &
      "`JSL $C12DD5`).",
    "",
    "### `$C11B26` → L1 `$C11B29` — cmd-menu blink/redraw (~62f)",
    "",
    "```",
    "C11B26: JSL $C12DD5          ; +1 RNG",
    "C11B2A: LDA #1 / STA $02",
    "C11B2F: LDA $02 / EOR #1     ; classic 0↔1 blink toggle",
    "… tilemap math via ($24), ADC #$7C20 …",
    "```",
    "",
    "Window **tile/cursor redraw** path. Period measured **exactly 62 " &
      "frames** (~1.03/s) while A-opened command menu has the side window " &
      "focused (`8654=00`, `8958=00`). Cursor Down also hits this parent " &
      "(+1 per nav). Grand `$DA1ECB` (bank $DA text/window dispatcher).",
    "",
    "## Reconciliation (both measurement sets are real)",
    "",
    "### Why prior probe said dwell=0 / cursor=0 / close=64",
    "",
    "- Prior states were **pure command menu** (`8650=01`, `8654=FF`, " &
      "focus free). Reproduced on slot219: dwell 300f = **0**, " &
      "cursor x5 = **0**.",
    "- Close cost is path-dependent: from pure cmd menu, B transitions " &
      "into the B-window (`8654=0A`) which free-runs 1/frame for the " &
      "remainder of the wait window — prior 64 vs our 93 is wait-length, " &
      "not a different RNG site.",
    "",
    "### Why live F8 saw ~60/s, +1/nav, >=1/s",
    "",
    "- **B on overworld** opens window type **`0x0A`** and free-runs " &
      "**1 advance/frame** via `$C13CB1` → `$C12DD5` → `$C08E9A`. " &
      "(X/Y do nothing on free overworld.)",
    "- **A command menu** open = **2** advances (matches prior). With the " &
      "side window allocated (`8654=00`, focus 00), dwell ticks every " &
      "**62 frames** via `$C11B29` — the >=1/s blink source. Pure cmd " &
      "menu without that side window is dwell-safe.",
    "- **Cursor nav** on A-opened cmd menu = **+1 per Down pulse** " &
      "(also `$C11B29`). Prior cursor=0 was the pure-cmd-menu state class.",
    "",
    "### Recipe impact",
    "",
    "- Coarse spin = open B-status (`0x0A`), idle, close carefully.",
    "- Fine step = A-cmd nav (+1/input); do **not** dwell on A-opened " &
      "menu with side window focused (62f tick).",
    "- Pure cmd-menu F12s (`8654=FF`) remain dwell-safe anchors.",
    "",
    "## Final evidence table",
    "",
    "| Menu type | Action | Advances | L0 | L1 parent | Period | Notes |",
    "|---|---|---:|---|---|---|---|",
    "| Free OW | idle 120f | **0** | — | — | — | baseline |",
    "| **B-status (0x0A)** | dwell | **1/frame** | `$C12DDB` | **`$C13CB4`** | 1f | live ~60/s spin |",
    "| Pure cmd (8654=FF) | dwell 300f | **0** | — | — | — | prior probe |",
    "| Pure cmd | cursor x5 | **0** | — | — | — | prior probe |",
    "| Pure cmd | close B | path→0x0A then 1/f | `$C12DDB` | `$C13CB4` | 1f | prior close=64 wait-length |",
    "| A-cmd + side win | open A | **2** | `$C12DDB` | `$C11B29` | — | matches prior open=2 |",
    "| A-cmd + side win | dwell 300f | **5** | `$C12DDB` | `$C11B29` | **62f** | >=1/s blink |",
    "| A-cmd + side win | cursor x5 | **5** | `$C12DDB` | `$C11B29` | =input | live +1/nav |",
    "| A-cmd + side win | close B | **2** | `$C12DDB` | mixed | — | closes side win |",
    "| Status via cmd (focus 01) | dwell 300f | **0** | — | — | — | dwell-safe once focused |",
    "",
  ])

  echo "=== done ==="
  echo &"summary → {SummaryPath}"
  quit(0)

when isMainModule:
  main()
