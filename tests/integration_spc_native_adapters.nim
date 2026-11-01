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
  ReturnAddress = 0x4000'u16
  Stable = PswH or PswV or PswP or PswI or PswB or PswC
  NativeEntries = [(0x1810, 2, 1), (0x2501, 3, 71),
    (0x2C92, 1, 23), (0x2C9A, 1, 24), (0x2CA2, 1, 21), (0x2CAA, 1, 22),
    (0x2D82, 1, 27), (0x2D8D, 1, 25), (0x2D98, 1, 28), (0x2DA3, 1, 26)]
  Parameters = [2'u8, 1, 0, 128, 0x8A, 0,
      0x73] # Authored limits, instrument/gain/control and raw pitch.

proc word(spc: Spc, address: int): int =
  ## Read a structural or authored state word without exporting asset content.
  spc.ram[address].int + 256 * spc.ram[address + 1].int

proc putWord(spc: var Spc, address, value: int) =
  ## Write a synthetic structural word.
  spc.ram[address] = (value and 255).uint8
  spc.ram[address + 1] = (value shr 8).uint8

proc prepare(spc: var Spc, port, command, seed: int) =
  ## Reset authored low state while preserving original code, headers and pointer tables.
  for address in 0 .. 0x4FF:
    spc.ram[address] = ((address * 37 + seed * 19 + 113) and 255).uint8
  spc.ram[0xE] = 0
  spc.ram[0xF] = 0
  spc.ram[0x4B0 + port] = command.uint8
  spc.ram[0x4D1] = 29
  spc.ram[0x4D2] = 9
  spc.ram[0x4D3] = 128
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.sp = 0xEF
  spc.psw = (if (seed and 1) == 0: 0'u8 else: 0xDF'u8)
  spc.a = 0xA6
  spc.x = 0x39
  spc.y = 0xC7
  spc.pc = [0, 0x1198, 0x11BA, 0x11DC][port].uint16

proc handoff(spc: var Spc, port, command, entry: int) =
  ## Execute the real adapter and native-kind header consumer to the exact original entry.
  var steps = 0
  while spc.pc.int != entry:
    doAssert steps < 100 and spc.sp >= 0xED
    spc.step()
    inc steps
  doAssert spc.sp == 0xEF and spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.x.int == 2 * (command - 1) and spc.y == spc.x
  doAssert spc.ram[0x2E].int == port and spc.ram[0x2F].int == 2 * port
  doAssert spc.ram[0x48C + port] == 8
  doAssert spc.word(0x20) == entry - 3
  doAssert spc.word(0x440 + 2 * port) == (if entry ==
      0x2501: 0x148B else: 0x148A)

proc execute(spc: var Spc): seq[PortWrite] =
  ## Follow original callees through RET with bare port capture and protected native frame.
  let lowGuard = spc.ram[0x1E4]
  var writes: seq[PortWrite]
  spc.readHook = proc(address: uint16): int =
    doAssert false, "unexpected adapter hardware read"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address in [0xF2'u16, 0xF3'u16]
    writes.add (address, value)
    true
  var steps = 0
  while spc.pc != ReturnAddress:
    doAssert steps < 1200 and spc.sp >= 0xE5
    spc.step()
    inc steps
  doAssert spc.sp == 0xF1 and spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E4] == lowGuard
  result = writes

