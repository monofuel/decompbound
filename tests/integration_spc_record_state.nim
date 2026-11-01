import
  std/[sets, strutils],
  decompbound/[apu, spc700],
  ./engine/rebuilt_rom

type
  PortWrite = tuple[address: uint16, value: uint8]

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x4000'u16
  Preserved = PswH or PswV or PswP or PswI or PswB
  Tables = [0x180D, 0x17D5, 0x17C5, 0x16C7]
  CodeIntervals = [(0x148B, 84), (0x14DF, 120), (0x1557, 129),
    (0x15DB, 9), (0x15E7, 12), (0x15F6, 19)]

proc putWord(spc: var Spc, address, value: int) =
  ## Write an authored structural word with address wrap.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address + 1) and 65535] = (value shr 8).uint8

proc word(spc: Spc, address: int): int =
  ## Read an authored structural word with address wrap.
  spc.ram[address and 65535].int + 256 * spc.ram[(address + 1) and 65535].int

proc loaded(rom: seq[uint8]): Spc =
  ## Load original resident instructions and a protected native caller frame.
  result = newSpc()
  for index in 0 ..< DriverLength:
    result.ram[DriverStart + index] = rom[DriverPayload + index]
  for address in 0 .. 0x4FF:
    result.ram[address] = ((address * 37 + 19) and 255).uint8
  result.sp = 0xEF
  result.putWord(0x1F0, ReturnAddress.int)
  result.psw = PswH or PswV or PswI or PswB
  result.ram[0xE] = 0
  result.ram[0xF] = 0

proc execute(spc: var Spc, entry: int, budget = 1000): seq[PortWrite] =
  ## Run real original callees with captured bare port writes and no audio device.
  let lowGuard = spc.ram[0x1E8]
  let highGuard = spc.ram[0x1F2]
  var writes: seq[PortWrite]
  spc.readHook = proc(address: uint16): int =
    doAssert false, "unexpected state I/O read $" & address.toHex(4)
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address in [0xF2'u16, 0xF3'u16]
    writes.add (address, value)
    true
  spc.pc = entry.uint16
  var steps = 0
  while spc.pc != ReturnAddress:
    doAssert steps < budget, "state budget at $" & spc.pc.toHex(4)
    doAssert spc.sp >= 0xE9
    spc.step()
    inc steps
  doAssert spc.sp == 0xF1 and spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1E8] == lowGuard and spc.ram[0x1F2] == highGuard
  result = writes
  spc.readHook = nil
  spc.writeHook = nil

proc checkLayout(rom: seq[uint8]) =
  ## Derive native headers from real startup inventory before accepting any candidate code span.
  let machine = newApu()
  for index in 0 ..< DriverLength:
    machine.spc.ram[DriverStart + index] = rom[DriverPayload + index]
  machine.spc.pc = 0x500
  var steps = 0
  while machine.spc.pc != 0x546:
    doAssert steps < 40000
    machine.spc.step()
    inc steps
  var native: HashSet[int]
  for port, table in Tables:
    for command in 1 ..< machine.spc.ram[0x4D0 + port].int:
      let pointer = machine.spc.word(table + 2 * (command - 1))
      if machine.spc.ram[pointer - 1] == 8: native.incl(pointer)
  doAssert native.len == 25
  var headers: HashSet[int]
  for pointer in native:
    for address in pointer - 3 .. pointer - 1:
      if address in 0x148B .. 0x1608: headers.incl(address)
  doAssert headers == toHashSet([0x15D8, 0x15D9, 0x15DA, 0x15E4, 0x15E5,
    0x15E6, 0x15F3, 0x15F4, 0x15F5])
  var code = 0
  for (origin, length) in CodeIntervals:
    for address in origin ..< origin + length: doAssert address notin headers
    code += length
  doAssert code == 373 and code + headers.len == 382
  echo "startup inventory: 25 native pointers; new pool=373 code bytes +9 copied header bytes"

