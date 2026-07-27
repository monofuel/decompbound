## 65816 CPU core: the third derivation of the shared opcode table
## (opcodes.nim), alongside the assembler and disassembler. Instruction-level
## accuracy verified against SingleStepTests vectors (tests/test_cpu.nim);
## cycle-level timing is out of scope (docs/goal.md: Earthbound does not
## race the beam).

import
  ./opcodes

const
  FlagC* = 0x01'u8
  FlagZ* = 0x02'u8
  FlagI* = 0x04'u8
  FlagD* = 0x08'u8
  FlagX* = 0x10'u8  ## Index width (B break bit when pushed in emulation).
  FlagM* = 0x20'u8  ## Accumulator width.
  FlagV* = 0x40'u8
  FlagN* = 0x80'u8

  MemSize* = 0x1000000  ## Full 24-bit address space for the test harness.

type
  Bus* = ref object
    ## Flat 16MB memory. The harness resets dirtied bytes between tests.
    ## The SNES bus (snesbus.nim) layers mirrors and MMIO on via hooks:
    ## readHook returns -1 to fall through to flat memory; writeHook
    ## returns true when it fully handled the write.
    mem*: seq[uint8]
    dirty*: seq[int]
    recordDirty*: bool  ## OFF by default. Only the vector-test harness needs the
                        ## dirty list (to reset touched RAM between tests); in normal
                        ## emulation it grew one int per write forever — a heap leak
                        ## and the source of the rare realloc-copy frame stutter.
    readHook*: proc(address: uint32): int
    writeHook*: proc(address: uint32, value: uint8): bool
    cpuInApuUpload*: bool
      ## Set each instruction from CPU PBR:PC when inside uploadApuPackages
      ## ($C0AB06-$C0ABBC). snesbus.mmioRead raises the $214x catch-up cap
      ## while true so full package uploads do not starve the SPC.

  Cpu* = object
    a*: uint16
    x*: uint16
    y*: uint16
    s*: uint16
    d*: uint16
    pc*: uint16
    dbr*: uint8
    pbr*: uint8
    p*: uint8
    emulation*: bool
    stopped*: bool
    waiting*: bool
    mvnBudget*: int  ## Cycle budget per block-move step. <= 0 means run to
                     ## completion (hardware behavior); the vector harness
                     ## sets 100 to match SingleStepTests snapshots.
    nmiPending*: bool  ## Set by the system when vblank NMI fires.

proc newBus*(): Bus =
  ## Allocate the flat memory bus.
  Bus(mem: newSeq[uint8](MemSize))

proc read8*(bus: Bus, address: uint32): uint8 =
  ## Read one byte from the 24-bit address space.
  if bus.readHook != nil:
    let hooked = bus.readHook(address and 0xFFFFFF)
    if hooked >= 0:
      return hooked.uint8
  bus.mem[address and 0xFFFFFF]

proc write8*(bus: Bus, address: uint32, value: uint8) =
  ## Write one byte and remember it for harness cleanup.
  if bus.writeHook != nil and bus.writeHook(address and 0xFFFFFF, value):
    return
  bus.mem[(address and 0xFFFFFF).int] = value
  if bus.recordDirty:
    bus.dirty.add (address and 0xFFFFFF).int

proc read16*(bus: Bus, address: uint32): uint16 =
  ## Read a little-endian word, crossing banks linearly (data semantics).
  bus.read8(address).uint16 or (bus.read8(address + 1).uint16 shl 8)

proc read16Wrap*(bus: Bus, bank: uint32, offset: uint16): uint16 =
  ## Read a word whose second byte wraps within a 64KB bank (pointer
  ## semantics for bank-0 indirection and program fetches).
  bus.read8(bank or offset).uint16 or
    (bus.read8(bank or ((offset + 1) and 0xFFFF).uint32).uint16 shl 8)

proc m8*(cpu: Cpu): bool =
  ## Accumulator/memory operations are 8-bit.
  cpu.emulation or (cpu.p and FlagM) != 0

proc x8*(cpu: Cpu): bool =
  ## Index register operations are 8-bit.
  cpu.emulation or (cpu.p and FlagX) != 0

proc setFlag(cpu: var Cpu, flag: uint8, on: bool) =
  ## Set or clear one status bit.
  if on:
    cpu.p = cpu.p or flag
  else:
    cpu.p = cpu.p and not flag

proc getFlag(cpu: Cpu, flag: uint8): bool =
  ## Test one status bit.
  (cpu.p and flag) != 0

proc setNZ8(cpu: var Cpu, value: uint8) =
  ## Set N and Z from an 8-bit result.
  cpu.setFlag(FlagZ, value == 0)
  cpu.setFlag(FlagN, (value and 0x80) != 0)

proc setNZ16(cpu: var Cpu, value: uint16) =
  ## Set N and Z from a 16-bit result.
  cpu.setFlag(FlagZ, value == 0)
  cpu.setFlag(FlagN, (value and 0x8000) != 0)

proc forceWidthInvariants(cpu: var Cpu) =
  ## Apply the hardware invariants for emulation mode and 8-bit index mode.
  if cpu.emulation:
    cpu.p = cpu.p or FlagM or FlagX
    cpu.s = 0x0100'u16 or (cpu.s and 0xFF)
  if (cpu.p and FlagX) != 0:
    cpu.x = cpu.x and 0xFF
    cpu.y = cpu.y and 0xFF

