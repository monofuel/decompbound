import
  decompbound/[asm_parse, cpu, rom_pipeline, snesbus]

const
  InitCaller = 0x1E00'u32
  CallbackCaller = 0x1E10'u32
  PublishCaller = 0x1E20'u32
  Wram = 0x7E0000'u32
  DefinitionBank = 0x7F0000'u32
  DefinitionBase = 0x5000
  AlternateOffset = 0x100
  DirectPage = 0x0200'u16
  Counts = [(0, 1), (1, 0), (1, 1), (2, 3), (3, 2), (4, 4)]
  StepLimit = 2000

proc putWord(snes: SnesBus, address: uint32, value: int) =
  ## Write a synthetic word without coupling to emulated instructions.
  snes.bus.write8(address, (value and 255).uint8)
  snes.bus.write8(address + 1, ((value shr 8) and 255).uint8)

proc run(snes: SnesBus, caller: uint32, length: int) =
  ## Execute original code with a separate entity scratch direct page.
  var
    cpu = Cpu(pc: caller.uint16, s: 0x1FFF, dbr: 0x7E, d: DirectPage)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != (caller + length.uint32).uint16:
    doAssert steps < StepLimit
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.s == 0x1FFF and cpu.d == DirectPage and cpu.dbr == 0x7E

proc checkPriority(snes: SnesBus, first, second, flags, attribute, alternate: int) =
  ## Verify priority patching and emitted attributes while overlays are inactive.
  let
    pointer = DefinitionBase + alternate * AlternateOffset
    total = first + second
    group = attribute mod 4
  snes.putWord(Wram + 0x2E, 1)
  snes.run(InitCaller, 4)
  snes.putWord(Wram + DirectPage.uint32 + 0x88, 0)
  snes.putWord(Wram + DirectPage.uint32 + 0x8C, DefinitionBase)
  snes.bus.write8(Wram + DirectPage.uint32 + 0x8E, 0x7F)
  snes.putWord(Wram + 0x341A, alternate)
  snes.putWord(Wram + 0x2916, AlternateOffset)
  snes.putWord(Wram + 0x2BAA, flags)
  snes.putWord(Wram + 0x2BE6, second or (first shl 8))
  snes.putWord(Wram + 0x103E, group)
  snes.putWord(Wram + 0x0B16, 32)
  snes.putWord(Wram + 0x0B52, 64)
  snes.putWord(Wram + 0x2E7A, 0)
  for offset in 0 ..< 0x200:
    snes.bus.write8(DefinitionBank + (DefinitionBase + offset).uint32, 0x5A)
  for i in 0 ..< total:
    let address = DefinitionBank + (pointer + i * 5).uint32
    snes.bus.write8(address, 0)
    snes.bus.write8(address + 1, i.uint8)
    snes.bus.write8(address + 2, attribute.uint8)
    snes.bus.write8(address + 3, i.uint8)
    snes.bus.write8(address + 4, (if i == total - 1: 0x81'u8 else: 1'u8))
  let before = block:
    var snapshot: array[512, uint8]
    for i in 0 ..< snapshot.len:
      snapshot[i] = snes.bus.read8(DefinitionBank + (DefinitionBase + i).uint32)
    snapshot
  snes.run(CallbackCaller, 3)
  for offset in 0 ..< before.len:
    let relative = offset - alternate * AlternateOffset
    var expected = before[offset]
    if relative >= 0 and relative < total * 5 and relative mod 5 == 2:
      let
        groupBit = if relative div 5 < first: 2 else: 1
        priority = if (flags and groupBit) != 0: 0x20 else: 0x30
      expected = ((attribute and 0xCF) or priority).uint8
    doAssert snes.bus.read8(DefinitionBank + (DefinitionBase + offset).uint32) == expected
  doAssert snes.bus.read16(Wram + DirectPage.uint32 + 0x8C) == pointer.uint16
  snes.run(PublishCaller, 4)
  for i in 0 ..< total:
    let
      groupBit = if i < first: 2 else: 1
      priority = if (flags and groupBit) != 0: 0x20 else: 0x30
      address = Wram + (0x500 + i * 4).uint32
    doAssert snes.bus.read8(address) == (32 + i).uint8
    doAssert snes.bus.read8(address + 1) == 63
    doAssert snes.bus.read8(address + 2) == i.uint8
    doAssert snes.bus.read8(address + 3) == ((attribute and 0xCF) or priority).uint8
  doAssert snes.bus.read16(Wram + 3) == (0x500 + total * 4).uint16

proc main() =
  ## Sweep every attribute byte and priority selector across two record groups.
  let snes = newSnesBus(readGoldBaserom())
  for entry in [(InitCaller, "JSL $C088B1"),
      (CallbackCaller, "JSR $A3A4"), (PublishCaller, "JSL $C08B26")]:
    let code = assembleAsm(".a16\n.i16\n" & entry[1] & "\n", entry[0])
    for i, value in code:
      snes.bus.write8(entry[0] + i.uint32, value)
  for counts in Counts:
    for flags in 0 ..< 4:
      for attribute in 0 ..< 256:
        for alternate in 0 .. 1:
          snes.checkPriority(counts[0], counts[1], flags, attribute, alternate)

when isMainModule:
  main()