proc checkSetters(spc: var Spc) =
  ## Check complete original global/channel setters with all inherited byte seeds and pending-state guards.
  var contexts = 0
  for index in 2 .. 9:
    let (entry, port, command) = NativeEntries[index]
    for seed in 0 .. 255:
      spc.prepare(port, command, seed)
      spc.handoff(port, command, entry)
      let
        before = spc.ram[]
        status = spc.psw
        oldY = spc.y
        oldX = spc.x
      var expected = before
      let value = [100, 240, 16, 0, 90, 250, 40, 0][index - 2]
      if index in [2, 3]:
        expected[0x58] = 0
        expected[0x59] = value.uint8
      elif index in [4, 5]: expected[0x50] = value.uint8
      else:
        expected[0x30E] = 0
        expected[0x30F] = value.uint8
      doAssert spc.execute().len == 0
      for address in 0 .. 0x4FF:
        if address notin 0x1EC .. 0x1EF:
          doAssert spc.ram[address] == expected[address], "setter RAM $" &
              address.toHex(4)
      let resultA = if index in [4, 5]: value else: 0
      doAssert spc.a.int == resultA
      doAssert spc.x == (if index >= 6: 14'u8 else: oldX)
      doAssert spc.y == (if index in [2, 3]: value.uint8 else: oldY)
      doAssert spc.psw.int == ((status.int and Stable.int) or (resultA and
          128) or
        (if resultA == 0: PswZ.int else: 0))
      inc contexts
  echo "actual native setter contexts=", contexts, "; pending fades/dirty/scratch preserved"

proc fixture(spc: var Spc) =
  ## Author one ordinary instrument and a constant stereo curve without game assets.
  for index, value in [0x23, 0x81, 0x62, 0x43, 0, 0]: spc.ram[0x6E00 +
      index] = value.uint8
  for index in 0 .. 21: spc.ram[0xE73 + index] = 128
  for index in 0 .. 12: spc.putWord(0xEBC + 2 * index, 0x4567)

proc addDsp(writes: var seq[PortWrite], address, value: int) =
  ## Append a host-derived DSP address/data transaction.
  writes.add (0xF2'u16, address.uint8)
  writes.add (0xF3'u16, (value and 255).uint8)

proc checkFinish(spc: var Spc) =
  ## Reach original finish through port-two input one, testing output guards and all gain bytes.
  var contexts = 0
  for seed in 0 .. 255:
    for inhibit in [0, 255]:
      for oldMask in [0, 255]:
        spc.prepare(2, 1, seed)
        spc.fixture()
        let
          phase = (seed shr 6) * 64
          combined = oldMask or 0x40
          blocked = (combined and (inhibit and 0xBF)) != 0
        spc.ram[0x1A] = inhibit.uint8
        spc.ram[0x47] = oldMask.uint8
        spc.ram[0x4EC] = seed.uint8
        spc.ram[0x4FC] = phase.uint8
        spc.ram[0x211 + 12] = 0
        spc.putWord(0x330 + 12, 10 * 256)
        spc.handoff(2, 1, 0x1810)
        let
          before = spc.ram[]
          status = spc.psw
          queued = before[0x46].int or 0x40
        var expected = before
        expected[0x1A] = (inhibit and 0xBF).uint8
        expected[0x47] = combined.uint8
        expected[0x5E] = before[0x5E] or 0x40
        expected[0x46] = queued.uint8
        expected[0x321 + 12] = seed.uint8
        expected[0x351 + 12] = phase.uint8
        expected[0x10] = 0
        expected[0x11] = 10
        expected[0x12] = 0x62
        expected[0x14] = 0
        expected[0x15] = 0x6E
        for address in [0x4B6, 0x4CA, 0x48E]: expected[address] = 0
        var writes: seq[PortWrite]
        if not blocked:
          expected[0x220 + 12] = 0
          expected[0x221 + 12] = 0
          expected[0x49] = before[0x49] and (255 xor combined).uint8
          writes.addDsp(0x60, (if (phase and 128) == 0: seed div 2 else: -(seed div 2)))
          writes.addDsp(0x61, (if (phase and 64) == 0: seed div 2 else: -(seed div 2)))
          for index, value in [0x23, 0x81, 0x62, 0x43]: writes.addDsp(0x64 +
              index, value)
        doAssert spc.execute() == writes
        for address in 0 .. 0x4FF:
          if address notin 0x1EA .. 0x1EF:
            doAssert spc.ram[address] == expected[address], "finish RAM $" &
                address.toHex(4)
        doAssert spc.a.int == queued and spc.x == 2 and spc.y == (
            if blocked: 0'u8 else: 5'u8)
        doAssert spc.psw.int == ((status.int and (PswP or PswI or PswB).int) or
          (if blocked: 0 else: 1) or (queued and 128) or (if queued == 0: 2 else: 0))
        inc contexts
  echo "actual port-two finish contexts=", contexts

proc continueConfiguration(spc: var Spc) =
  ## Feed produced native state through its actual initialize and finish continuations without rewriting it.
  spc.ram[0x4B3] = 0
  spc.sp = 0xEF
  spc.pc = 0x11DC
  var expected: seq[PortWrite]
  for index, value in [0x23, 0x81, 0x62, 0x43]: expected.addDsp(0x74 + index, value)
  expected.addDsp(0x70, -64)
  expected.addDsp(0x71, 64)
  expected.addDsp(0x72, 0)
  expected.addDsp(0x73, 0)
  doAssert spc.execute() == expected
  doAssert spc.ram[0x4BB] == 1 and spc.ram[0x453] == 1 and spc.ram[0x4B7] == 71
  doAssert spc.ram[0x321 + 14] == 128 and spc.ram[0x351 + 14] == 0x80
  doAssert spc.ram[0x4EE] == 96 and spc.ram[0x4FE] == 0x40
  doAssert spc.ram[0x47] == 0 and (spc.ram[0x49] and 0x80) != 0
  spc.sp = 0xEF
  spc.pc = 0x11DC
  expected.setLen(0)
  expected.addDsp(0x70, 48)
  expected.addDsp(0x71, -48)
  for index, value in [0x23, 0x81, 0x62, 0x43]: expected.addDsp(0x74 + index, value)
  doAssert spc.execute() == expected
  doAssert spc.ram[0x4BB] == 0 and spc.ram[0x4B7] == 0 and spc.ram[0x4CB] ==
      0 and spc.ram[0x48F] == 0
  doAssert spc.ram[0x321 + 14] == 96 and spc.ram[0x351 + 14] == 0x40
  doAssert (spc.ram[0x1A] and 0x80) == 0 and (spc.ram[0x46] and 0x80) != 0

proc checkConfiguration(spc: var Spc) =
  ## Execute native state configuration with authored seven-byte payload and inherited marker/control guards.
  var contexts, chains = 0
  for control in 0 .. 255:
    for marker in [0, 1, 255]:
      spc.prepare(3, 71, control)
      spc.fixture()
      for index, value in Parameters: spc.ram[0x250A + index] = value
      spc.ram[0x48] = control.uint8
      spc.ram[0x4CB] = marker.uint8
      spc.ram[0x321 + 14] = 96
      spc.ram[0x351 + 14] = 0x40
      spc.ram[0x211 + 14] = 0
      spc.putWord(0x330 + 14, 10 * 256)
      spc.handoff(3, 71, 0x2501)
      let
        before = spc.ram[]
        status = spc.psw
        combined = (control and 0xE0) or 0x1F
      var expected = before
      expected[0x22] = 0x0A
      expected[0x23] = 0x25
      expected[0x24] = 0x1F
      expected[0x20] = 0x78
      expected[0x21] = 4
      expected[0x48] = combined.uint8
      expected[0x4CF] = combined.uint8
      expected[0x4BF] = Parameters[0]
      expected[0x4C3] = Parameters[1]
      for index, value in Parameters: expected[0x478 + index] = value
      for address in [0x1A, 0x46]: expected[address] = before[address] or 0x80
      for address in [0x4BB, 0xD3, 0xD7, 0xDB, 0x49F, 0x4B3, 0x453,
          0x457]: expected[address] = 0
      expected[0x4B7] = 71
      doAssert spc.execute().len == 0
      for address in 0 .. 0x4FF:
        if address notin 0x1EE .. 0x1EF:
          doAssert spc.ram[address] == expected[address], "config RAM $" &
              address.toHex(4)
      doAssert spc.a == 71 and spc.x == 3 and spc.y == 7
      doAssert spc.psw == ((status and (PswP or PswI or PswB or PswH or
          PswV)) or PswC)
      doAssert spc.word(0x446) == 0x148B and spc.ram[0x4CB].int == marker
      for index, value in Parameters: doAssert spc.ram[0x250A + index] == value
      inc contexts
      if marker == 0 and control in [0, 1, 127, 255]:
        spc.continueConfiguration()
        inc chains
  echo "actual port-three configuration contexts=", contexts,
    "; produced-state initialize/finish chains=", chains

proc main() =
  ## Require original and independently rebuilt images, with only authored instrument/state parameters.
  for index, image in engineImages("bin/spc_native_adapters_extract"):
    echo "image=", (if index == 0: "original" else: "fresh rebuild")
    var spc = newSpc()
    for offset in 0 ..< DriverLength:
      spc.ram[DriverStart + offset] = image[DriverPayload + offset]
    checkSetters(spc)
    checkFinish(spc)
    checkConfiguration(spc)
  echo "SPC native adapters passed across both images."

when isMainModule:
  main()
