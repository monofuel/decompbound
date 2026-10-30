## Batch the verified EarthBound event poll inside an existing CPU slot budget.
## Generic CPU stepping remains the reference and handles every untrusted case.

import
  ./[cpu, snesbus]

const
  PollBank = 0xC0'u8
  PollLoadPc = 0x875F'u16
  PollBranchPc = 0x8762'u16
  PollCodeAddress = (PollBank.int shl 16) or PollLoadPc.int
  PollCode = [0xAD'u8, 0x2B, 0x00, 0xF0, 0xFB]
    ## Own-ROM file $00875F: LDA $002B; BEQ -5, ending at file $008763.
    ## TODO: Replace offsets with named decompilation symbols when promoted.
  EventAddress = 0x7E002B
    ## Own-ROM file $00875F reads this event through DBR; $00818E increments it.
    ## TODO: Link this WRAM address to a named event-state declaration.
  WramBank = (EventAddress shr 16).uint8
  SystemBankMask = 0x7F'u8
  SystemBankLimit = 0x40'u8
    ## SNES bus system banks $00..$3F/$80..$BF mirror low WRAM at $002B.
  PairSlots = 2
  MinimumBatchSlots = PairSlots * 2

type
  ReadHook = proc(address: uint32): int
  WriteHook = proc(address: uint32, value: uint8): bool
  CpuPollingContext* = ref object
    originalBus: Bus
    readHook: ReadHook
    writeHook: WriteHook
    memory: pointer
    memoryLength: int

proc newPollingMachine*(rom: seq[uint8]): tuple[machine: SnesBus,
    polling: CpuPollingContext] =
  ## Construct a machine and retain only its freshly installed canonical hooks.
  let machine = newSnesBus(rom)
  result.machine = machine
  result.polling = CpuPollingContext(originalBus: machine.bus,
    readHook: machine.bus.readHook, writeHook: machine.bus.writeHook,
    memory: cast[pointer](addr machine.bus.mem[0]),
    memoryLength: machine.bus.mem.len)

proc pollingMatches*(polling: CpuPollingContext, machine: SnesBus): bool =
  ## Require the original bus, backing memory and exact hook closures to remain.
  if polling == nil or machine == nil or machine.bus == nil or
      polling.originalBus == nil or machine.bus != polling.originalBus:
    return false
  let bus = machine.bus
  result = bus.mem.len == polling.memoryLength and bus.mem.len > 0 and
    cast[pointer](addr bus.mem[0]) == polling.memory and
    bus.readHook == polling.readHook and bus.writeHook == polling.writeHook

proc canBatch(machine: SnesBus, state: Cpu, slots: int,
    polling: CpuPollingContext): bool =
  ## Admit only the unchanged byte-load loop while its WRAM event remains zero.
  if slots < MinimumBatchSlots or not polling.pollingMatches(machine) or
      state.pbr != PollBank or not state.m8 or state.nmiPending or
      state.waiting or state.stopped:
    return false
  if state.pc != PollLoadPc and
      (state.pc != PollBranchPc or (state.p and FlagZ) == 0):
    return false
  let eventBank = state.dbr == WramBank or
    (state.dbr and SystemBankMask) < SystemBankLimit
  if not eventBank or machine.bus.mem[EventAddress] != 0:
    return false
  for index, value in PollCode:
    if machine.bus.mem[PollCodeAddress + index] != value:
      return false
  result = true

proc stepCpuBatch*(machine: SnesBus, state: var Cpu, slots: int,
    polling: CpuPollingContext = nil): int =
  ## Consume the original slot budget and return the number of skipped poll steps.
  ## Callers must retain the existing device/event boundaries around this batch.
  if slots <= 0:
    return 0
  if not machine.canBatch(state, slots, polling):
    for slot in 0 ..< slots:
      state.step(machine.bus)
      if state.stopped:
        break
    return 0

  for slot in 0 ..< PairSlots:
    state.step(machine.bus)
  let remaining = slots - PairSlots
  result = remaining - remaining mod PairSlots
  if remaining mod PairSlots != 0:
    state.step(machine.bus)
