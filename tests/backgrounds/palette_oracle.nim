## Compare original battle palette cycling with synthetic color indices.
## Invoked by tests/integration_battle_bg.nim with the user's ROM.

import
  std/[strformat],
  pixie,
  ../../src/decompbound/[asm_parse, battle_bg, cpu, snesbus]

const
  Caller = 0x0200'u32
  ReturnPc = 0x0204'u16
  Wram = 0x7e0000'u32
  ObjectAddr = 0x3000'u32
  OutputAddr = 0x4000'u32
  StackTop = 0x1fff'u16
  DirectPage = 0x1a00'u16
  MaxSteps = 20000
  ScrollTable = 0x0af258

proc put8(snes: SnesBus, address: uint32, value: int) =
  ## Write a synthetic byte through the bus.
  snes.bus.write8(Wram + address, uint8(value and 0xff))

proc put16(snes: SnesBus, address: uint32, value: int) =
  ## Write a synthetic little-endian word through the bus.
  snes.put8(address, value)
  snes.put8(address + 1, value shr 8)

proc read16(snes: SnesBus, address: uint32): int =
  ## Read a synthetic little-endian word through the bus.
  snes.bus.read16(Wram + address).int

proc stepOriginal(snes: SnesBus) =
  ## Invoke the original background update with the synthetic layer object.
  let code = assembleAsm(".a16\n.i16\nJSL $C2C92D\n", Caller)
  for i, b in code: snes.bus.write8(Caller + i.uint32, b)
  var machine = Cpu(pc: Caller.uint16, s: StackTop, d: DirectPage,
    dbr: 0x7e'u8, a: ObjectAddr.uint16)
  var steps = 0
  while machine.pbr != 0 or machine.pc != ReturnPc:
    doAssert steps < MaxSteps, &"background step did not return at {machine.pbr:02X}:{machine.pc:04X}"
    machine.step(snes.bus)
    inc steps

proc expectedIndex(kind, i, step: int): int =
  ## Model two four-color ranges and the original phase-indexed copy.
  result = i
  if kind in [1, 2] and i in 1..4:
    result = 1 + ((i - 1 - step mod 4 + 4) mod 4)
  if kind == 2 and i in 6..9:
    result = 6 + ((i - 6 - step mod 4 + 4) mod 4)
  if kind == 3 and i in 1..4:
    let position = (i - 1 + step) mod 8
    result = 1 + (if position < 4: position else: 7 - position)

proc testCase(rom: seq[uint8], kind, speed: int) =
  ## Compare cycle frames and untouched entries against original CPU execution.
  let snes = newSnesBus(rom)
  snes.put8(ObjectAddr + 3, kind)
  snes.put8(ObjectAddr + 4, 1)
  snes.put8(ObjectAddr + 5, 4)
  snes.put8(ObjectAddr + 6, 6)
  snes.put8(ObjectAddr + 7, 9)
  snes.put8(ObjectAddr + 10, speed)
  snes.put8(ObjectAddr + 11, 1)
  snes.put16(ObjectAddr + 0x4c, OutputAddr.int)
  snes.put16(0xa97a, 0xffff)
  for i in 0 ..< 16:
    snes.put16(ObjectAddr + 12 + (i * 2).uint32, i)
    snes.put16(OutputAddr + (i * 2).uint32, i)
  var layer = BattleBgLayer(palCycleType: kind, palCycleSpeed: speed,
    cycle1Start: 1, cycle1End: 4, cycle2Start: 6, cycle2End: 9,
    palette: newSeq[ColorRGBA](16))
  for i in 0 ..< 16: layer.palette[i] = rgba(i.uint8, 0, 0, 255)
  for frame in 1..22:
    snes.stepOriginal()
    let phase = if speed == 0: 0 else: (frame - 1) div speed
    let rendered = cycledPalette(layer, frame)
    for i in 0 ..< 16:
      let got = snes.read16(OutputAddr + (i * 2).uint32)
      let want = expectedIndex(kind, i, phase)
      doAssert rendered[i].r.int == got
      doAssert got == want, &"kind={kind} speed={speed} frame={frame} index={i}: {got} != {want}"

proc testScroll(rom: seq[uint8]) =
  ## Exercise real scroll records through original CPU duration transitions.
  let
    snes = newSnesBus(rom)
    slots = [1, 2, 0, 0]
  var
    slot = 0
    remaining = 1
    x, y, vx, vy, ax, ay = 0
  for i, id in slots: snes.put8(ObjectAddr + 0x4e + i.uint32, id)
  snes.put16(ObjectAddr + 0x53, remaining)
  snes.put16(0xa97a, 0)
  var segments: seq[ScrollSegment]
  for id in [2, 1]:
    let off = ScrollTable + id * 10
    template word(delta: int): int = rom[off + delta].int or (rom[off + delta + 1].int shl 8)
    template signedWord(delta: int): int = cast[int16](word(delta).uint16).int
    segments.add ScrollSegment(duration: word(0), hVel: signedWord(2),
      vVel: signedWord(4), hAccel: signedWord(6), vAccel: signedWord(8))
  for frame in 1..200:
    if remaining > 0:
      dec remaining
      if remaining == 0:
        slot = (slot + 1) mod 4
        var id = slots[slot]
        if id == 0:
          slot = 0
          id = slots[0]
        if id != 0:
          let off = ScrollTable + id * 10
          template word(delta: int): int = rom[off + delta].int or (rom[off + delta + 1].int shl 8)
          remaining = word(0)
          vx = word(2)
          vy = word(4)
          ax = word(6)
          ay = word(8)
    vx = (vx + ax) and 0xffff
    vy = (vy + ay) and 0xffff
    x = (x + vx) and 0xffff
    y = (y + vy) and 0xffff
    snes.stepOriginal()
    doAssert scrollOffsetAt(segments, frame) == (x shr 8, y shr 8)
    for (off, expected) in [(0x52, slot), (0x53, remaining), (0x55, x),
        (0x57, y), (0x59, vx), (0x5b, vy)]:
      let got = if off == 0x52: snes.bus.read8(Wram + ObjectAddr + off.uint32).int
        else: snes.read16(ObjectAddr + off.uint32)
      doAssert got == expected, &"scroll frame={frame} offset={off:02X}: {got} != {expected}"

proc verifyPalette*(rom: seq[uint8]) =
  ## Compare production palette output and the independent model with the original CPU.
  for kind in 1..3:
    for speed in [0, 1, 3]: testCase(rom, kind, speed)
  testScroll(rom)
