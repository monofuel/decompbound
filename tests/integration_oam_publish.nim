import
  decompbound/[asm_parse, cpu, rom_pipeline, snesbus]

const
  InitCaller = 0x0200'u32
  EnqueueCaller = 0x0210'u32
  PublishCaller = 0x0220'u32
  StackTop = 0x1FFF'u16
  Wram = 0x7E0000'u32
  Definitions = 0x3000
  QueueBases = [0x2404, 0x2506, 0x2608, 0x270A]
  Sentinel = 0x5A'u8
  Attributes = 0xA9'u8
  StepLimit = 16000

proc putWord(snes: SnesBus, address, value: int) =
  ## Install a synthetic WRAM word.
  snes.bus.write8(Wram + address.uint32, (value and 255).uint8)
  snes.bus.write8(Wram + address.uint32 + 1, ((value shr 8) and 255).uint8)

proc word(snes: SnesBus, address: int): int =
  ## Read a WRAM word without changing the emulated program.
  snes.bus.read16(Wram + address.uint32).int

proc run(snes: SnesBus, caller: uint32, a = 0, x = 0, y = 0) =
  ## Execute an original ROM routine through a synthetic long-call trampoline.
  var
    cpu = Cpu(pc: caller.uint16, s: StackTop, dbr: 0x7E,
      a: a.uint16, x: x.uint16, y: y.uint16)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != (caller + 4).uint16:
    doAssert steps < StepLimit, "OAM pipeline failed to return"
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.s == StackTop and cpu.d == 0 and cpu.dbr == 0x7E
  doAssert (cpu.p and (FlagM or FlagX)) == 0

proc checkFrame(snes: SnesBus, selector, count: int) =
  ## Verify original initialization, interleaved enqueue, drain, and publication.
  let
    low = if selector == 1: 0x500 else: 0x800
    high = low + 0x200
    other = if selector == 1: 0x800 else: 0x500
  for address in 0x500 ..< 0xB00:
    snes.bus.write8(Wram + address.uint32, Sentinel)
  for address in 0x41 ..< 0x61:
    snes.bus.write8(Wram + address.uint32, Sentinel)
  for i in 0 ..< 8:
    snes.putWord(0x31 + i * 2, 0xB000 + i)
  snes.putWord(0x2E, selector)
  snes.putWord(0x2C, 0xA500)
  snes.putWord(0x2402, count mod 5)
  snes.run(InitCaller)
  snes.bus.write8(Wram + 9, (if selector == 1: 0'u8 else: 0x7E'u8))
  var expected: seq[int]
  for i in 0 ..< count:
    let address = Wram + (Definitions + i * 5).uint32
    snes.bus.write8(address, 0)
    snes.bus.write8(address + 1, i.uint8)
    snes.bus.write8(address + 2, Attributes)
    snes.bus.write8(address + 3, (if (i and 1) == 0: 0'u8 else: 255'u8))
    snes.bus.write8(address + 4, (0x80 or ((i shr 1) and 1)).uint8)
    snes.putWord(0x2400, 3 - i mod 4)
    snes.putWord(0x0B, 0xA57E)
    snes.run(EnqueueCaller, Definitions + i * 5, 0, i + 1)
  for group in 0 ..< 4:
    var slot = 0
    for i in 0 ..< count:
      if 3 - i mod 4 == group:
        expected.add i
        let base = QueueBases[group] + slot * 2
        doAssert snes.word(base) == Definitions + i * 5
        doAssert snes.word(base + 0x40) == 0
        doAssert snes.word(base + 0x80) == i + 1
        doAssert snes.word(base + 0xC0) == 0xA57E
        inc slot
    doAssert snes.word(QueueBases[group] + 0x100) == slot * 2
  snes.run(PublishCaller)
  for slot in 0 ..< 128:
    let address = Wram + (low + slot * 4).uint32
    if slot < count:
      let i = expected[slot]
      doAssert snes.bus.read8(address) == (if (i and 1) == 0: 0'u8 else: 255'u8)
      doAssert snes.bus.read8(address + 1) == i.uint8
      doAssert snes.bus.read8(address + 2) == i.uint8
      doAssert snes.bus.read8(address + 3) == Attributes
    else:
      doAssert snes.bus.read8(address) == Sentinel
      doAssert snes.bus.read8(address + 1) == 0xE0
      doAssert snes.bus.read8(address + 2) == Sentinel
      doAssert snes.bus.read8(address + 3) == Sentinel
  for byteIndex in 0 .. 32:
    var packed = 0
    for bitPair in 0 ..< 4:
      let slot = byteIndex * 4 + bitPair
      if slot < count:
        packed = packed or ((expected[slot] and 3) shl (bitPair * 2))
    let value =
      if byteIndex < count div 4: packed.uint8
      elif byteIndex == count div 4:
        if count mod 4 == 0: 0x80'u8 else: packed.uint8
      else: Sentinel
    doAssert snes.bus.read8(Wram + (high + byteIndex).uint32) == value
  doAssert snes.word(3) == low + count * 4
  doAssert snes.word(7) == high + count div 4
  let remainder = count mod 4
  var pending = 0x80 shr (remainder * 2)
  for i in 0 ..< remainder:
    pending = pending or ((expected[count - remainder + i] and 3) shl
      (8 - remainder * 2 + i * 2))
  doAssert snes.bus.read8(Wram + 10) == pending.uint8
  doAssert snes.word(0x2C) == 0xA500 + selector
  doAssert snes.word(0x2E) == (selector xor 3)
  for i in 0 ..< 8:
    doAssert snes.word(0x41 + i * 4 + (selector - 1) * 2) == 0xB000 + i
    doAssert snes.word(0x41 + i * 4 + (2 - selector) * 2) == 0x5A5A
  for address in other ..< other + 0x221:
    doAssert snes.bus.read8(Wram + address.uint32) == Sentinel
  for group in 0 ..< 4:
    var members = 0
    for i in 0 ..< count:
      if 3 - i mod 4 == group:
        inc members
    doAssert snes.word(QueueBases[group] + 0x100) == members * 2

proc main() =
  ## Sweep every legal total occupancy in both OAM buffers using original code.
  let snes = newSnesBus(readGoldBaserom())
  for entry in [(InitCaller, "C088B1"), (EnqueueCaller, "C08C54"),
      (PublishCaller, "C08B26")]:
    let code = assembleAsm(".a16\n.i16\nJSL $" & entry[1] & "\n", entry[0])
    for i, value in code:
      snes.bus.write8(entry[0] + i.uint32, value)
  for selector in 1 .. 2:
    for count in 0 .. 128:
      snes.checkFrame(selector, count)

when isMainModule:
  main()