proc push8(cpu: var Cpu, bus: Bus, value: uint8, wrap: bool = true) =
  ## Push one byte. The stack lives in bank 0. In emulation mode the
  ## original 6502 instructions wrap within page 1 (wrap = true); the new
  ## 65816 instructions (PHD, PEA, JSL, ...) use S as a full 16-bit
  ## pointer during the operation (wrap = false) and S snaps back to
  ## page 1 afterwards via forceWidthInvariants.
  bus.write8(cpu.s.uint32, value)
  if cpu.emulation and wrap:
    cpu.s = 0x0100'u16 or ((cpu.s - 1) and 0xFF)
  else:
    cpu.s = cpu.s - 1

proc pull8(cpu: var Cpu, bus: Bus, wrap: bool = true): uint8 =
  ## Pull one byte, honoring emulation-mode page-1 wrap for the original
  ## instructions only (see push8).
  if cpu.emulation and wrap:
    cpu.s = 0x0100'u16 or ((cpu.s + 1) and 0xFF)
  else:
    cpu.s = cpu.s + 1
  result = bus.read8(cpu.s.uint32)

proc push16(cpu: var Cpu, bus: Bus, value: uint16, wrap: bool = true) =
  ## Push a word, high byte first.
  cpu.push8(bus, (value shr 8).uint8, wrap)
  cpu.push8(bus, (value and 0xFF).uint8, wrap)

proc pull16(cpu: var Cpu, bus: Bus, wrap: bool = true): uint16 =
  ## Pull a word, low byte first.
  result = cpu.pull8(bus, wrap).uint16
  result = result or (cpu.pull8(bus, wrap).uint16 shl 8)

proc fetch8(cpu: var Cpu, bus: Bus): uint8 =
  ## Fetch the next program byte; PC wraps within the program bank.
  result = bus.read8((cpu.pbr.uint32 shl 16) or cpu.pc.uint32)
  cpu.pc = cpu.pc + 1

proc fetch16(cpu: var Cpu, bus: Bus): uint16 =
  ## Fetch a program word.
  result = cpu.fetch8(bus).uint16
  result = result or (cpu.fetch8(bus).uint16 shl 8)

proc directOffset(cpu: Cpu, operand: uint8, index: uint16 = 0): uint16 =
  ## Direct page effective offset in bank 0. In emulation mode with DL == 0,
  ## indexed direct page addresses wrap within the page.
  if cpu.emulation and (cpu.d and 0xFF) == 0 and index != 0:
    (cpu.d and 0xFF00) or ((operand.uint16 + index) and 0xFF)
  else:
    cpu.d + operand.uint16 + index

proc directPointer16(cpu: Cpu, bus: Bus, operand: uint8, index: uint16 = 0): uint16 =
  ## Read a 16-bit pointer from the direct page. The base honors the
  ## emulation-mode DL == 0 page wrap for indexed forms (directOffset);
  ## the second pointer byte reads linearly with 16-bit bank-0 wrap
  ## (verified against silicon by SingleStepTests e1 e 8669).
  let base = cpu.directOffset(operand, index)
  bus.read16Wrap(0, base)

type
  Operand = object
    ## Resolved operand: either an immediate value or an effective address.
    isImmediate: bool
    value: uint16
    address: uint32
    wrapBank0: bool  ## 16-bit accesses wrap within bank 0 (dp, sr modes).

proc resolve(cpu: var Cpu, bus: Bus, mode: AddressingMode,
             indexIsX: bool): Operand =
  ## Fetch operand bytes and resolve the effective address for a data
  ## access. Control-flow modes are handled by their instructions directly.
  case mode:
  of amImmediateM:
    result.isImmediate = true
    if cpu.m8:
      result.value = cpu.fetch8(bus).uint16
    else:
      result.value = cpu.fetch16(bus)
  of amImmediateX:
    result.isImmediate = true
    if cpu.x8:
      result.value = cpu.fetch8(bus).uint16
    else:
      result.value = cpu.fetch16(bus)
  of amImmediate8:
    result.isImmediate = true
    result.value = cpu.fetch8(bus).uint16
  of amDirectPage:
    result.address = cpu.directOffset(cpu.fetch8(bus)).uint32
    result.wrapBank0 = true
  of amDirectPageX:
    result.address = cpu.directOffset(cpu.fetch8(bus), cpu.x).uint32
    result.wrapBank0 = true
  of amDirectPageY:
    result.address = cpu.directOffset(cpu.fetch8(bus), cpu.y).uint32
    result.wrapBank0 = true
  of amDpIndirect:
    let ptr16 = cpu.directPointer16(bus, cpu.fetch8(bus))
    result.address = (cpu.dbr.uint32 shl 16) or ptr16.uint32
  of amDpIndirectX:
    let ptr16 = cpu.directPointer16(bus, cpu.fetch8(bus), cpu.x)
    result.address = (cpu.dbr.uint32 shl 16) or ptr16.uint32
  of amDpIndirectY:
    let ptr16 = cpu.directPointer16(bus, cpu.fetch8(bus))
    result.address = ((cpu.dbr.uint32 shl 16) or ptr16.uint32) + cpu.y.uint32
  of amDpIndirectLong:
    let base = cpu.d + cpu.fetch8(bus).uint16
    let lo = bus.read8(base.uint32)
    let mid = bus.read8(((base + 1) and 0xFFFF).uint32)
    let hi = bus.read8(((base + 2) and 0xFFFF).uint32)
    result.address = lo.uint32 or (mid.uint32 shl 8) or (hi.uint32 shl 16)
  of amDpIndirectLongY:
    let base = cpu.d + cpu.fetch8(bus).uint16
    let lo = bus.read8(base.uint32)
    let mid = bus.read8(((base + 1) and 0xFFFF).uint32)
    let hi = bus.read8(((base + 2) and 0xFFFF).uint32)
    result.address = (lo.uint32 or (mid.uint32 shl 8) or (hi.uint32 shl 16)) +
      cpu.y.uint32
  of amAbsolute:
    result.address = (cpu.dbr.uint32 shl 16) or cpu.fetch16(bus).uint32
  of amAbsoluteX:
    result.address = ((cpu.dbr.uint32 shl 16) or cpu.fetch16(bus).uint32) +
      cpu.x.uint32
  of amAbsoluteY:
    result.address = ((cpu.dbr.uint32 shl 16) or cpu.fetch16(bus).uint32) +
      cpu.y.uint32
  of amAbsoluteLong:
    let lo = cpu.fetch16(bus)
    let hi = cpu.fetch8(bus)
    result.address = lo.uint32 or (hi.uint32 shl 16)
  of amAbsoluteLongX:
    let lo = cpu.fetch16(bus)
    let hi = cpu.fetch8(bus)
    result.address = (lo.uint32 or (hi.uint32 shl 16)) + cpu.x.uint32
  of amStackRelative:
    result.address = ((cpu.s + cpu.fetch8(bus).uint16) and 0xFFFF).uint32
    result.wrapBank0 = true
  of amStackRelativeY:
    let base = (cpu.s + cpu.fetch8(bus).uint16) and 0xFFFF
    let ptr16 = bus.read16Wrap(0, base)
    result.address = ((cpu.dbr.uint32 shl 16) or ptr16.uint32) + cpu.y.uint32
  else:
    doAssert false, "resolve called for non-data mode: " & $mode
  discard indexIsX

