import
  std/strutils,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  PortWrite = tuple[address: uint16, value: uint8]

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  CallSites = [0x596, 0x599, 0x59C, 0x59F, 0x5A2, 0x5A7, 0x5AD,
    0x5B0, 0x5B5, 0x5BB, 0x5C0]
  Targets = [0x1609, 0x2DAB, 0x2DF3, 0x2DD5, 0x11DC, 0x635, 0x2E1D,
    0x11BA, 0x635, 0x1198, 0x635]
  Edges = [0, 1, 127, 128, 170, 255]

proc loaded(rom: seq[uint8]): Spc =
  ## Load the selected image's resident package into a fresh synthetic state.
  result = newSpc()
  for index in 0 ..< DriverLength:
    result.ram[DriverStart + index] = rom[DriverPayload + index]
  result.sp = 0xEE
  result.ram[0x1EF] = 7 # Authored pending timer byte, above all nested native frames.

proc checkPoll(rom: seq[uint8]) =
  ## Check low-product carry routing and pending count for full-byte authored inputs.
  var
    spc = loaded(rom)
    timer, reads, contexts, actualDomain: int
  spc.readHook = proc(address: uint16): int =
    doAssert address == 0xFD
    inc reads
    if reads <= 2: 0 else: timer
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, "unexpected polling I/O write"
    false
  for count in 1 .. 255:
    timer = count
    for accumulator in 0 .. 255:
      for seed in [0, 255 and not PswP.int]:
        spc.pc = 0x579
        spc.sp = 0xEF
        spc.a = 0x91
        spc.x = 0x5A
        spc.y = 0xE1
        spc.psw = seed.uint8
        spc.ram[0x43] = accumulator.uint8
        spc.ram[0x42] = 0x96
        spc.ram[0x44] = 0x69
        spc.ram[0x1EE] = 0x39
        spc.ram[0x1F0] = 0x93
        spc.ram[0x1EF] = 0
        reads = 0
        var steps = 0
        while spc.pc notin [0x596'u16, 0x5CD'u16]:
          doAssert steps < 20
          spc.step()
          inc steps
        let
          low = (count * 32) and 255
          sum = low + accumulator
          value = sum and 255
          carry = if sum > 255: 1 else: 0
          flags = (seed and (PswP or PswI or PswB).int) or carry or
            (if value == 0: PswZ.int else: 0) or (value and PswN.int) or
            (if (low and 15) + (accumulator and 15) > 15: PswH.int else: 0) or
            (if ((not(low xor accumulator)) and (low xor value) and 128) != 0: PswV.int else: 0)
        doAssert spc.pc.int == (if carry == 1: 0x596 else: 0x5CD)
        doAssert spc.ram[0x43].int == value and spc.a.int == value
        doAssert spc.y.int == count * 32 div 256 and spc.x == 0x5A
        doAssert spc.sp == 0xEE and spc.ram[0x1EF].int == count
        doAssert spc.ram[0x42] == 0x96 and spc.ram[0x44] == 0x69
        doAssert spc.ram[0x1EE] == 0x39 and spc.ram[0x1F0] == 0x93
        doAssert spc.psw.int == flags and reads == 3
        inc contexts
        if count <= 15: inc actualDomain
  timer = 0
  reads = 0
  spc.pc = 0x579
  spc.sp = 0xEF
  let
    beforeIdleDp = spc.ram[0 .. 0xEF]
    beforeIdleStack = spc.ram[0x100 .. 0x1FF]
  for step in 0 ..< 20: spc.step()
  doAssert spc.pc == 0x579 and spc.sp == 0xEF and reads == 10
  doAssert spc.ram[0 .. 0xEF] == beforeIdleDp
  doAssert spc.ram[0x100 .. 0x1FF] == beforeIdleStack
  echo "poll contexts=", contexts, " four-bit nonzero domain=", actualDomain,
    " zero polling checked for ten reads (not termination)"

proc checkService(rom: seq[uint8]) =
  ## Exercise actual callees with idle service fields and an authored final port-one input.
  var contexts, calls: int
  for value in 0 .. 255:
    for previous in Edges:
      var
        spc = loaded(rom)
        writes: seq[PortWrite]
        observed: seq[int]
      spc.pc = 0x596
      spc.ram[0x4A5] = previous.uint8
      spc.readHook = proc(address: uint16): int =
        if address == 0xF5: value else: 0
      spc.writeHook = proc(address: uint16, data: uint8): bool =
        writes.add (address, data)
        true
      var steps = 0
      while spc.pc != 0x5C6:
        doAssert steps < 2000, "service budget at " & spc.pc.toHex(4)
        if spc.pc.int in CallSites:
          let index = observed.len
          doAssert index < CallSites.len and spc.pc.int == CallSites[index]
          doAssert spc.sp == 0xEE and spc.ram[0x1EF] == 7
          spc.step()
          doAssert spc.pc.int == Targets[index] and spc.sp == 0xEC
          observed.add Targets[index]
        else:
          spc.step()
        inc steps
      let changed = if value == previous: 0 else: value
      doAssert observed == @Targets
      doAssert spc.sp == 0xEE and spc.ram[0x1EF] == 7
      doAssert spc.ram[0x4B1].int == changed and spc.ram[0x4A1].int == changed
      doAssert spc.ram[0x4A5].int == value and spc.ram[1].int == value
      doAssert spc.ram[0x4B2] == 0 and spc.ram[0x4B3] == 0
      doAssert (0xF5'u16, value.uint8) in writes
      inc contexts
      calls += observed.len
  echo "real-callee service contexts=", contexts, " calls=", calls,
    " (idle earlier helpers; final port-one values all bytes)"

proc checkAlternate(rom: seq[uint8]) =
  ## Distinguish the alternate reset entry from timer carry routing without patching callees.
  for value in 0 .. 255:
    var
      spc = loaded(rom)
      writes: seq[PortWrite]
    spc.pc = 0x58C
    spc.ram[0x4B1] = value.uint8
    spc.readHook = proc(address: uint16): int = 0
    spc.writeHook = proc(address: uint16, data: uint8): bool =
      writes.add (address, data)
      true
    var steps = 0
    let stop = if value == 0xAA: 0xFFC0 else: 0x596
    while spc.pc.int != stop:
      doAssert steps < 200
      spc.step()
      inc steps
    doAssert spc.ram[0x1EF] == 7
    if value == 0xAA:
      doAssert spc.sp == 0xEC
      doAssert spc.ram[0x1ED] == 0x96 and spc.ram[0x1EE] == 5
      doAssert writes.len == 11 and writes[^1] == (0xF1'u16, 0x80'u8)
    else:
      doAssert spc.sp == 0xEE and writes.len == 0 and spc.a.int == value
      let difference = (value - 0xAA) and 255
      let expected = (if value >= 0xAA: PswC else: 0'u8) or
        (if difference == 0: PswZ else: 0'u8) or
        (if difference >= 128: PswN else: 0'u8)
      doAssert spc.psw == expected
  echo "alternate reset-gate contexts=256; one actual transfer to IPL boundary"

proc main() =
  ## Require both original and fresh byte-identical rebuilt images without an audio device.
  for index, image in engineImages("bin/spc_timer_service_extract"):
    echo "image=", (if index == 0: "original" else: "fresh rebuild")
    checkPoll(image)
    checkService(image)
    checkAlternate(image)
  echo "SPC timer service passed across both images."

when isMainModule:
  main()
