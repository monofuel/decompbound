import
  ./[asm_parse, cpu, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  DirectPage = 0x0200'u16
  ResourceCount* = 464
  StepLimit = 20000

proc putWord(snes: SnesBus, address: uint32, value: int) =
  ## Write a preview's isolated WRAM field.
  snes.bus.write8(Wram + address, (value and 255).uint8)
  snes.bus.write8(Wram + address + 1, ((value shr 8) and 255).uint8)

proc runUntil(snes: SnesBus, cpu: var Cpu, bank: uint8, pc: uint16) =
  ## Execute original ROM code within the diagnostic's bounded entry contract.
  var steps = 0
  while cpu.pbr != bank or cpu.pc != pc:
    if steps >= StepLimit:
      raise newException(ValueError, "Sprite preview routine exceeded its instruction limit")
    cpu.step(snes.bus)
    inc steps

proc call(snes: SnesBus, instruction: string, a = 0, x = 0, y = 0): uint16 {.discardable.} =
  ## Invoke an original routine through an isolated WRAM trampoline.
  let code = assembleAsm(".a16\n.i16\n" & instruction & "\n", Caller)
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  var cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: DirectPage, dbr: 0x7E,
    a: a.uint16, x: x.uint16, y: y.uint16)
  snes.runUntil(cpu, 0, (Caller + code.len.uint32).uint16)
  cpu.a

proc buildSpritePreview*(gold: seq[uint8], resourceId, direction, phase: int): SnesBus =
  ## Build an isolated normal sprite using original routines and the baseline palette.
  if resourceId notin 0 ..< ResourceCount or direction notin 0 .. 7 or phase notin 0 .. 1:
    raise newException(ValueError, "Expected resource 0..463, direction 0..7, phase 0..1")
  result = newSnesBus(gold)
  result.call("JSL $C09282")
  result.call("JSL $C01A86")
  result.call("JSL $C01C11", 0x8000)
  result.bus.write8(Wram + 0x0D, 0x80)
  result.putWord(0x20E, 128)
  result.putWord(0x210, 112)
  let entity = result.call("JSL $C01E49", resourceId, 0, 0xFFFF)
  if entity != 0 or result.bus.read16(Wram + 0x0A50) != 0:
    raise newException(ValueError, "Fresh sprite preview did not allocate entity zero")
  result.putWord(0x2AF6, direction)
  result.putWord(0x2892, phase)
  result.call("JSL $C0A4C4")
  var palette = Cpu(pbr: 0xC0, pc: 0xB55B, s: 0x1FFF, d: 0x1000, dbr: 0x7E)
  result.runUntil(palette, 0xC0, 0xB56F)
  result.call("JSL $C0856B", 16)
  result.putWord(0x2E, 1)
  result.call("JSL $C088B1")
  result.putWord(0x288, 0)
  result.putWord(0x28C, result.bus.read16(Wram + 0x112E).int)
  result.putWord(0x28E, result.bus.read16(Wram + 0x116A).int)
  result.call("JSR $A3A4")
  result.call("JSL $C08B26")
  var interrupt = Cpu(pbr: 0xC0, pc: 0x8196, s: 0x1FFF, p: FlagX)
  result.runUntil(interrupt, 0xC0, 0x81F7)
  result.call("JSL $C08D92", 0x62)
  result.bus.write8(0x2100, 0x0F)
  result.bus.write8(0x212C, 0x10)
