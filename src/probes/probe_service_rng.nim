## Trace complete $C12DD5 calls in a local state, including nested RNG draws.
## Usage: nim r src/probes/probe_service_rng.nim state [frames] [joyMaskHex].
## Read-only state input; stdout contains addresses and aggregate counts only.

import
  std/[algorithm, os, strformat, strutils, tables],
  ../decompbound/[cpu, rom_pipeline, save_state, snesbus]

type
  Invocation = object
    returnPc: uint32
    returnStack: uint16
    draws: int
    firstGate, secondGate: uint8
    longPath: bool
  Trace = object
    active: seq[Invocation]
    completed: int
    counts: CountTable[string]
    services: CountTable[uint32]
    rngCallers: CountTable[uint32]

const
  ServiceEntry = 0xC12DD5'u32
  LongPathEntry = 0xC12DF2'u32
  RngEntry = 0xC08E9A'u32
  FirstGate = 0x968C'u32
  SecondGate = 0x9622'u32
  WatchedServices = [0xC2087C'u32, 0xC107AF, 0xC2109F, 0xC213AC,
    0xC1FF2C, 0xC47F87, 0xC2038B, 0xC1004E, 0xC088B1, 0xC09466,
    0xC08B26, 0xC08756, 0xC43568]
  Scanlines = 262
  VisibleLines = 224
  InstructionsPerLine = 150
  ApuTicksPerFrame = 533
  DefaultFrames = 180

proc address(cpu: Cpu): uint32 =
  ## Return the current program address.
  (cpu.pbr.uint32 shl 16) or cpu.pc.uint32

proc returnAddress(snes: SnesBus, cpu: Cpu): uint32 =
  ## Read only the immediate JSL return frame at routine entry.
  let
    lo = snes.bus.read8(cpu.s.uint32 + 1).uint32
    hi = snes.bus.read8(cpu.s.uint32 + 2).uint32
    bank = snes.bus.read8(cpu.s.uint32 + 3).uint32
  (bank shl 16) or ((((hi shl 8) or lo) + 1) and 0xFFFF)

proc observe(trace: var Trace, snes: SnesBus, cpu: Cpu) =
  ## Attribute nested calls by their actual return PC and stack depth.
  let pc = address(cpu)
  if trace.active.len > 0 and pc == trace.active[^1].returnPc and
      cpu.s == trace.active[^1].returnStack:
    let call = trace.active.pop()
    trace.counts.inc(&"first={call.firstGate:02X} second={call.secondGate:02X} " &
      &"long={call.longPath} draws={call.draws}")
    inc trace.completed
  if pc == ServiceEntry:
    let bank = cpu.dbr.uint32 shl 16
    trace.active.add Invocation(returnPc: returnAddress(snes, cpu),
      returnStack: cpu.s + 3,
      firstGate: snes.bus.read8(bank or FirstGate),
      secondGate: snes.bus.read8(bank or SecondGate))
  if trace.active.len > 0:
    if pc == LongPathEntry:
      trace.active[^1].longPath = true
    if pc in WatchedServices:
      trace.services.inc(pc)
    if pc == RngEntry:
      trace.rngCallers.inc(returnAddress(snes, cpu))
      for call in trace.active.mitems:
        inc call.draws

proc stepFrame(trace: var Trace, snes: SnesBus, cpu: var Cpu) =
  ## Use the TAS emulator cadence while observing instruction boundaries.
  var ticks = 0
  for line in 0 ..< Scanlines:
    snes.tickScanline(line)
    if line == VisibleLines and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for instruction in 0 ..< InstructionsPerLine:
      if not cpu.waiting and not cpu.stopped and not cpu.nmiPending:
        trace.observe(snes, cpu)
      cpu.step(snes.bus)
      doAssert not cpu.stopped, "CPU stopped during service observation"
    if line < VisibleLines:
      snes.runHdma()
    for tick in 0 ..< 2:
      discard snes.tickApu()
      inc ticks
  snes.initHdma()
  while ticks < ApuTicksPerFrame:
    discard snes.tickApu()
    inc ticks

proc reportAddresses(label: string, counts: CountTable[uint32]) =
  ## Print deterministic address counts without memory payloads.
  var addresses: seq[uint32]
  for key in counts.keys:
    addresses.add key
  addresses.sort()
  for key in addresses:
    echo &"{label} ${key:06X} count={counts[key]}"

proc main() =
  ## Measure complete service calls from an unmodified local machine state.
  if paramCount() < 1:
    raise newException(ValueError, "Expected a local state path")
  let
    statePath = paramStr(1)
    frames = if paramCount() > 1: parseInt(paramStr(2)) else: DefaultFrames
    joy = if paramCount() > 2: parseHexInt(paramStr(3)).uint16 else: 0'u16
    snes = newSnesBus(readGoldBaserom())
  doAssert frames > 0
  var
    cpu = snes.resetCpu()
    trace: Trace
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)
  for frame in 0 ..< frames:
    snes.joy1 = joy
    trace.stepFrame(snes, cpu)
  echo &"state={statePath.extractFilename} frames={frames} joy={joy:04X} " &
    &"completed={trace.completed} pending={trace.active.len}"
  var keys: seq[string]
  for key in trace.counts.keys:
    keys.add key
  keys.sort()
  for key in keys:
    echo key, " count=", trace.counts[key]
  reportAddresses("service", trace.services)
  reportAddresses("rngReturn", trace.rngCallers)

when isMainModule:
  main()
