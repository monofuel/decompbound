import
  ./[asm_parse, cpu, memmap, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  DirectPage = 0x1000'u16
  DefinitionOffset = 0x100
  DefinitionAddress = 0x477E
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

proc call(snes: SnesBus, instruction: string, a = 0) =
  ## Invoke an original routine through an isolated WRAM trampoline.
  let code = assembleAsm(".a16\n.i16\n" & instruction & "\n", Caller)
  for index, value in code:
    snes.bus.write8(Caller + index.uint32, value)
  var cpu = Cpu(pc: Caller.uint16, s: 0x1FFF, d: DirectPage, dbr: 0x7E, a: a.uint16)
  snes.runUntil(cpu, 0, (Caller + code.len.uint32).uint16)

proc buildSpritePreview*(gold: seq[uint8], resourceId, direction, phase: int): SnesBus =
  ## Build an isolated normal sprite using original routines and the baseline palette.
  if resourceId notin 0 ..< ResourceCount or direction notin 0 .. 7 or phase notin 0 .. 1:
    raise newException(ValueError, "Expected resource 0..463, direction 0..7, phase 0..1")
  let
    resourcePointer = 0x2F133F + resourceId * 4
    resourceAddress = gold[resourcePointer].uint32 or
      (gold[resourcePointer + 1].uint32 shl 8) or (gold[resourcePointer + 2].uint32 shl 16)
    resource = snesToFile(resourceAddress)
    layoutPointer = 0x042B0D + gold[resource + 2].int * 4
    layoutAddress = gold[layoutPointer].uint32 or
      (gold[layoutPointer + 1].uint32 shl 8) or (gold[layoutPointer + 2].uint32 shl 16)
    layout = snesToFile(layoutAddress)
    count = gold[layout].int
    firstGroup = gold[layout + 1].int
    chunks = gold[resource].int
  result = newSnesBus(gold)
  result.bus.write8(Wram + 0x0D, 0x80)
  result.putWord(0x102B, resourceId)
  result.putWord(0x1004, 1)
  var allocation = Cpu(pbr: 0xC0, pc: 0x1EA0, s: 0x1FFF, d: DirectPage, dbr: 0x7E)
  result.runUntil(allocation, 0xC0, 0x1EB3)
  if allocation.a >= 88:
    raise newException(ValueError, "Sprite preview allocation failed")
  let slot = allocation.a.int
  result.putWord(0x100E, (layoutAddress and 0xFFFF).int)
  result.putWord(0x1010, (layoutAddress shr 16).int)
  result.putWord(0x1FFE, Caller.int - 1)
  var builder = Cpu(pbr: 0xC0, pc: 0x1D38, s: 0x1FFD, d: DirectPage,
    dbr: 0x7E, a: DefinitionOffset, x: slot.uint16, y: gold[resource + 3].uint16)
  result.runUntil(builder, 0xC0, Caller.uint16)
  let tileMapping = 0x042F8C + slot * 2
  result.putWord(0x298E, 0x4000 + gold[tileMapping].int +
    (gold[tileMapping + 1].int shl 8) + (if chunks mod 2 != 0: 0x100 else: 0))
  result.putWord(0x2ABA, chunks)
  result.putWord(0x2A7E, gold[resource + 1].int * 2)
  result.putWord(0x29CA, ((resourceAddress + 9) and 0xFFFF).int)
  result.putWord(0x2A06, (resourceAddress shr 16).int)
  result.putWord(0x2A42, gold[resource + 8].int)
  result.putWord(0x2AF6, direction)
  result.putWord(0x2892, phase)
  result.call("JSL $C0A4C4")
  var palette = Cpu(pbr: 0xC0, pc: 0xB55B, s: 0x1FFF, d: DirectPage, dbr: 0x7E)
  result.runUntil(palette, 0xC0, 0xB56F)
  result.call("JSL $C0856B", 16)
  result.putWord(0x2E, 1)
  result.call("JSL $C088B1")
  result.putWord(0x1088, 0)
  result.putWord(0x108C, DefinitionAddress)
  result.putWord(0x108E, 0x7E)
  result.putWord(0x2916, count * 5)
  result.putWord(0x2BE6, (firstGroup shl 8) or (count - firstGroup))
  result.putWord(0x0B16, 128)
  result.putWord(0x0B52, 112)
  result.call("JSR $A3A4")
  result.call("JSL $C08B26")
  var interrupt = Cpu(pbr: 0xC0, pc: 0x8196, s: 0x1FFF, p: FlagX)
  result.runUntil(interrupt, 0xC0, 0x81F7)
  result.call("JSL $C08D92", 0x62)
  result.bus.write8(0x2100, 0x0F)
  result.bus.write8(0x212C, 0x10)
