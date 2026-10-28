## Original distortion HDMA routines checked against synthetic scanline formulas.
## Invoked by tests/integration_battle_bg.nim with the user's ROM.

import
  std/[strformat],
  ../../src/decompbound/[asm_parse, battle_bg, cpu, snesbus]

const
  Caller = 0x0200'u32
  ReturnPc = 0x0204'u16
  Wram = 0x7e0000'u32
  Buffer = 0x3c46'u32
  ObjectAddr = 0x3000'u32
  StackTop = 0x1fff'u16
  DirectPage = 0x1a00'u16
  MaxSteps = 30000
  Lines = 224
  Sine = 0xb425

proc put16(snes: SnesBus, address: uint32, value: int) =
  ## Set a WRAM word.
  snes.bus.write8(Wram + address, uint8(value and 0xff))
  snes.bus.write8(Wram + address + 1, uint8((value shr 8) and 0xff))

proc runEngine(snes: SnesBus, kind, freq, amp, angle, comp, scrollX, scrollY: int) =
  ## Execute the original HDMA generator with BG1 scroll enabled.
  snes.put16(0x1acc, kind)
  snes.put16(0x1ace, 1)
  snes.put16(0x1ad2, 0)
  snes.put16(0x1ad4, comp)
  snes.put16(0x31, scrollX)
  snes.put16(0x33, scrollY)
  let code = assembleAsm(".a16\n.i16\nJSL $C0AE5A\n", Caller)
  for i, b in code: snes.bus.write8(Caller + i.uint32, b)
  var machine = Cpu(pc: Caller.uint16, s: StackTop, d: DirectPage,
    dbr: 0x7e'u8, a: freq.uint16, x: amp.uint16, y: angle.uint16)
  var steps = 0
  while machine.pbr != 0 or machine.pc != ReturnPc:
    doAssert steps < MaxSteps
    machine.step(snes.bus)
    inc steps

proc runDriver(snes: SnesBus) =
  ## Execute the original per-frame background driver with a synthetic object.
  let code = assembleAsm(".a16\n.i16\nJSL $C2C92D\n", Caller)
  for i, b in code: snes.bus.write8(Caller + i.uint32, b)
  var machine = Cpu(pc: Caller.uint16, s: StackTop, d: DirectPage,
    dbr: 0x7e'u8, a: ObjectAddr.uint16, x: 0)
  var steps = 0
  while machine.pbr != 0 or machine.pc != ReturnPc:
    doAssert steps < MaxSteps
    machine.step(snes.bus)
    inc steps

proc read16(snes: SnesBus, address: uint32): int =
  ## Read one WRAM word.
  snes.bus.read16(Wram + address).int

proc driverTest(snes: SnesBus) =
  ## Verify per-frame additions, phase wrap, and acceleration before rendering.
  snes.put16(ObjectAddr, 1)
  snes.put16(ObjectAddr + 2, 1)
  snes.put16(ObjectAddr + 0x66, 0)
  snes.put16(ObjectAddr + 0x68, 1)
  snes.put16(ObjectAddr + 0x69, 0xfff0)
  snes.put16(ObjectAddr + 0x6b, 0xffe0)
  snes.put16(ObjectAddr + 0x6d, 0xf7)
  snes.put16(ObjectAddr + 0x6e, 0x0010)
  snes.put16(ObjectAddr + 0x70, 0x32)
  snes.put16(ObjectAddr + 0x72, 0x43)
  snes.put16(ObjectAddr + 0x74, 0x05)
  snes.put16(ObjectAddr + 0x75, 0xffd0)
  for frame in 1..10:
    snes.runDriver()
    for (off, expected) in [
        (0x69, (0xfff0 + frame * 0x32) and 0xffff),
        (0x6b, (0xffe0 + frame * 0x43) and 0xffff),
        (0x6e, (0x10 - frame * 0x30) and 0xffff)]:
      let got = snes.read16(ObjectAddr + off.uint32)
      doAssert got == expected, &"frame={frame} offset={off:02X} got={got:04X} expected={expected:04X}"
    let phase = snes.bus.read8(Wram + ObjectAddr + 0x6d).int
    doAssert phase == ((0xf7 + frame * 5) and 0xff)

proc oracle(rom: seq[uint8], kind, freq, amp, angle, comp, scrollX, scrollY: int): seq[int] =
  ## Generate absolute register words with 16-bit fixed-point wrapping.
  var phase = ((angle + (if kind < 2: scrollY else: 0)) and 0xff) shl 8
  var vertical = (scrollY and 0xff) shl 8
  for line in 0 ..< Lines:
    let sine = cast[int8](rom[Sine + ((phase shr 8) and 0xff)]).int
    let wave = (amp * sine) shr 8
    if kind >= 2: vertical = (vertical + comp) and 0xffff
    let base = if kind < 2: scrollX else: vertical shr 8
    let signedWave = if (kind and 1) != 0 and (line and 1) != 0: -wave else: wave
    result.add((base + signedWave) and 0xffff)
    phase = (phase + freq) and 0xffff

proc verifyDistortion*(rom: seq[uint8]) =
  ## Compare production scanline registers with original CPU output for all four kinds.
  let snes = newSnesBus(rom)
  var background: BattleBg
  for i in 0 ..< 256: background.sine[i] = cast[int8](rom[Sine + i]).int
  for kind in 0..3:
    for (freq, amp, angle, comp, x, y) in [
      (0x100, 0xff, 0x40, 0x100, 0x65, 0x7a),
      (0x345, 0x83, 0xf4, 0x1a1, 0x1f2, 0xd1),
      (0x80, 0x20, 0x10, 0xffc0, 0x20, 0x03)]:
      snes.runEngine(kind, freq, amp, angle, comp, x, y)
      let
        expected = oracle(rom, kind, freq, amp, angle, comp, x, y)
        rendered = distortionLines(background, @[DistortSegment(kind: kind + 1,
          frequency: freq, amplitude: amp shl 8, angle: angle, compression: comp)], 0, x, y, Lines)
      for line in 0 ..< Lines:
        let
          got = snes.bus.read16(Wram + Buffer + (line * 2).uint32).int
          actual = if kind < 2: rendered.dx[line] else: rendered.dy[line]
        doAssert actual == got, &"Production distortion kind={kind} line={line} actual={actual} original={got}"
        doAssert got == expected[line], &"kind={kind} line={line} got={got:04X} expected={expected[line]:04X}"
  snes.driverTest()
