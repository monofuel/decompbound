import
  decompbound/[asm_parse, cpu, snesbus]

const
  Wram* = 0x7E0000'u32
  Caller* = 0x1E00'u32
  StackTop* = 0x1FFF'u16
  DirectPage* = 0x0200'u16
  StepLimit = 30000

proc putWord*(snes: SnesBus, address, value: int) =
  ## Write a little-endian word in the synthetic WRAM setup.
  snes.bus.write8(Wram + address.uint32, (value and 255).uint8)
  snes.bus.write8(Wram + address.uint32 + 1, ((value shr 8) and 255).uint8)

proc word*(snes: SnesBus, address: int): int =
  ## Read a result word from WRAM.
  snes.bus.read16(Wram + address.uint32).int

proc putBytes*(snes: SnesBus, address: uint32, bytes: openArray[uint8]) =
  ## Install synthetic code or data without changing the cartridge image.
  for index, value in bytes:
    snes.bus.write8(address + index.uint32, value)

proc runUntil*(snes: SnesBus, state: var Cpu, bank: uint8, pc: uint16) =
  ## Execute the original instructions to a bounded return or fragment boundary.
  var steps = 0
  while state.pbr != bank or state.pc != pc:
    doAssert steps < StepLimit, "Engine routine did not reach its expected boundary"
    state.step(snes.bus)
    inc steps

proc call*(snes: SnesBus, instruction: string, a = 0, x = 0, y = 0,
    status = 0'u8, directPage = DirectPage): Cpu {.discardable.} =
  ## Invoke a native-width routine with isolated scratch and check its return context.
  let code = assembleAsm(".a16\n.i16\n" & instruction & "\n", Caller)
  snes.putBytes(Caller, code)
  result = Cpu(pc: Caller.uint16, s: StackTop, d: directPage, dbr: 0x7E,
    a: a.uint16, x: x.uint16, y: y.uint16, p: status)
  snes.runUntil(result, 0, (Caller + code.len.uint32).uint16)
  doAssert result.s == StackTop and result.d == directPage and result.dbr == 0x7E

proc fragment*(snes: SnesBus, first, last: uint16, status = 0'u8) =
  ## Run an interrupt fragment with its explicit entry contract, without claiming full NMI timing.
  var state = Cpu(pbr: 0xC0, pc: first, s: StackTop, p: status)
  snes.runUntil(state, 0xC0, last)
  doAssert state.s == StackTop