proc checkInitialize(rom: seq[uint8]) =
  ## Model forward overlapping seven-byte copies and control-dependent source truncation.
  var contexts = 0
  for entry in [0x14DF, 0x14EE, 0x14FC]:
    for slot in 0 .. 3:
      for source in [0x6000, 0x60FD, 0xFFFE]:
        for shift in [-1, 0, 1, 2, 6, 7]:
          for parameter in [0, 1, 255]:
            for oldControl in [0, 0xE0]:
              var spc = loaded(rom)
              let
                destination = (source + shift) and 65535
                command = (slot * 37 + parameter) and 255
                mask = 1 shl (slot + 3)
                combined = (oldControl and 0xE0) or parameter
                effective = if entry == 0x14EE and combined == 0: source and
                    0xFF00 else: source
              for offset in 0 .. 6:
                spc.ram[((source and 0xFF00) + offset) and 65535] = (offset *
                    23 + 41).uint8
                spc.ram[(source + offset) and 65535] = (offset * 17 + 19).uint8
              spc.putWord(0x2A, destination)
              spc.ram[0x2D] = command.uint8
              spc.ram[0x2E] = slot.uint8
              spc.ram[0x4D7] = mask.uint8
              spc.ram[0x48] = oldControl.uint8
              spc.psw = (if (slot and 1) == 0: Preserved and not PswP else: 0)
              spc.a = (source and 255).uint8
              spc.y = (source shr 8).uint8
              spc.x = parameter.uint8
              let
                before = spc.ram[]
                flags = spc.psw
              var expected = before
              expected[0x22] = (effective and 255).uint8
              expected[0x23] = (effective shr 8).uint8
              expected[0x20] = (destination and 255).uint8
              expected[0x21] = (destination shr 8).uint8
              expected[0x4BC + slot] = before[effective]
              expected[0x4C0 + slot] = before[(effective + 1) and 65535]
              expected[0x4CC + slot] = (if entry ==
                  0x14EE: combined else: 0).uint8
              if entry == 0x14DF: expected[0x4C8 + slot] = 0
              if entry == 0x14EE:
                expected[0x24] = parameter.uint8
                expected[0x48] = combined.uint8
              for index in 0 .. 6:
                expected[(destination + index) and 65535] = expected[(
                    effective + index) and 65535]
              for address in [0x1A, 0x46]: expected[address] = expected[
                  address] or mask.uint8
              for address in [0x4B8, 0xD0, 0xD4, 0xD8, 0x49C, 0x4B0, 0x450, 0x454]:
                expected[address + slot] = 0
              expected[0x4B4 + slot] = command.uint8
              doAssert spc.execute(entry).len == 0
              for address in 0 .. 65535:
                if address notin 0x1EE .. 0x1EF:
                  doAssert spc.ram[address] == expected[address], "init RAM $" &
                      address.toHex(4)
              doAssert spc.a.int == command and spc.x.int == slot and spc.y == 7
              doAssert spc.psw.int == ((flags.int and Preserved.int) or
                  PswC.int or
                (command and 128) or (if command == 0: PswZ.int else: 0))
              inc contexts
  echo "state initialization/overlap contexts=", contexts

