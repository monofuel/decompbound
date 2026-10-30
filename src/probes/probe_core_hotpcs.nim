import
  std/[algorithm, os, strformat, strutils, tables],
  pixie,
  ../decompbound/[assembler, cpu, disasm, frame_step, memmap, opcodes, png_state, ppu,
    replay_run, rom_pipeline, save_state, snesbus]

type
  PcProfile = object
    counts: seq[uint32]
    flags: seq[uint8]
    visited: seq[uint32]
    instructions, stepCalls, nmiServices, waitSteps, stoppedSteps: uint64
  RankedCount = tuple[address: int, count: uint64]

const
  DefaultFrames = 180
  MaximumFrames = 100_000
  TopPcs = 24
  TopBlocks = 12
  BlockBytes = 64
  VblankLine = 224
  Scanlines = 262
  InlineApuSamples = 2
  EmulationWidthBit = 1'u8

proc observe(profile: var PcProfile, state: Cpu) =
  ## Count actual opcode fetches separately from no-op stepping and interrupt service.
  inc profile.stepCalls
  if state.stopped:
    inc profile.stoppedSteps
  elif state.nmiPending:
    inc profile.nmiServices
  elif state.waiting:
    inc profile.waitSteps
  else:
    let address = (state.pbr.uint32 shl 16) or state.pc.uint32
    if profile.counts[address] == 0:
      profile.visited.add(address)
      profile.flags[address] = (state.p and (FlagM or FlagX)) or
        (if state.emulation: EmulationWidthBit else: 0'u8)
    inc profile.counts[address]
    inc profile.instructions

proc profiledFrame(machine: SnesBus, state: var Cpu, image: Image,
    render: bool, profile: var PcProfile) =
  ## Preserve stepReplayFrame's CPU, NMI, HDMA, sprite and audio ordering exactly.
  let forceBlank = (machine.ppuRegs[0] and 0x80) != 0
  if render and not forceBlank:
    image.fill(bgr555ToColor(machine.cgram[0]))
  for line in 0 ..< Scanlines:
    machine.tickScanline(line)
    if line == VblankLine:
      if render:
        machine.renderSprites(image)
        machine.overlayForegroundBg(image)
      if (machine.nmitimen and 0x80) != 0:
        state.nmiPending = true
    for instruction in 0 ..< InstrPerLine:
      if state.pbr == 0xC0 and state.pc == 0x875F and profile.counts[0xC0875F] == 0:
        echo &"First poll context: DBR=${state.dbr:02X} P=${state.p:02X} emulation={state.emulation} eventLow={machine.bus.mem[0x7E002B]} eventHigh={machine.bus.mem[0x7E002C]}."
      profile.observe(state)
      state.step(machine.bus)
      if state.stopped: break
    if line < VblankLine:
      machine.runHdma()
      if render and (machine.ppuRegs[0] and 0x80) == 0:
        machine.renderScanline(image, line)
    for sample in 0 ..< InlineApuSamples:
      discard machine.tickApu()
    if line + 1 == Scanlines:
      machine.initHdma()
  for sample in 0 ..< PlayApuTopUp:
    discard machine.tickApu()

proc release(machine: SnesBus) =
  ## Release self-capturing emulator hooks after this private profiling run.
  machine.bus.readHook = nil
  machine.bus.writeHook = nil
  if machine.apu != nil:
    machine.apu.spc.readHook = nil
    machine.apu.spc.writeHook = nil

proc ranking(counts: Table[int, uint64]): seq[RankedCount] =
  ## Sort nonzero counts reproducibly by descending frequency then ascending address.
  for address, count in counts:
    result.add((address, count))
  result.sort(proc(a, b: RankedCount): int =
    ## Break frequency ties by the physical ROM location.
    result = cmp(b.count, a.count)
    if result == 0: result = cmp(a.address, b.address))

proc describe(rom: seq[uint8], offset: int, width: uint8): string =
  ## Disassemble one hot instruction using its first observed live register widths.
  let flags = FlagState(m8: (width and FlagM) != 0,
    x8: (width and FlagX) != 0, emulation: (width and EmulationWidthBit) != 0)
  let decoded = disassemble(rom, offset, 1, flags)
  if decoded.len > 0: formatInstruction(decoded[0].instr) else: "<truncated>"

proc report(profile: PcProfile, rom: seq[uint8]) =
  ## Report instruction-frequency shares without claiming elapsed-time attribution.
  var
    counts = initTable[int, uint64]()
    blockCounts = initTable[int, uint64]()
    widths = initTable[int, uint8]()
    nonRom: uint64
  for address in profile.visited:
    let
      offset = snesToFile(address)
      count = profile.counts[address].uint64
    if offset >= 0 and offset < rom.len:
      counts.mgetOrPut(offset, 0) += count
      blockCounts.mgetOrPut((offset div BlockBytes) * BlockBytes, 0) += count
      if offset notin widths: widths[offset] = profile.flags[address]
    else:
      nonRom += count
  echo &"opcodeFetches={profile.instructions} stepCalls={profile.stepCalls} nmiServices={profile.nmiServices} waitSteps={profile.waitSteps} stoppedSteps={profile.stoppedSteps} nonRomFetches={nonRom}"
  echo "Shares below count 65816 opcode fetches, not CPU cycles or host wall time; ROM mirrors are combined."
  echo "Top PCs: canonical SNES address / file offset / fetches / instruction share / first-width disassembly"
  let ordered = counts.ranking()
  for index in 0 ..< min(TopPcs, ordered.len):
    let
      row = ordered[index]
      share = row.count.float64 * 100 / profile.instructions.float64
      instruction = describe(rom, row.address, widths[row.address])
    echo &"${fileToSnes(row.address):06X} file=0x{row.address:06X} fetches={row.count} share={share:.3f}% {instruction}"
  echo &"Top aligned {BlockBytes}-byte ROM blocks:"
  let blocks = blockCounts.ranking()
  for index in 0 ..< min(TopBlocks, blocks.len):
    let row = blocks[index]
    let share = row.count.float64 * 100 / profile.instructions.float64
    echo &"file=0x{row.address:06X}..0x{row.address+BlockBytes-1:06X} fetches={row.count} share={share:.3f}%"

proc main() =
  ## Profile a fixed private state and input, then prove instrumentation preserves replay.
  if paramCount() notin 1 .. 4:
    echo "Usage: nim r -d:release --path:src src/probes/probe_core_hotpcs.nim STATE [FRAMES=180] [JOYMASKHEX=0000] [render|headless]"
    quit(1)
  let
    path = paramStr(1)
    frames = if paramCount() >= 2: parseInt(paramStr(2)) else: DefaultFrames
    joy = if paramCount() >= 3: parseHexInt(paramStr(3)) else: 0
    rendering = if paramCount() >= 4: paramStr(4) else: "render"
  if frames notin 1 .. MaximumFrames or joy notin 0 .. 0xFFFF:
    raise newException(ValueError, "Frames or joypad mask are outside the bounded profiling range.")
  if rendering notin ["render", "headless"]:
    raise newException(ValueError, "Use render or headless for the final argument.")
  let
    rom = readGoldBaserom()
    supplied = cast[seq[uint8]](readFile(path))
    initialState = if path.toLowerAscii.endsWith(".png"):
        extractStateForRom(supplied, romHashOf(rom)) else: supplied
    machine = newSnesBus(rom)
    reference = newSnesBus(rom)
    image = newImage(ScreenWidth, ScreenHeight)
    referenceImage = newImage(ScreenWidth, ScreenHeight)
    render = rendering == "render"
  defer: machine.release()
  defer: reference.release()
  var
    state, referenceState: Cpu
    profile = PcProfile(counts: newSeq[uint32](MemSize), flags: newSeq[uint8](MemSize))
  deserializeState(initialState, machine, state)
  deserializeState(initialState, reference, referenceState)
  echo &"initialBGMODE=${machine.ppuRegs[5]:02X}"
  for frame in 0 ..< frames:
    machine.joy1 = joy.uint16
    machine.profiledFrame(state, image, render, profile)
  let actualState = serializeState(machine, state)
  for frame in 0 ..< frames:
    reference.joy1 = joy.uint16
    reference.stepReplayFrame(referenceState, if render: referenceImage else: nil)
  if serializeState(reference, referenceState) != actualState:
    raise newException(AssertionDefect, "Instrumented frame ordering diverged from stepReplayFrame.")
  if render and image.data != referenceImage.data:
    raise newException(AssertionDefect, "Instrumented frame image diverged from stepReplayFrame.")
  let pixelVerification = if render: "IDENTICAL" else: "not-rendered"
  echo &"state={path.extractFilename} frames={frames} joy=${joy:04X} rendering={rendering} referenceState=IDENTICAL referencePixels={pixelVerification}"
  profile.report(rom)

main()
