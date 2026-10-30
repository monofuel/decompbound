import
  std/unittest,
  decompbound/[cpu, cpu_polling, save_state, snesbus]

const
  RomBytes = 0x10000
  LoadPc = 0x875F'u16
  BranchPc = 0x8762'u16
  CodeAddress = 0xC0875F
  EventAddress = 0x7E002B
  WramStart = 0x7E0000
  WramBytes = 0x20000
  LoopBytes = [0xAD'u8, 0x2B, 0x00, 0xF0, 0xFB]
    ## Authored LDA $002B; BEQ -5, independently encoding the documented loop.
    ## TODO: Use symbolic assembly once the original routine has named labels.

proc syntheticRom(): seq[uint8] =
  ## Build a tiny authored HiROM containing the loop and an inert NMI target.
  result = newSeq[uint8](RomBytes)
  for index, value in LoopBytes: result[LoadPc.int + index] = value
  for index, value in "SYNTHETIC POLL TEST   ": result[0xFFC0 + index] = value.uint8
  result[0xFFD5] = 0x21 # Synthetic HiROM map mode.
  result[0xFFEA] = 0x00 # Native NMI vector $9000.
  result[0xFFEB] = 0x90
  result[0xFFFA] = 0x00 # Emulation NMI vector $9000.
  result[0xFFFB] = 0x90

proc release(machine: SnesBus, polling: var CpuPollingContext) =
  ## Discard retained closures before breaking the emulator's ordinary hook cycles.
  polling = nil
  machine.bus.readHook = nil
  machine.bus.writeHook = nil
  machine.apu.spc.readHook = nil
  machine.apu.spc.writeHook = nil

proc initial(pc: uint16, flags = FlagM or FlagZ): Cpu =
  ## Seed nontrivial registers so normalization and high-byte preservation matter.
  Cpu(a: 0xA5F3, x: 0x1234, y: 0xBEEF, s: 0xABCD, d: 0x5678,
    pc: pc, pbr: 0xC0, dbr: 0x7E, p: flags, mvnBudget: 77)

proc resetMemory(machine: SnesBus) =
  ## Reset writable witnesses and instruction bytes without changing bus identity.
  zeroMem(addr machine.bus.mem[WramStart], WramBytes)
  for index, value in LoopBytes: machine.bus.mem[CodeAddress + index] = value
  machine.bus.cpuInApuHandshake = true

proc ordinary(machine: SnesBus, state: var Cpu, slots: int) =
  ## Use only original instructions as the independent batch oracle.
  for slot in 0 ..< slots:
    state.step(machine.bus)
    if state.stopped: break

proc compare(machine, reference: SnesBus, state, expected: Cpu) =
  ## Compare every CPU field, both WRAM banks and the unserialized handshake flag.
  doAssert state == expected, $state & " != " & $expected
  doAssert equalMem(addr machine.bus.mem[WramStart],
    addr reference.bus.mem[WramStart], WramBytes)
  doAssert machine.bus.cpuInApuHandshake == reference.bus.cpuInApuHandshake

proc changingHook(machine: SnesBus, reads: ptr int): proc(address: uint32): int =
  ## Build the same hook code with independent captured environments and counters.
  let original = machine.bus.readHook
  result = proc(address: uint32): int =
    if address == EventAddress.uint32:
      inc reads[]
      if reads[] == 3: machine.bus.mem[EventAddress] = 1
    original(address)

suite "Guarded EarthBound polling batches":
  test "budgets, phases, flags and width invariants match original instructions":
    let rom = syntheticRom()
    var
      optimized = newPollingMachine(rom)
      reference = newPollingMachine(rom)
    defer:
      release(optimized.machine, optimized.polling)
      release(reference.machine, reference.polling)
    for pc in [LoadPc, BranchPc]:
      for flags in [FlagM or FlagZ, FlagM or FlagX or FlagZ,
          0xFF'u8, FlagM or FlagZ or FlagN or FlagC or FlagD]:
        for emulation in [false, true]:
          for slots in 0 .. 301:
            resetMemory(optimized.machine)
            resetMemory(reference.machine)
            var
              state = initial(pc, flags)
              expected = state
            state.emulation = emulation
            expected.emulation = emulation
            let skipped = stepCpuBatch(optimized.machine, state, slots, optimized.polling)
            ordinary(reference.machine, expected, slots)
            compare(optimized.machine, reference.machine, state, expected)
            check skipped == (if slots >= 4: (slots - 2) div 2 * 2 else: 0)
            if slots > 0:
              state.nmiPending = true
              expected.nmiPending = true
              state.step(optimized.machine.bus)
              expected.step(reference.machine.bus)
              compare(optimized.machine, reference.machine, state, expected)
    for flags in 0 .. 255:
      for emulation in [false, true]:
        resetMemory(optimized.machine)
        resetMemory(reference.machine)
        var
          state = initial(LoadPc, flags.uint8)
          expected = state
        state.emulation = emulation
        expected.emulation = emulation
        let byteWidth = state.m8
        let skipped = stepCpuBatch(optimized.machine, state, 150, optimized.polling)
        ordinary(reference.machine, expected, 150)
        compare(optimized.machine, reference.machine, state, expected)
        check skipped == (if byteWidth: 148 else: 0)

  test "WRAM mirrors and neighboring event bytes obey byte-load semantics":
    let rom = syntheticRom()
    var pair = newPollingMachine(rom)
    defer: release(pair.machine, pair.polling)
    for bank in [0'u8, 0x3F, 0x7E, 0x80, 0xBF]:
      resetMemory(pair.machine)
      pair.machine.bus.mem[EventAddress + 1] = 1
      var state = initial(LoadPc)
      state.dbr = bank
      check stepCpuBatch(pair.machine, state, 150, pair.polling) == 148
      check state.a == 0xA500

  test "eligibility is recalculated when the event and execution phase change":
    var pair = newPollingMachine(syntheticRom())
    defer: release(pair.machine, pair.polling)
    var state = initial(LoadPc)
    check stepCpuBatch(pair.machine, state, 150, pair.polling) == 148
    pair.machine.bus.mem[EventAddress] = 1
    check stepCpuBatch(pair.machine, state, 2, pair.polling) == 0
    check state.pc == BranchPc + 2
    pair.machine.bus.mem[EventAddress] = 0
    state.pc = LoadPc
    check stepCpuBatch(pair.machine, state, 150, pair.polling) == 148
    state = initial(LoadPc)
    check stepCpuBatch(pair.machine, state, 150) == 0

  test "changed code, events and unsupported execution states fall back exactly":
    let rom = syntheticRom()
    var
      optimized = newPollingMachine(rom)
      reference = newPollingMachine(rom)
    defer:
      release(optimized.machine, optimized.polling)
      release(reference.machine, reference.polling)
    for scenario in 0 .. 10:
      resetMemory(optimized.machine)
      resetMemory(reference.machine)
      var state = initial(LoadPc)
      case scenario
      of 0:
        optimized.machine.bus.mem[EventAddress] = 1
        reference.machine.bus.mem[EventAddress] = 1
      of 1: state.dbr = 0x7F
      of 2: state.pbr = 0x40
      of 3: state.p = FlagZ
      of 4: state.nmiPending = true
      of 5: state.waiting = true
      of 6: state.stopped = true
      of 7:
        state.pc = BranchPc
        state.p = FlagM
      of 8:
        optimized.machine.bus.mem[CodeAddress] = 0xEA # Authored NOP mutation.
        reference.machine.bus.mem[CodeAddress] = 0xEA
      of 9:
        optimized.machine.bus.mem[CodeAddress + 1] = 0x2C
        reference.machine.bus.mem[CodeAddress + 1] = 0x2C
      else:
        optimized.machine.bus.mem[CodeAddress + 4] = 0xFE # Authored self-branch.
        reference.machine.bus.mem[CodeAddress + 4] = 0xFE
      var expected = state
      check stepCpuBatch(optimized.machine, state, 9, optimized.polling) == 0
      ordinary(reference.machine, expected, 9)
      compare(optimized.machine, reference.machine, state, expected)

  test "hook identity includes closures and custom readers remain observable":
    let rom = syntheticRom()
    var
      optimized = newPollingMachine(rom)
      reference = newPollingMachine(rom)
      reads, referenceReads: int
    defer:
      release(optimized.machine, optimized.polling)
      release(reference.machine, reference.polling)
    let
      readHook = optimized.machine.bus.readHook
      writeHook = optimized.machine.bus.writeHook
    check optimized.polling.pollingMatches(optimized.machine)
    optimized.machine.bus.readHook = nil
    check not optimized.polling.pollingMatches(optimized.machine)
    optimized.machine.bus.readHook = reference.machine.bus.readHook
    check not optimized.polling.pollingMatches(optimized.machine)
    optimized.machine.bus.readHook = readHook
    optimized.machine.bus.writeHook = reference.machine.bus.writeHook
    check not optimized.polling.pollingMatches(optimized.machine)
    optimized.machine.bus.writeHook = writeHook
    check optimized.polling.pollingMatches(optimized.machine)
    optimized.machine.bus.readHook = changingHook(optimized.machine, addr reads)
    reference.machine.bus.readHook = changingHook(reference.machine, addr referenceReads)
    var
      state = initial(LoadPc)
      expected = state
    check stepCpuBatch(optimized.machine, state, 6, optimized.polling) == 0
    ordinary(reference.machine, expected, 6)
    compare(optimized.machine, reference.machine, state, expected)
    check reads == 3 and referenceReads == 3
    check optimized.machine.bus.mem[EventAddress] == 1

  test "bus and buffer replacement invalidate trust without touching stale memory":
    var pair = newPollingMachine(syntheticRom())
    let bus = pair.machine.bus
    pair.machine.bus = newBus()
    check not pair.polling.pollingMatches(pair.machine)
    pair.machine.bus = bus
    check pair.polling.pollingMatches(pair.machine)
    var replacement = newSeq[uint8](MemSize)
    let originalAddress = cast[pointer](addr pair.machine.bus.mem[0])
    swap(pair.machine.bus.mem, replacement)
    check cast[pointer](addr pair.machine.bus.mem[0]) != originalAddress
    check not pair.polling.pollingMatches(pair.machine)
    swap(pair.machine.bus.mem, replacement)
    check pair.polling.pollingMatches(pair.machine)
    release(pair.machine, pair.polling)

  test "reset and state import retain original trust without blessing custom hooks":
    var pair = newPollingMachine(syntheticRom())
    defer: release(pair.machine, pair.polling)
    var state = initial(LoadPc)
    let
      bytes = serializeState(pair.machine, state)
      readHook = pair.machine.bus.readHook
    state = pair.machine.softReset()
    check pair.polling.pollingMatches(pair.machine)
    deserializeState(bytes, pair.machine, state)
    check pair.polling.pollingMatches(pair.machine)
    pair.machine.bus.readHook = proc(address: uint32): int = readHook(address)
    check not pair.polling.pollingMatches(pair.machine)
    state = pair.machine.softReset()
    check not pair.polling.pollingMatches(pair.machine)
    deserializeState(bytes, pair.machine, state)
    check not pair.polling.pollingMatches(pair.machine)