proc addDsp(writes: var seq[PortWrite], register, value: int) =
  ## Append a mathematical DSP transaction to the expected ordered port stream.
  writes.add (0xF2'u16, (register and 255).uint8)
  writes.add (0xF3'u16, (value and 255).uint8)

proc instrumentFixture(spc: var Spc) =
  ## Author one instrument and constant pan/pitch curves for independently predictable output.
  for index, value in [0x23, 0x81, 0x62, 0x43, 0, 0]:
    spc.ram[0x6E00 + index] = value.uint8
  for index in 0 .. 21: spc.ram[0xE73 + index] = 128
  for index in 0 .. 12: spc.putWord(0xEBC + 2 * index, 0x4567)

proc checkApply(rom: seq[uint8]) =
  ## Run real instrument/stereo/pitch output for authored five-byte payloads and zero multipliers.
  var contexts = 0
  for slot in 0 .. 3:
    for voice in 0 .. 7:
      for base in [0x5000, 0x50FD, 0x50FE, 0x50FF]:
        for variant in 0 .. 15:
          var spc = loaded(rom)
          spc.instrumentFixture()
          let
            channel = voice * 2
            register = voice * 16
            payload = (base and 0xFF00) or ((base + 2) and 255)
            gain = [0, 1, 127, 255][variant and 3]
            phase = ((variant shr 2) and 3) * 64
            pan = [0, 10, 20][(slot + voice + variant) mod 3]
            override = (variant and 1) != 0
            noisy = (variant and 2) != 0
            mask = 1 shl voice
          spc.putWord(0x2A, base)
          for index, value in [0, gain, phase or pan, 12, 0x73]:
            spc.ram[payload + index] = value.uint8
          spc.x = slot.uint8
          spc.ram[0x4DF] = channel.uint8
          spc.ram[0x4D6] = (255 xor mask).uint8
          spc.ram[0x4D7] = mask.uint8
          spc.ram[0x4CC + slot] = noisy.uint8
          spc.ram[0x431] = override.uint8
          spc.ram[0x321 + channel] = 0xA5
          spc.ram[0x351 + channel] = 0x5A
          spc.ram[0x1A] = 255
          spc.ram[0x1B] = 255
          spc.ram[0x49] = 0x69
          spc.ram[0x47] = 0xFF
          let before = spc.ram[]
          var expectedChannels = before[0x200 .. 0x3FF]
          expectedChannels[0x20 + channel] = 0
          expectedChannels[0x21 + channel] = 0
          expectedChannels[0x121 + channel] = gain.uint8
          expectedChannels[0x151 + channel] = phase.uint8
          var expected: seq[PortWrite]
          for index, value in [0x23, 0x81, 0x62, 0x43]: expected.addDsp(
              register + 4 + index, value)
          let magnitude = gain div 2
          expected.addDsp(register, (if (phase and 128) ==
              0: magnitude else: -magnitude))
          expected.addDsp(register + 1, (if (phase and 64) ==
              0: magnitude else: -magnitude))
          expected.addDsp(register + 2, 0)
          expected.addDsp(register + 3, 0)
          doAssert spc.execute(0x1557) == expected
          doAssert spc.ram[0x200 .. 0x3FF] == expectedChannels
          doAssert spc.word(0x22) == payload and spc.ram[0x47] == 0
          doAssert spc.ram[0x4E0 + channel] == 0xA5 and spc.ram[0x4F0 +
              channel] == 0x5A
          doAssert spc.ram[0x321 + channel].int == gain and spc.ram[0x351 +
              channel].int == phase
          doAssert spc.ram[0x433].int == (if override: 10 else: pan) and
              spc.ram[0x211 + channel] == before[0x211 + channel]
          doAssert spc.ram[0x49].int == (if noisy: 0x69 or mask else: 0x69 and (255 xor mask))
          for address in [0x330 + channel, 0x331 + channel, 0x1A, 0x1B, 0x4B4 + slot]:
            doAssert spc.ram[address] == before[address]
          doAssert spc.a == 0 and spc.x.int == channel and spc.y.int ==
              register + 3
          doAssert spc.psw == (PswI or PswB or PswZ)
          inc contexts
  echo "complete apply/instrument/stereo/pitch contexts=", contexts

proc checkFinish(rom: seq[uint8]) =
  ## Finish actual record state and guard both allowed and inhibited restored output paths.
  var contexts = 0
  for slot in 0 .. 3:
    for voice in 0 .. 7:
      for oldMask in [0, 255]:
        for inhibit in [0, 255]:
          for entry in [0x1491, 0x148B]:
            for phase in [0, 64, 128, 192]:
              var spc = loaded(rom)
              spc.instrumentFixture()
              let
                channel = voice * 2
                register = voice * 16
                mask = 1 shl voice
                combined = oldMask or mask
                blocked = (combined and (inhibit and (255 xor mask))) != 0
              spc.ram[0x2E] = slot.uint8
              spc.ram[0x4DF] = channel.uint8
              spc.ram[0x4D6] = (255 xor mask).uint8
              spc.ram[0x4D7] = mask.uint8
              spc.ram[0x47] = oldMask.uint8
              spc.ram[0x1A] = inhibit.uint8
              spc.ram[0x4E0 + channel] = 127
              spc.ram[0x4F0 + channel] = phase.uint8
              spc.ram[0x321 + channel] = 0xA5
              spc.ram[0x351 + channel] = 0x5A
              spc.ram[0x330 + channel] = 0
              spc.ram[0x331 + channel] = 10
              spc.ram[0x211 + channel] = 0
              let before = spc.ram[]
              var expectedChannels = before[0x200 .. 0x3FF]
              expectedChannels[0x121 + channel] = 127
              expectedChannels[0x151 + channel] = phase.uint8
              if not blocked:
                expectedChannels[0x20 + channel] = 0
                expectedChannels[0x21 + channel] = 0
              var expected: seq[PortWrite]
              if not blocked:
                expected.addDsp(register, (if (phase and 128) ==
                    0: 63 else: -63))
                expected.addDsp(register + 1, (if (phase and 64) ==
                    0: 63 else: -63))
                for index, value in [0x23, 0x81, 0x62, 0x43]: expected.addDsp(
                    register + 4 + index, value)
              if entry == 0x148B:
                spc.ram[0x4B8 + slot] = 1
                spc.ram[0x4BC + slot] = 2
              doAssert spc.execute(entry) == expected
              doAssert spc.ram[0x200 .. 0x3FF] == expectedChannels
              doAssert spc.ram[0x49] == (if blocked: before[0x49] else: before[
                  0x49] and (255 xor combined).uint8)
              if entry == 0x148B: doAssert spc.ram[0x4B8 + slot] == 0
              doAssert spc.ram[0x321 + channel] == 127 and spc.ram[0x351 +
                  channel].int == phase
              doAssert spc.ram[0x1A].int == (inhibit and (255 xor mask))
              doAssert spc.ram[0x47].int == combined and spc.ram[0x5E] == (
                  before[0x5E] or mask.uint8)
              doAssert spc.ram[0x46] == (before[0x46] or mask.uint8)
              for address in [0x4B4, 0x4C8, 0x48C]: doAssert spc.ram[address +
                  slot] == 0
              doAssert spc.a == spc.ram[0x46] and spc.x.int == slot
              let queued = (before[0x46].int or mask)
              doAssert spc.y == (if blocked: 0'u8 else: 5'u8)
              doAssert spc.psw.int == ((PswI or PswB).int or
                (if blocked: 0 else: PswC.int) or (queued and 128) or
                (if queued == 0: PswZ.int else: 0))
              inc contexts
  echo "complete restored finish contexts=", contexts

proc checkNativeArms(rom: seq[uint8]) =
  ## Exercise metadata-selected state clear/fades through original shared signed arithmetic.
  var contexts = 0
  for current in 0 .. 255:
    for entry in [0x15E7, 0x15F6]:
      var spc = loaded(rom)
      let
        duration = if entry == 0x15E7: 112 else: 24
        delta = 16 - current
        step = ((if delta < 0: -1 else: 1) * (abs(delta) *
            256 div duration)) and 65535
      spc.ram[0x44] = 6
      spc.x = 6
      spc.ram[0x59] = current.uint8
      spc.ram[0x58] = (current xor 0xA5).uint8
      let before = spc.ram[]
      doAssert spc.execute(entry).len == 0
      doAssert spc.ram[0x492].int == (if entry == 0x15E7: 2 else: 1)
      doAssert spc.ram[0x491].int == duration and spc.ram[0x5A].int == duration
      doAssert spc.ram[0x5B] == 16 and spc.word(0x5C) == step
      for address in [0x30, 0x31, 0x58, 0x59, 0x5E]: doAssert spc.ram[
          address] == before[address]
      doAssert spc.x == 6
      inc contexts
  var spc = loaded(rom)
  let before = spc.ram[]
  doAssert spc.execute(0x15DB).len == 0
  for address in 0 .. 65535:
    doAssert spc.ram[address] == (if address in [0x4B5,
        0x491]: 0'u8 else: before[address])
  echo "native arm/fade contexts=", contexts, "; clear context=1"

proc checkProgressReturn(rom: seq[uint8]) =
  ## Pin the progress wrapper's nonzero return through its real counter callee.
  for slot in 0 .. 3:
    for status in [0'u8, PswH or PswV or PswI or PswB]:
      var spc = loaded(rom)
      spc.psw = status
      spc.ram[0x2E] = slot.uint8
      spc.ram[0x4B8 + slot] = 1
      spc.ram[0x4BC + slot] = 3
      spc.ram[0x4C0 + slot] = 4
      let before = spc.ram[]
      doAssert spc.execute(0x148B).len == 0
      for address in 0 .. 65535:
        if address notin 0x1EE .. 0x1EF:
          doAssert spc.ram[address] ==
            (if address == 0x4B8 + slot: 2'u8 else: before[address])
      doAssert spc.a == 2 and spc.x.int == slot
      doAssert spc.psw == (status and Preserved)
  echo "progress wrapper non-finish contexts=8; actual $13A0 return"

proc checkSharedFade(rom: seq[uint8]) =
  ## Check shared duration input including zero-divisor arithmetic without fetching stream bytes.
  var contexts = 0
  for duration in [0, 1, 127, 128, 255]:
    for current in [0, 16, 17, 255]:
      var spc = loaded(rom)
      let
        delta = 16 - current
        magnitude = if duration == 0: 65535 - abs(delta)
          else: abs(delta) * 256 div duration
        step = ((if delta < 0: -magnitude else: magnitude)) and 65535
      spc.a = duration.uint8
      spc.ram[0x44] = 8
      spc.ram[0x59] = current.uint8
      let before = spc.ram[]
      doAssert spc.execute(0x1600).len == 0
      doAssert spc.ram[0x5A].int == duration and spc.ram[0x5B] == 16
      doAssert spc.word(0x5C) == step and spc.x == 8
      for address in [0x30, 0x31, 0x491, 0x492, 0x58, 0x59, 0x5E]:
        doAssert spc.ram[address] == before[address]
      inc contexts
  echo "shared native fade-tail duration contexts=", contexts

proc checkNativeDispatchMismatch(rom: seq[uint8]) =
  ## Execute actual port-one records with table-offset X differing from the divider's saved X.
  var contexts = 0
  for command in [2, 3]:
    for current in [0, 16, 17, 255]:
      for saved in [0, 6, 14]:
        var spc = loaded(rom)
        let
          native = if command == 2: 0x15F6 else: 0x15E7
          duration = if command == 2: 24 else: 112
          delta = 16 - current
          step = ((if delta < 0: -1 else: 1) *
            (abs(delta) * 256 div duration)) and 65535
        doAssert spc.word(0x17D5 + 2 * (command - 1)) == native
        spc.ram[0x4B1] = command.uint8
        spc.ram[0x4D1] = 29 # Startup's actual exclusive capacity, not an arbitrary expanded table.
        spc.ram[0x44] = saved.uint8
        spc.ram[0x59] = current.uint8
        spc.ram[0x58] = (current xor 0xA5).uint8
        let before = spc.ram[]
        spc.readHook = proc(address: uint16): int =
          doAssert false, "unexpected native record hardware read"
          -1
        spc.writeHook = proc(address: uint16, value: uint8): bool =
          doAssert false, "unexpected native record hardware write"
          false
        spc.pc = 0x1198
        var steps, witnesses: int
        while spc.pc != ReturnAddress:
          doAssert steps < 200 and spc.sp >= 0xEB
          if spc.pc.int == native:
            doAssert spc.x.int == 2 * (command - 1) and spc.x.int != saved
            doAssert spc.sp == 0xEF and spc.word(0x1F0) == ReturnAddress.int
            inc witnesses
          spc.step()
          inc steps
        doAssert witnesses == 1 and spc.sp == 0xF1 and spc.x.int == saved
        doAssert spc.ram[0x44].int == saved and spc.word(0x5C) == step
        doAssert spc.ram[0x491].int == duration and spc.ram[0x5A].int == duration
        doAssert spc.ram[0x492].int == (if command == 2: 1 else: 2)
        doAssert spc.ram[0x5B] == 16
        for address in [0x30, 0x31, 0x58, 0x59, 0x5E]:
          doAssert spc.ram[address] == before[address]
        inc contexts
  echo "actual port-one native arm X-mismatch contexts=", contexts

proc main() =
  ## Require original and independently rebuilt images with authored state and no audio device.
  for index, image in engineImages("bin/spc_record_state_extract"):
    echo "image=", (if index == 0: "original" else: "fresh rebuild")
    checkLayout(image)
    checkInitialize(image)
    checkApply(image)
    checkFinish(image)
    checkNativeArms(image)
    checkProgressReturn(image)
    checkSharedFade(image)
    checkNativeDispatchMismatch(image)
  echo "SPC record state passed across both images."

when isMainModule:
  main()