proc loadValue(cpu: Cpu, bus: Bus, op: Operand, wide: bool): uint16 =
  ## Load the operand value at instruction width. Direct page and stack
  ## relative accesses wrap within bank 0 for the high byte.
  if op.isImmediate:
    op.value
  elif wide:
    if op.wrapBank0:
      bus.read16Wrap(0, (op.address and 0xFFFF).uint16)
    else:
      bus.read16(op.address)
  else:
    bus.read8(op.address).uint16

proc storeValue(cpu: Cpu, bus: Bus, op: Operand, value: uint16, wide: bool) =
  ## Store a result at instruction width, honoring bank-0 wrap.
  bus.write8(op.address, (value and 0xFF).uint8)
  if wide:
    if op.wrapBank0:
      bus.write8(((op.address + 1) and 0xFFFF), (value shr 8).uint8)
    else:
      bus.write8(op.address + 1, (value shr 8).uint8)

proc adc(cpu: var Cpu, value: uint16) =
  ## Add with carry, honoring decimal mode and accumulator width.
  let carryIn = if cpu.getFlag(FlagC): 1'u32 else: 0'u32
  if cpu.m8:
    let a = cpu.a and 0xFF
    let b = value and 0xFF
    var r: uint32
    if cpu.getFlag(FlagD):
      var lo = (a and 0x0F).uint32 + (b and 0x0F).uint32 + carryIn
      if lo > 9: lo += 6
      var hi = (a shr 4).uint32 + (b shr 4).uint32 + (if lo > 0x0F: 1'u32 else: 0)
      cpu.setFlag(FlagV, ((not (a.uint32 xor b.uint32)) and
        (a.uint32 xor ((hi shl 4) or (lo and 0x0F))) and 0x80) != 0)
      if hi > 9: hi += 6
      r = ((hi shl 4) or (lo and 0x0F))
      cpu.setFlag(FlagC, hi > 0x0F)
    else:
      r = a.uint32 + b.uint32 + carryIn
      cpu.setFlag(FlagV, ((not (a.uint32 xor b.uint32)) and
        (a.uint32 xor r) and 0x80) != 0)
      cpu.setFlag(FlagC, r > 0xFF)
    cpu.a = (cpu.a and 0xFF00) or (r and 0xFF).uint16
    cpu.setNZ8((r and 0xFF).uint8)
  else:
    let a = cpu.a
    let b = value
    var r: uint32
    if cpu.getFlag(FlagD):
      var d0 = (a and 0x000F).uint32 + (b and 0x000F).uint32 + carryIn
      if d0 > 9: d0 += 6
      var d1 = ((a shr 4) and 0xF).uint32 + ((b shr 4) and 0xF).uint32 +
        (if d0 > 0x0F: 1'u32 else: 0)
      if d1 > 9: d1 += 6
      var d2 = ((a shr 8) and 0xF).uint32 + ((b shr 8) and 0xF).uint32 +
        (if d1 > 0x0F: 1'u32 else: 0)
      if d2 > 9: d2 += 6
      var d3 = ((a shr 12) and 0xF).uint32 + ((b shr 12) and 0xF).uint32 +
        (if d2 > 0x0F: 1'u32 else: 0)
      let partial = ((d3 and 0xF) shl 12) or ((d2 and 0xF) shl 8) or
        ((d1 and 0xF) shl 4) or (d0 and 0xF)
      cpu.setFlag(FlagV, ((not (a.uint32 xor b.uint32)) and
        (a.uint32 xor partial) and 0x8000) != 0)
      if d3 > 9: d3 += 6
      r = ((d3 and 0x1F) shl 12) or ((d2 and 0xF) shl 8) or
        ((d1 and 0xF) shl 4) or (d0 and 0xF)
      cpu.setFlag(FlagC, d3 > 0x0F)
    else:
      r = a.uint32 + b.uint32 + carryIn
      cpu.setFlag(FlagV, ((not (a.uint32 xor b.uint32)) and
        (a.uint32 xor r) and 0x8000) != 0)
      cpu.setFlag(FlagC, r > 0xFFFF)
    cpu.a = (r and 0xFFFF).uint16
    cpu.setNZ16(cpu.a)

proc sbc(cpu: var Cpu, value: uint16) =
  ## Subtract with borrow, honoring decimal mode and accumulator width.
  let carryIn = if cpu.getFlag(FlagC): 1'u32 else: 0'u32
  if cpu.m8:
    let a = (cpu.a and 0xFF).uint32
    let b = (value and 0xFF).uint32 xor 0xFF
    var r = a + b + carryIn
    cpu.setFlag(FlagV, ((not (a xor b)) and (a xor r) and 0x80) != 0)
    if cpu.getFlag(FlagD):
      var lo = (a and 0x0F) + (b and 0x0F) + carryIn
      var hi = (a shr 4) + (b shr 4) + (if lo > 0x0F: 1'u32 else: 0)
      if lo < 0x10: lo -= 6
      if hi < 0x10: hi -= 6
      r = ((hi and 0xF) shl 4) or (lo and 0x0F) or (r and 0x100)
    cpu.setFlag(FlagC, r > 0xFF)
    cpu.a = (cpu.a and 0xFF00) or (r and 0xFF).uint16
    cpu.setNZ8((r and 0xFF).uint8)
  else:
    let a = cpu.a.uint32
    let b = value.uint32 xor 0xFFFF
    var r = a + b + carryIn
    cpu.setFlag(FlagV, ((not (a xor b)) and (a xor r) and 0x8000) != 0)
    if cpu.getFlag(FlagD):
      var d0 = (a and 0xF) + (b and 0xF) + carryIn
      var d1 = ((a shr 4) and 0xF) + ((b shr 4) and 0xF) +
        (if d0 > 0xF: 1'u32 else: 0)
      var d2 = ((a shr 8) and 0xF) + ((b shr 8) and 0xF) +
        (if d1 > 0xF: 1'u32 else: 0)
      var d3 = ((a shr 12) and 0xF) + ((b shr 12) and 0xF) +
        (if d2 > 0xF: 1'u32 else: 0)
      if d0 < 0x10: d0 -= 6
      if d1 < 0x10: d1 -= 6
      if d2 < 0x10: d2 -= 6
      if d3 < 0x10: d3 -= 6
      r = ((d3 and 0xF) shl 12) or ((d2 and 0xF) shl 8) or
        ((d1 and 0xF) shl 4) or (d0 and 0xF) or (r and 0x10000)
    cpu.setFlag(FlagC, r > 0xFFFF)
    cpu.a = (r and 0xFFFF).uint16
    cpu.setNZ16(cpu.a)

proc compare(cpu: var Cpu, reg: uint16, value: uint16, wide: bool) =
  ## CMP/CPX/CPY: subtract without storing, set N/Z/C.
  if wide:
    let r = reg.uint32 + (value.uint32 xor 0xFFFF) + 1
    cpu.setFlag(FlagC, r > 0xFFFF)
    cpu.setNZ16((r and 0xFFFF).uint16)
  else:
    let r = (reg and 0xFF).uint32 + ((value and 0xFF).uint32 xor 0xFF) + 1
    cpu.setFlag(FlagC, r > 0xFF)
    cpu.setNZ8((r and 0xFF).uint8)

proc branch(cpu: var Cpu, bus: Bus, taken: bool) =
  ## Fetch an 8-bit displacement and branch within the program bank.
  let disp = cast[int8](cpu.fetch8(bus))
  if taken:
    cpu.pc = (cpu.pc.int32 + disp.int32).uint16

proc interrupt(cpu: var Cpu, bus: Bus, nativeVector: uint16,
               emulationVector: uint16) =
  ## Software interrupt entry (BRK/COP): push state and jump through the
  ## bank-0 vector. The signature byte has already been fetched.
  if cpu.emulation:
    cpu.push16(bus, cpu.pc)
    cpu.push8(bus, cpu.p or 0x30)
    cpu.setFlag(FlagI, true)
    cpu.setFlag(FlagD, false)
    cpu.pbr = 0
    cpu.pc = bus.read16(emulationVector.uint32)
  else:
    cpu.push8(bus, cpu.pbr)
    cpu.push16(bus, cpu.pc)
    cpu.push8(bus, cpu.p)
    cpu.setFlag(FlagI, true)
    cpu.setFlag(FlagD, false)
    cpu.pbr = 0
    cpu.pc = bus.read16(nativeVector.uint32)

proc serviceNmi(cpu: var Cpu, bus: Bus) =
  ## Deliver a non-maskable interrupt through the hardware vector.
  cpu.waiting = false
  if cpu.emulation:
    cpu.push16(bus, cpu.pc)
    cpu.push8(bus, cpu.p or 0x20)
    cpu.setFlag(FlagI, true)
    cpu.setFlag(FlagD, false)
    cpu.pbr = 0
    cpu.pc = bus.read16(0xFFFA)
  else:
    cpu.push8(bus, cpu.pbr)
    cpu.push16(bus, cpu.pc)
    cpu.push8(bus, cpu.p)
    cpu.setFlag(FlagI, true)
    cpu.setFlag(FlagD, false)
    cpu.pbr = 0
    cpu.pc = bus.read16(0xFFEA)

proc step*(cpu: var Cpu, bus: Bus) =
  ## Execute one instruction.
  if cpu.stopped:
    return
  if cpu.nmiPending:
    cpu.nmiPending = false
    cpu.serviceNmi(bus)
    return
  if cpu.waiting:
    return
  # Emulation-mode hardware invariants hold continuously, not just at mode
  # transitions: S is pinned to page 1, M/X read as set, X/Y high clear.
  cpu.forceWidthInvariants()
  # Upload-range flag for APU port catch-up (two compares + store per instr).
  # PC is pre-fetch so multi-byte ops still count as inside the routine.
  bus.cpuInApuUpload =
    cpu.pbr == 0xC0'u8 and cpu.pc >= 0xAB06'u16 and cpu.pc <= 0xABBC'u16
  let opcode = cpu.fetch8(bus)
  let info = OpcodeTable[opcode]
  let mode = info.mode

  template dataOp(): Operand =
    cpu.resolve(bus, mode, true)

  case info.mnemonic:
  # Flag operations.
  of "CLC": cpu.setFlag(FlagC, false)
  of "SEC": cpu.setFlag(FlagC, true)
  of "CLI": cpu.setFlag(FlagI, false)
  of "SEI": cpu.setFlag(FlagI, true)
  of "CLD": cpu.setFlag(FlagD, false)
  of "SED": cpu.setFlag(FlagD, true)
  of "CLV": cpu.setFlag(FlagV, false)
  of "REP":
    let mask = cpu.fetch8(bus)
    cpu.p = cpu.p and not mask
    cpu.forceWidthInvariants()
  of "SEP":
    let mask = cpu.fetch8(bus)
    cpu.p = cpu.p or mask
    cpu.forceWidthInvariants()
  of "XCE":
    let oldCarry = cpu.getFlag(FlagC)
    cpu.setFlag(FlagC, cpu.emulation)
    cpu.emulation = oldCarry
    cpu.forceWidthInvariants()

  # Loads and stores.
  of "LDA":
    let op = dataOp()
    let v = cpu.loadValue(bus, op, not cpu.m8)
    if cpu.m8:
      cpu.a = (cpu.a and 0xFF00) or (v and 0xFF)
      cpu.setNZ8((v and 0xFF).uint8)
    else:
      cpu.a = v
      cpu.setNZ16(v)
  of "LDX":
    let op = dataOp()
    let v = cpu.loadValue(bus, op, not cpu.x8)
    cpu.x = if cpu.x8: v and 0xFF else: v
    if cpu.x8: cpu.setNZ8((v and 0xFF).uint8) else: cpu.setNZ16(v)
  of "LDY":
    let op = dataOp()
    let v = cpu.loadValue(bus, op, not cpu.x8)
    cpu.y = if cpu.x8: v and 0xFF else: v
    if cpu.x8: cpu.setNZ8((v and 0xFF).uint8) else: cpu.setNZ16(v)
  of "STA":
    let op = dataOp()
    cpu.storeValue(bus, op, cpu.a, not cpu.m8)
  of "STX":
    let op = dataOp()
    cpu.storeValue(bus, op, cpu.x, not cpu.x8)
  of "STY":
    let op = dataOp()
    cpu.storeValue(bus, op, cpu.y, not cpu.x8)
  of "STZ":
    let op = dataOp()
    cpu.storeValue(bus, op, 0, not cpu.m8)

  # Register transfers.
  of "TAX":
    cpu.x = if cpu.x8: cpu.a and 0xFF else: cpu.a
    if cpu.x8: cpu.setNZ8((cpu.x and 0xFF).uint8) else: cpu.setNZ16(cpu.x)
  of "TAY":
    cpu.y = if cpu.x8: cpu.a and 0xFF else: cpu.a
    if cpu.x8: cpu.setNZ8((cpu.y and 0xFF).uint8) else: cpu.setNZ16(cpu.y)
  of "TXA":
    if cpu.m8:
      cpu.a = (cpu.a and 0xFF00) or (cpu.x and 0xFF)
      cpu.setNZ8((cpu.a and 0xFF).uint8)
    else:
      cpu.a = cpu.x
      cpu.setNZ16(cpu.a)
  of "TYA":
    if cpu.m8:
      cpu.a = (cpu.a and 0xFF00) or (cpu.y and 0xFF)
      cpu.setNZ8((cpu.a and 0xFF).uint8)
    else:
      cpu.a = cpu.y
      cpu.setNZ16(cpu.a)
  of "TXY":
    cpu.y = if cpu.x8: cpu.x and 0xFF else: cpu.x
    if cpu.x8: cpu.setNZ8((cpu.y and 0xFF).uint8) else: cpu.setNZ16(cpu.y)
  of "TYX":
    cpu.x = if cpu.x8: cpu.y and 0xFF else: cpu.y
    if cpu.x8: cpu.setNZ8((cpu.x and 0xFF).uint8) else: cpu.setNZ16(cpu.x)
  of "TSX":
    cpu.x = if cpu.x8: cpu.s and 0xFF else: cpu.s
    if cpu.x8: cpu.setNZ8((cpu.x and 0xFF).uint8) else: cpu.setNZ16(cpu.x)
  of "TXS":
    if cpu.emulation:
      cpu.s = 0x0100'u16 or (cpu.x and 0xFF)
    else:
      cpu.s = cpu.x
  of "TCD":
    cpu.d = cpu.a
    cpu.setNZ16(cpu.d)
  of "TDC":
    cpu.a = cpu.d
    cpu.setNZ16(cpu.a)
  of "TCS":
    if cpu.emulation:
      cpu.s = 0x0100'u16 or (cpu.a and 0xFF)
    else:
      cpu.s = cpu.a
  of "TSC":
    cpu.a = cpu.s
    cpu.setNZ16(cpu.a)
  of "XBA":
    cpu.a = (cpu.a shl 8) or (cpu.a shr 8)
    cpu.setNZ8((cpu.a and 0xFF).uint8)

  # Arithmetic and logic.
  of "ADC":
    let op = dataOp()
    cpu.adc(cpu.loadValue(bus, op, not cpu.m8))
  of "SBC":
    let op = dataOp()
    cpu.sbc(cpu.loadValue(bus, op, not cpu.m8))
  of "AND":
    let op = dataOp()
    let v = cpu.loadValue(bus, op, not cpu.m8)
    if cpu.m8:
      cpu.a = (cpu.a and 0xFF00) or ((cpu.a and v) and 0xFF)
      cpu.setNZ8((cpu.a and 0xFF).uint8)
    else:
      cpu.a = cpu.a and v
      cpu.setNZ16(cpu.a)
  of "ORA":
    let op = dataOp()
    let v = cpu.loadValue(bus, op, not cpu.m8)
    if cpu.m8:
      cpu.a = (cpu.a and 0xFF00) or ((cpu.a or v) and 0xFF)
      cpu.setNZ8((cpu.a and 0xFF).uint8)
    else:
      cpu.a = cpu.a or v
      cpu.setNZ16(cpu.a)
  of "EOR":
    let op = dataOp()
    let v = cpu.loadValue(bus, op, not cpu.m8)
    if cpu.m8:
      cpu.a = (cpu.a and 0xFF00) or ((cpu.a xor v) and 0xFF)
      cpu.setNZ8((cpu.a and 0xFF).uint8)
    else:
      cpu.a = cpu.a xor v
      cpu.setNZ16(cpu.a)
  of "CMP":
    let op = dataOp()
    cpu.compare(cpu.a, cpu.loadValue(bus, op, not cpu.m8), not cpu.m8)
  of "CPX":
    let op = dataOp()
    cpu.compare(cpu.x, cpu.loadValue(bus, op, not cpu.x8), not cpu.x8)
  of "CPY":
    let op = dataOp()
    cpu.compare(cpu.y, cpu.loadValue(bus, op, not cpu.x8), not cpu.x8)
  of "BIT":
    let op = dataOp()
    let v = cpu.loadValue(bus, op, not cpu.m8)
    if cpu.m8:
      cpu.setFlag(FlagZ, ((cpu.a and v) and 0xFF) == 0)
      if not op.isImmediate:
        cpu.setFlag(FlagN, (v and 0x80) != 0)
        cpu.setFlag(FlagV, (v and 0x40) != 0)
    else:
      cpu.setFlag(FlagZ, (cpu.a and v) == 0)
      if not op.isImmediate:
        cpu.setFlag(FlagN, (v and 0x8000) != 0)
        cpu.setFlag(FlagV, (v and 0x4000) != 0)
  of "TSB":
    let op = dataOp()
    let v = cpu.loadValue(bus, op, not cpu.m8)
    if cpu.m8:
      cpu.setFlag(FlagZ, ((cpu.a and v) and 0xFF) == 0)
      cpu.storeValue(bus, op, v or (cpu.a and 0xFF), false)
    else:
      cpu.setFlag(FlagZ, (cpu.a and v) == 0)
      cpu.storeValue(bus, op, v or cpu.a, true)
  of "TRB":
    let op = dataOp()
    let v = cpu.loadValue(bus, op, not cpu.m8)
    if cpu.m8:
      cpu.setFlag(FlagZ, ((cpu.a and v) and 0xFF) == 0)
      cpu.storeValue(bus, op, v and not (cpu.a and 0xFF), false)
    else:
      cpu.setFlag(FlagZ, (cpu.a and v) == 0)
      cpu.storeValue(bus, op, v and not cpu.a, true)

  # Increments and decrements.
  of "INC":
    if mode == amAccumulator:
      if cpu.m8:
        cpu.a = (cpu.a and 0xFF00) or ((cpu.a + 1) and 0xFF)
        cpu.setNZ8((cpu.a and 0xFF).uint8)
      else:
        cpu.a = cpu.a + 1
        cpu.setNZ16(cpu.a)
    else:
      let op = dataOp()
      let v = cpu.loadValue(bus, op, not cpu.m8) + 1
      cpu.storeValue(bus, op, v, not cpu.m8)
      if cpu.m8: cpu.setNZ8((v and 0xFF).uint8) else: cpu.setNZ16(v)
  of "DEC":
    if mode == amAccumulator:
      if cpu.m8:
        cpu.a = (cpu.a and 0xFF00) or ((cpu.a - 1) and 0xFF)
        cpu.setNZ8((cpu.a and 0xFF).uint8)
      else:
        cpu.a = cpu.a - 1
        cpu.setNZ16(cpu.a)
    else:
      let op = dataOp()
      let v = cpu.loadValue(bus, op, not cpu.m8) - 1
      cpu.storeValue(bus, op, v, not cpu.m8)
      if cpu.m8: cpu.setNZ8((v and 0xFF).uint8) else: cpu.setNZ16(v)
  of "INX":
    cpu.x = if cpu.x8: (cpu.x + 1) and 0xFF else: cpu.x + 1
    if cpu.x8: cpu.setNZ8((cpu.x and 0xFF).uint8) else: cpu.setNZ16(cpu.x)
  of "INY":
    cpu.y = if cpu.x8: (cpu.y + 1) and 0xFF else: cpu.y + 1
    if cpu.x8: cpu.setNZ8((cpu.y and 0xFF).uint8) else: cpu.setNZ16(cpu.y)
  of "DEX":
    cpu.x = if cpu.x8: (cpu.x - 1) and 0xFF else: cpu.x - 1
    if cpu.x8: cpu.setNZ8((cpu.x and 0xFF).uint8) else: cpu.setNZ16(cpu.x)
  of "DEY":
    cpu.y = if cpu.x8: (cpu.y - 1) and 0xFF else: cpu.y - 1
    if cpu.x8: cpu.setNZ8((cpu.y and 0xFF).uint8) else: cpu.setNZ16(cpu.y)

  # Shifts and rotates.
  of "ASL", "LSR", "ROL", "ROR":
    let isAcc = mode == amAccumulator
    var op: Operand
    var v: uint16
    if isAcc:
      v = if cpu.m8: cpu.a and 0xFF else: cpu.a
    else:
      op = dataOp()
      v = cpu.loadValue(bus, op, not cpu.m8)
    let carryIn = if cpu.getFlag(FlagC): 1'u16 else: 0'u16
    let msb = if cpu.m8: 0x80'u16 else: 0x8000'u16
    var r: uint16
    case info.mnemonic:
    of "ASL":
      cpu.setFlag(FlagC, (v and msb) != 0)
      r = v shl 1
    of "LSR":
      cpu.setFlag(FlagC, (v and 1) != 0)
      r = v shr 1
    of "ROL":
      cpu.setFlag(FlagC, (v and msb) != 0)
      r = (v shl 1) or carryIn
    else:  # ROR.
      cpu.setFlag(FlagC, (v and 1) != 0)
      r = (v shr 1) or (if carryIn != 0: msb else: 0)
    if cpu.m8:
      r = r and 0xFF
      cpu.setNZ8(r.uint8)
    else:
      cpu.setNZ16(r)
    if isAcc:
      cpu.a = if cpu.m8: (cpu.a and 0xFF00) or r else: r
    else:
      cpu.storeValue(bus, op, r, not cpu.m8)

  # Branches.
  of "BPL": cpu.branch(bus, not cpu.getFlag(FlagN))
  of "BMI": cpu.branch(bus, cpu.getFlag(FlagN))
  of "BVC": cpu.branch(bus, not cpu.getFlag(FlagV))
  of "BVS": cpu.branch(bus, cpu.getFlag(FlagV))
  of "BCC": cpu.branch(bus, not cpu.getFlag(FlagC))
  of "BCS": cpu.branch(bus, cpu.getFlag(FlagC))
  of "BNE": cpu.branch(bus, not cpu.getFlag(FlagZ))
  of "BEQ": cpu.branch(bus, cpu.getFlag(FlagZ))
  of "BRA": cpu.branch(bus, true)
  of "BRL":
    let disp = cast[int16](cpu.fetch16(bus))
    cpu.pc = (cpu.pc.int32 + disp.int32).uint16

  # Jumps and calls.
  of "JMP":
    case mode:
    of amAbsolute:
      cpu.pc = cpu.fetch16(bus)
    of amAbsIndirect:
      let target = cpu.fetch16(bus)
      cpu.pc = bus.read16Wrap(0, target)
    of amAbsIndirectX:
      let target = cpu.fetch16(bus) + cpu.x
      cpu.pc = bus.read16Wrap(cpu.pbr.uint32 shl 16, target)
    else:
      doAssert false
  of "JML":
    case mode:
    of amAbsoluteLong:
      let lo = cpu.fetch16(bus)
      let hi = cpu.fetch8(bus)
      cpu.pc = lo
      cpu.pbr = hi
    of amAbsIndirectLong:
      let target = cpu.fetch16(bus)
      cpu.pc = bus.read16Wrap(0, target)
      cpu.pbr = bus.read8(((target + 2) and 0xFFFF).uint32)
    else:
      doAssert false
  of "JSR":
    case mode:
    of amAbsolute:
      let target = cpu.fetch16(bus)
      cpu.push16(bus, cpu.pc - 1)
      cpu.pc = target
    of amAbsIndirectX:
      let base = cpu.fetch16(bus)
      cpu.push16(bus, cpu.pc - 1)
      cpu.pc = bus.read16Wrap(cpu.pbr.uint32 shl 16, base + cpu.x)
    else:
      doAssert false
  of "JSL":
    let lo = cpu.fetch16(bus)
    let hi = cpu.fetch8(bus)
    cpu.push8(bus, cpu.pbr, wrap = false)
    cpu.push16(bus, cpu.pc - 1, wrap = false)
    cpu.pc = lo
    cpu.pbr = hi
  of "RTS":
    cpu.pc = cpu.pull16(bus) + 1
  of "RTL":
    cpu.pc = cpu.pull16(bus, wrap = false) + 1
    cpu.pbr = cpu.pull8(bus, wrap = false)
  of "RTI":
    if cpu.emulation:
      cpu.p = cpu.pull8(bus) or FlagM or FlagX
      cpu.pc = cpu.pull16(bus)
    else:
      cpu.p = cpu.pull8(bus)
      cpu.pc = cpu.pull16(bus)
      cpu.pbr = cpu.pull8(bus)
    cpu.forceWidthInvariants()

  # Stack operations.
  of "PHA":
    if cpu.m8: cpu.push8(bus, (cpu.a and 0xFF).uint8)
    else: cpu.push16(bus, cpu.a)
  of "PLA":
    if cpu.m8:
      let v = cpu.pull8(bus)
      cpu.a = (cpu.a and 0xFF00) or v.uint16
      cpu.setNZ8(v)
    else:
      cpu.a = cpu.pull16(bus)
      cpu.setNZ16(cpu.a)
  of "PHX":
    if cpu.x8: cpu.push8(bus, (cpu.x and 0xFF).uint8)
    else: cpu.push16(bus, cpu.x)
  of "PLX":
    if cpu.x8:
      cpu.x = cpu.pull8(bus).uint16
      cpu.setNZ8((cpu.x and 0xFF).uint8)
    else:
      cpu.x = cpu.pull16(bus)
      cpu.setNZ16(cpu.x)
  of "PHY":
    if cpu.x8: cpu.push8(bus, (cpu.y and 0xFF).uint8)
    else: cpu.push16(bus, cpu.y)
  of "PLY":
    if cpu.x8:
      cpu.y = cpu.pull8(bus).uint16
      cpu.setNZ8((cpu.y and 0xFF).uint8)
    else:
      cpu.y = cpu.pull16(bus)
      cpu.setNZ16(cpu.y)
  of "PHP":
    if cpu.emulation:
      cpu.push8(bus, cpu.p or 0x30)
    else:
      cpu.push8(bus, cpu.p)
  of "PLP":
    cpu.p = cpu.pull8(bus)
    cpu.forceWidthInvariants()
  of "PHB": cpu.push8(bus, cpu.dbr, wrap = false)
  of "PLB":
    cpu.dbr = cpu.pull8(bus, wrap = false)
    cpu.setNZ8(cpu.dbr)
  of "PHD": cpu.push16(bus, cpu.d, wrap = false)
  of "PLD":
    cpu.d = cpu.pull16(bus, wrap = false)
    cpu.setNZ16(cpu.d)
  of "PHK": cpu.push8(bus, cpu.pbr)
  of "PEA":
    cpu.push16(bus, cpu.fetch16(bus), wrap = false)
  of "PEI":
    let base = cpu.d + cpu.fetch8(bus).uint16
    cpu.push16(bus, bus.read16Wrap(0, base), wrap = false)
  of "PER":
    let disp = cast[int16](cpu.fetch16(bus))
    cpu.push16(bus, (cpu.pc.int32 + disp.int32).uint16, wrap = false)

  # Block moves. The hardware refetches the 3-byte instruction for every
  # byte moved (7 cycles per byte); the SingleStepTests vectors execute a
  # 100-cycle budget and snapshot mid-move, so we model the same budget.
  of "MVN", "MVP":
    let startPc = cpu.pc - 1
    let dstBank = cpu.fetch8(bus)
    let srcBank = cpu.fetch8(bus)
    cpu.dbr = dstBank
    let budget = if cpu.mvnBudget > 0: cpu.mvnBudget else: high(int) - 7
    var cycles = 0
    var finished = false
    while cycles + 7 <= budget:
      let srcAddr = (srcBank.uint32 shl 16) or cpu.x.uint32
      let dstAddr = (dstBank.uint32 shl 16) or cpu.y.uint32
      bus.write8(dstAddr, bus.read8(srcAddr))
      if info.mnemonic == "MVN":
        cpu.x = if cpu.x8: (cpu.x + 1) and 0xFF else: cpu.x + 1
        cpu.y = if cpu.x8: (cpu.y + 1) and 0xFF else: cpu.y + 1
      else:
        cpu.x = if cpu.x8: (cpu.x - 1) and 0xFF else: cpu.x - 1
        cpu.y = if cpu.x8: (cpu.y - 1) and 0xFF else: cpu.y - 1
      cpu.a = cpu.a - 1
      cycles += 7
      if cpu.a == 0xFFFF:
        finished = true
        break
    if not finished:
      # Snapshot mid-move: PC sits partway through the next refetch.
      let leftover = budget - cycles
      cpu.pc = startPc + min(leftover, 3).uint16

  # Interrupts and misc.
  of "BRK":
    discard cpu.fetch8(bus)
    cpu.interrupt(bus, 0xFFE6, 0xFFFE)
  of "COP":
    discard cpu.fetch8(bus)
    cpu.interrupt(bus, 0xFFE4, 0xFFF4)
  of "WDM":
    discard cpu.fetch8(bus)
  of "NOP":
    discard
  of "WAI":
    cpu.waiting = true
  of "STP":
    cpu.stopped = true

  else:
    doAssert false, "unhandled mnemonic: " & info.mnemonic

  # Emulation invariants also hold at instruction end (S snaps back to
  # page 1 after the non-wrapping stack instructions).
  cpu.forceWidthInvariants()
