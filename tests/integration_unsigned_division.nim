import
  std/strformat,
  decompbound/cpu,
  ./engine/rebuilt_rom

const
  Ram = 0x7E0000
  ReturnPc = 0x4000'u16
  DivisorEdges = [0, 1, 2, 3, 127, 128, 255, 256, 257,
    0x3FFF, 0x4000, 0x4001, 0x7FFF, 0x8000, 0x8001, 0xFFFE, 0xFFFF]
  DividendEdges = [0, 1, 2, 127, 128, 255, 256, 0x3FFF, 0x4000,
    0x4001, 0x7FFF, 0x8000, 0x8001, 0xFFFE, 0xFFFF]

proc putWord(bus: Bus, address, value: int) =
  ## Author a little-endian word without hardware side effects.
  bus.mem[address] = (value and 255).uint8
  bus.mem[address + 1] = ((value shr 8) and 255).uint8

proc word(bus: Bus, address: int): int =
  ## Read a resulting little-endian word without hardware side effects.
  bus.mem[address].int or (bus.mem[address + 1].int shl 8)

proc expectedStatus(dividend, divisor, quotient, remainder, status: int): int =
  ## Derive final arithmetic flags from division identities, not the instruction loop.
  result = status and not (FlagN or FlagZ).int
  if quotient == 0: result = result or FlagZ.int
  elif quotient >= 32768: result = result or FlagN.int
  if quotient != 0:
    # The last subtraction corresponds to the least significant set quotient
    # bit. Its resulting remainder is final remainder divided by that bit's weight.
    var weight = 1
    while (quotient and weight) == 0: weight = weight shl 1
    let
      difference = if divisor == 0: dividend else: remainder div weight
      before = difference + divisor
      overflow = ((before xor divisor) and (before xor difference) and 0x8000) != 0
    result = result and not FlagV.int
    if overflow: result = result or FlagV.int

proc check(bus: Bus, dividend, divisor, status, direct: int) =
  ## Execute the original native routine and compare exact outputs, flags, scratch and frame guards.
  let
    quotient = if divisor == 0: 65535 else: dividend div divisor
    remainder = if divisor == 0: dividend else: dividend mod divisor
    scratch = (quotient shr 1) or ((status and 1) shl 15)
  bus.putWord(0x1FFD, ReturnPc.int - 1)
  bus.mem[0x1FFF] = 0xC4
  bus.mem[0x1FFC] = 0xA7
  bus.mem[0x2000] = 0x5A
  bus.mem[Ram + 0xAF] = 0x62
  bus.mem[Ram + 0xB4] = 0x93
  bus.putWord(Ram + 0xB0, 0x1234)
  bus.putWord(Ram + 0xB2, 0x5678)
  var host = Cpu(a: dividend.uint16, y: divisor.uint16, x: 0xABCD,
    d: direct.uint16, dbr: 0x7E, pbr: 0xC0, pc: 0x915B,
    s: 0x1FFC, p: status.uint8)
  var steps = 0
  while host.pc != ReturnPc or host.pbr != 0xC4:
    doAssert steps < 150
    host.step(bus)
    inc steps
  doAssert host.a.int == quotient and host.y.int == remainder
  doAssert host.x == 0xABCD and host.d.int == direct and host.dbr == 0x7E
  doAssert host.s == 0x1FFF and bus.mem[0x1FFC] == 0xA7 and bus.mem[0x2000] == 0x5A
  doAssert bus.word(Ram + 0xB0) == scratch and bus.word(Ram + 0xB2) == divisor
  doAssert bus.mem[Ram + 0xAF] == 0x62 and bus.mem[Ram + 0xB4] == 0x93
  doAssert host.p.int == expectedStatus(dividend, divisor, quotient, remainder, status),
    &"flags n={dividend} d={divisor} p={status:02X}: actual{host.p:02X}"

proc checkLookupCaller(bus: Bus): int =
  ## Witness the real position lookup's LDY/TXA/JSL and native helper return without a stand-in.
  for dividend in DividendEdges:
    for carry in 0 .. 1:
      var host = Cpu(x: dividend.uint16, d: 0x1F00, dbr: 0x7E,
        pbr: 0xC0, pc: 0x6910, s: 0x1FFF, p: carry.uint8)
      host.step(bus)
      host.step(bus)
      host.step(bus)
      doAssert host.pc == 0x915B and host.s == 0x1FFC
      doAssert bus.word(0x1FFD) == 0x6917 and bus.mem[0x1FFF] == 0xC0
      var steps = 0
      while host.pc != 0x6918:
        doAssert steps < 150
        host.step(bus)
        inc steps
      doAssert host.pbr == 0xC0 and host.s == 0x1FFF
      doAssert host.a.int == dividend div 128 and host.y.int == dividend mod 128
      doAssert host.x.int == dividend and host.d == 0x1F00 and host.dbr == 0x7E
      doAssert host.p.int == expectedStatus(dividend, 128, dividend div 128,
        dividend mod 128, carry)
      inc result

proc main() =
  ## Require original and fresh rebuilt images and exercise independent mathematical edge matrices.
  for imageIndex, image in engineImages("bin/unsigned_division_extract"):
    let bus = newBus()
    for offset in 0 ..< 65536: bus.mem[0xC00000 + offset] = image[offset]
    var cases = bus.checkLookupCaller()
    for dividend in 0 .. 65535:
      for divisor in DivisorEdges:
        let status = (dividend xor divisor) and (FlagC or FlagZ or FlagI or FlagV or FlagN).int
        bus.check(dividend, divisor, status, dividend)
        inc cases
    for divisor in 0 .. 65535:
      for dividend in [0, 0x7FFF, 0x8000, 0xFFFF]:
        let status = (dividend xor divisor) and (FlagC or FlagZ or FlagI or FlagV or FlagN).int
        bus.check(dividend, divisor, status, divisor)
        inc cases
    for dividend in DividendEdges:
      for divisor in DivisorEdges:
        for status in 0 .. 255:
          if (status and (FlagM or FlagX or FlagD).int) == 0:
            bus.check(dividend, divisor, status, 0xFFFF)
            inc cases
    echo &"unsigned division image{imageIndex}: {cases} full-word/zero-divisor/status and real lookup-caller contexts passed"

when isMainModule:
  main()
