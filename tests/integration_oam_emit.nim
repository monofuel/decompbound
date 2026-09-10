import
  decompbound/[asm_parse, cpu, rom_pipeline, snesbus]

const
  Caller = 0x0200'u32
  ReturnPc = 0x0204'u16
  StackTop = 0x1FFF'u16
  Script = 0x3000'u32
  Wram = 0x7E0000'u32
  Output = 0x0500'u32
  HighTable = 0x0700'u32
  Sentinel = 0x5A'u8
  Tile = 0x37'u8
  Attributes = 0xA9'u8
  FinalElement = 0x80'u8
  Origins = [0, 1, 31, 32, 127, 223, 224, 255, 256, 511, 512, 65535]
  StepLimit = 400

proc putWord(snes: SnesBus, address: uint32, value: int) =
  ## Write a synthetic little-endian word.
  snes.bus.write8(address, (value and 255).uint8)
  snes.bus.write8(address + 1, ((value shr 8) and 255).uint8)

proc signedByte(value: int): int =
  ## Interpret a synthetic displacement as a signed byte.
  if value < 128: value else: value - 256

proc prepare(snes: SnesBus, capacity: int) =
  ## Install empty output tables and the emitter's direct-page pointers.
  for offset in 0 ..< 32:
    snes.bus.write8(Output + offset.uint32, Sentinel)
    snes.bus.write8(HighTable + offset.uint32, Sentinel)
  putWord(snes, 3, Output.int)
  putWord(snes, 5, Output.int + capacity * 4)
  putWord(snes, 7, HighTable.int)
  snes.bus.write8(9, 0x7E)
  snes.bus.write8(10, 0x80)
  snes.bus.write8(11, 0x7E)

proc element(snes: SnesBus, offset: int, dx, dy: int, flags: uint8) =
  ## Write a synthetic five-byte sprite element in WRAM.
  let address = Wram + Script + offset.uint32
  snes.bus.write8(address, dy.uint8)
  snes.bus.write8(address + 1, Tile)
  snes.bus.write8(address + 2, Attributes)
  snes.bus.write8(address + 3, dx.uint8)
  snes.bus.write8(address + 4, flags)

proc execute(snes: SnesBus, x, y: int, status = 0'u8) =
  ## Execute the original ROM emitter with a synthetic JSL caller.
  var
    cpu = Cpu(pc: Caller.uint16, s: StackTop, dbr: 0x7F,
      d: 0x1234, a: Script.uint16, x: x.uint16, y: y.uint16, p: status)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != ReturnPc:
    doAssert steps < StepLimit, "Emitter did not return"
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.s == StackTop and cpu.d == 0x1234 and cpu.dbr == 0x7F
  doAssert cpu.p == status

proc checkSingle(snes: SnesBus, x, y, dx, dy, size: int) =
  ## Check clipping, partial writes, and pending packed bits independently.
  snes.prepare(4)
  snes.element(0, dx, dy, FinalElement or size.uint8)
  snes.execute(x, y)
  let
    screenX = (x + signedByte(dx)) and 65535
    screenY = (y + signedByte(dy) - 1) and 65535
    visibleY = screenY < 224 or screenY >= 65504
    visibleX = screenX < 256 or screenX >= 65280
    emitted = visibleY and visibleX
  doAssert snes.bus.read16(3) == Output.uint16 + (if emitted: 4'u16 else: 0'u16)
  doAssert snes.bus.read8(Output) == (if visibleY: (screenX and 255).uint8 else: Sentinel)
  doAssert snes.bus.read8(Output + 1) == (if emitted: (screenY and 255).uint8 else: Sentinel)
  doAssert snes.bus.read8(Output + 2) == (if visibleY: Tile else: Sentinel)
  doAssert snes.bus.read8(Output + 3) == (if visibleY: Attributes else: Sentinel)
  let packed = if emitted: 0x20 or ((screenX shr 8 and 1) shl 6) or (size shl 7) else: 0x80
  doAssert snes.bus.read8(10) == packed.uint8
  doAssert snes.bus.read16(7) == HighTable.uint16
  for offset in 0 ..< 32:
    doAssert snes.bus.read8(HighTable + offset.uint32) == Sentinel
  for offset in 4 ..< 32:
    doAssert snes.bus.read8(Output + offset.uint32) == Sentinel

proc checkPackedGroup(snes: SnesBus) =
  ## Verify four distinct X/size pairs flush in sprite order, with capacity exit.
  snes.prepare(4)
  for i in 0 ..< 5:
    snes.element(i * 5, (if (i and 1) == 0: 0 else: 255), 1,
      (i shr 1 and 1).uint8)
  snes.execute(0, 0, FlagC or FlagV)
  doAssert snes.bus.read8(HighTable) == 0xE4
  doAssert snes.bus.read16(7) == HighTable.uint16 + 1
  doAssert snes.bus.read8(10) == 0x80
  doAssert snes.bus.read16(3) == Output.uint16 + 16
  for i in 0 ..< 4:
    doAssert snes.bus.read8(Output + (i * 4 + 1).uint32) == 0
  doAssert snes.bus.read8(Output + 16) == Sentinel

proc checkRedirectAndEmpty(snes: SnesBus) =
  ## Check same-bank redirection and an initially exhausted output buffer.
  snes.prepare(4)
  snes.bus.write8(Wram + Script, 0x80)
  snes.putWord(Wram + Script + 1, Script.int + 16)
  snes.element(16, 0, 1, FinalElement)
  snes.execute(0, 0)
  doAssert snes.bus.read16(3) == Output.uint16 + 4
  doAssert snes.bus.read8(Output + 1) == 0
  snes.prepare(0)
  snes.execute(0, 0)
  doAssert snes.bus.read16(3) == Output.uint16
  doAssert snes.bus.read8(10) == 0x80
  for offset in 0 ..< 32:
    doAssert snes.bus.read8(Output + offset.uint32) == Sentinel

proc checkRejectedPrefix(snes: SnesBus) =
  ## Skip Y- and X-rejected records before emitting into the same output slot.
  snes.prepare(4)
  snes.element(0, 0, 1, 0)
  snes.element(5, 0, 255, 0)
  snes.element(10, 255, 255, 0xFE)
  snes.execute(256, 224)
  doAssert snes.bus.read16(3) == Output.uint16 + 4
  doAssert snes.bus.read8(Output) == 255
  doAssert snes.bus.read8(Output + 1) == 222
  doAssert snes.bus.read8(10) == 0x20
  doAssert snes.bus.read8(Output + 4) == Sentinel

proc main() =
  ## Sweep signed offsets and boundary origins against original ROM execution.
  let
    snes = newSnesBus(readGoldBaserom())
    caller = assembleAsm(".a16\n.i16\nJSL $C08CD5\n", Caller)
  for i, value in caller:
    snes.bus.write8(Caller + i.uint32, value)
  for origin in Origins:
    for displacement in 0 .. 255:
      for size in 0 .. 1:
        snes.checkSingle(origin, 1, displacement, 0, size)
        if displacement != 128:
          snes.checkSingle(0, origin, 0, displacement, size)
  snes.checkPackedGroup()
  snes.checkRedirectAndEmpty()
  snes.checkRejectedPrefix()

when isMainModule:
  main()
