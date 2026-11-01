## Record parser and setup/output adapters on original and freshly rebuilt images.
## Fixtures are authored; the 78 timing-data and eight classification bytes stay in ROM.
import
  std/[strformat, tables],
  decompbound/spc700,
  ./engine/rebuilt_rom

type PortWrite = tuple[address: uint16, value: uint8]

const
  DriverMap = 0x25FB42
  DriverStart = 0x500
  DriverLength = 16779
  ReturnAddress = 0x5000'u16

proc word(spc: Spc, address: int): int =
  ## Read a wrapping authored pointer.
  spc.ram[address and 65535].int or (spc.ram[(address + 1) and 65535].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Write an authored little-endian fixture value.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address + 1) and 65535] = (value shr 8).uint8

proc prepare(spc: var Spc, seed: int) =
  ## Guard low RAM while leaving all original driver instructions unchanged.
  for address in 0 .. 0x4FF:
    spc.ram[address] = ((address * 37 + seed * 19 + 113) and 255).uint8
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.sp = 0xEF
  spc.a = seed.uint8
  spc.x = (seed xor 0x5A).uint8
  spc.y = (seed xor 0xA5).uint8
  spc.psw = if (seed and 1) == 0: 0 else: 0xDF

proc execute(spc: var Spc, entry: int, stop = ReturnAddress.int, budget = 200,
             minimumSp = 0xEB): seq[PortWrite] =
  ## Execute original code with real stack frames and bare ordered hardware capture.
  var writes: seq[PortWrite]
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected hardware read ${address:04X}"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address in [0xF2'u16, 0xF3]
    writes.add (address, value)
    true
  spc.pc = entry.uint16
  var instructions = 0
  while spc.pc.int != stop:
    doAssert instructions < budget, &"entry${entry:04X} PC${spc.pc:04X}"
    doAssert spc.sp.int >= minimumSp
    spc.step()
    inc instructions
  if stop == ReturnAddress.int: doAssert spc.sp == 0xF1
  doAssert spc.word(0x1F0) == ReturnAddress.int
  result = writes

proc guard(spc: Spc, before: array[0x10000, uint8], changes: Table[int, int],
           scratch: openArray[int] = []) =
  ## Assert host-derived outputs and all other low-memory/stack neighbors.
  for address in 0 .. 0x4FF:
    if address in scratch or address in 0x1EC .. 0x1EF: continue
    let expected = if changes.hasKey(address): changes[address].uint8 else: before[address]
    doAssert spc.ram[address] == expected, &"RAM${address:04X} {spc.ram[address]} != {expected}"

proc addDsp(writes: var seq[PortWrite], register, value: int) =
  ## Specify ordered hardware writes without constructing an audio device.
  writes.add (0xF2'u16, register.uint8)
  writes.add (0xF3'u16, value.uint8)

proc installCurves(spc: var Spc) =
  ## Author tiny independent stereo and pitch curves in their known lookup windows.
  for index in 0 .. 21: spc.ram[0xE73 + index] = (index * index div 2).uint8
  for index in 0 .. 12: spc.putWord(0xEBC + index * 2, 0x200 + index * index * 13)

proc pitchWord(position: int): int =
  ## Model raw conversion with unsigned low-difference interpolation and pre-shift wrap.
  let
    numerator = (2 * (position shr 8)) and 255
    quotient = numerator div 24
    interval = (numerator mod 24) div 2
    first = 0x200 + interval * interval * 13
    second = 0x200 + (interval + 1) * (interval + 1) * 13
    interpolated = (first + (((second - first) and 255) * (position and 255) div 256)) and 65535
    doubled = (2 * interpolated) and 65535
  if quotient <= 6: doubled shr (6 - quotient) else: 0

proc panWrites(channel, gain, control, position, effectiveMask, inhibit: int): seq[PortWrite] =
  ## State the stereo law for integer positions on the authored nonlinear curve.
  if (effectiveMask and inhibit) == 0:
    let
      left = gain * (position * position div 2) div 256
      rightPosition = 20 - position
      right = gain * (rightPosition * rightPosition div 2) div 256
    result.addDsp(channel * 8, (if (control and 128) != 0: -left else: left) and 255)
    result.addDsp(channel * 8 + 1, (if (control and 64) != 0: -right else: right) and 255)

proc checkPanAndPitch(spc: var Spc): int =
  ## Verify actual output tails and raw unclamped handoffs without external curve assets.
  spc.installCurves()
  for channel in countup(0, 14, 2):
    for control in 0 .. 255:
      for override in [0, 1]:
        spc.prepare(control)
        spc.x = channel.uint8
        spc.ram[0x22] = 0xA6
        spc.ram[0x23] = control.uint8
        spc.ram[0x431] = override.uint8
        spc.ram[0x47] = 255
        spc.ram[0x4D6] = (255 xor (1 shl (channel div 2))).uint8
        let
          position = if override != 0: 10 else: control and 63
          mask = spc.ram[0x4D6].int
          before = spc.ram[]
        let changes = {0x321 + channel: 0xA6, 0x351 + channel: control and 0xC0,
          0x433: position, 0x10: 0, 0x11: position, 0x47: mask}.toTable
        doAssert spc.execute(0x10B6, 0xC95).len == 0
        spc.guard(before, changes)
        doAssert spc.x.int == channel
        inc result
  for channel in countup(0, 14, 2):
    for position in 0 .. 20:
      for phase in 0 .. 3:
        for gain in [0, 1, 127, 128, 254, 255]:
          for inhibit in [0, 255]:
            let control = position or (phase shl 6)
            spc.prepare(control)
            spc.x = channel.uint8
            spc.ram[0x22] = gain.uint8
            spc.ram[0x23] = control.uint8
            spc.ram[0x431] = 0
            spc.ram[0x47] = 255
            spc.ram[0x1A] = inhibit.uint8
            spc.ram[0x4D6] = (255 xor (1 shl (channel div 2))).uint8
            let before = spc.ram[]
            let mask = spc.ram[0x4D6].int
            let changes = {0x321 + channel: gain, 0x351 + channel: control and 0xC0,
              0x433: position, 0x10: 0, 0x11: position,
              0x12: channel * 8 + 2, 0x47: mask}.toTable
            doAssert spc.execute(0x10B6, budget=250, minimumSp=0xEA) ==
              panWrites(channel, gain, control, position, mask, inhibit)
            spc.guard(before, changes, [0x1EB])
            doAssert spc.x.int == channel
            inc result
  for high in 0 .. 255:
    for fraction in [0, 1, 127, 128, 254, 255]:
      for inhibit in [0, 255]:
        let
          channel = ((high xor fraction) and 7) * 2
          position = high * 256 + fraction
          pitch = pitchWord(position)
        spc.prepare(fraction)
        spc.a = fraction.uint8
        spc.y = high.uint8
        spc.x = (high xor fraction).uint8
        spc.ram[0x4DF] = channel.uint8
        spc.ram[0x4D6] = (255 xor (1 shl (channel div 2))).uint8
        spc.ram[0x47] = 255
        spc.ram[0x1A] = inhibit.uint8
        spc.putWord(0x220 + channel, 0x0100)
        let
          before = spc.ram[]
          oldX = spc.x
          mask = spc.ram[0x4D6].int
          changes = {0x10: fraction, 0x11: high, 0x14: pitch and 255,
            0x15: pitch shr 8, 0x16: pitch and 255, 0x17: pitch shr 8, 0x47: mask}.toTable
        var expected: seq[PortWrite]
        if inhibit == 0:
          expected.addDsp(channel * 8 + 2, pitch and 255)
          expected.addDsp(channel * 8 + 3, pitch shr 8)
        doAssert spc.execute(0x10E7, budget=1600, minimumSp=0xE9) == expected
        spc.guard(before, changes, [0x1EA, 0x1EB])
        doAssert spc.x == oldX
        inc result

proc prepareStream(spc: var Spc, port, pointer, control, fraction, inhibit: int) =
  ## Author one state block and the minimal service-ready counter state.
  spc.prepare(fraction)
  let
    channel = 8 + 2 * port
    state = 0x460 + 8 * port
    configuration = [2, 1, 9, 156, control, 0xC9, fraction]
  for index, value in configuration: spc.ram[state + index] = value.uint8
  spc.putWord(0x2A, state)
  spc.ram[0x2E] = port.uint8
  spc.ram[0x2F] = (2 * port).uint8
  spc.ram[0x4DF] = channel.uint8
  spc.ram[0x4D5] = (channel * 8).uint8
  spc.ram[0x4D6] = (255 xor (1 shl (channel div 2))).uint8
  spc.ram[0x4D7] = (1 shl (channel div 2)).uint8
  spc.putWord(0x480 + 2 * port, pointer)
  spc.ram[0x4B8 + port] = 1
  spc.ram[0x4BC + port] = 2
  spc.ram[0x4C0 + port] = 1
  spc.ram[0x49C + port] = 0
  spc.ram[0xD0 + port] = 0
  spc.ram[0x47] = 255
  spc.ram[0x1A] = inhibit.uint8
  spc.ram[0x431] = 0
  spc.ram[0x5F] = 37
  spc.putWord(0x220 + channel, 0x0100)

proc checkParser(spc: var Spc): int =
  ## Classify every token through real13A0/readers and authored records, including wrap.
  spc.installCurves()
  for port in 0 .. 3:
    for token in 0 .. 255:
      for pointer in [0x6000, 0xFFFA]:
        for inhibit in [0, 255]:
          for oldControl in [0, 10]:
            let
              channel = 8 + 2 * port
              fraction = (token * 37 + 19) and 255
              instrument = token xor 0xA5
              operand = if token == 0xE0: instrument elif token == 0xE1: 0xCA else: 0x92
            spc.prepareStream(port, pointer, oldControl, fraction, inhibit)
            let payload = if token in [0xE0, 0xE1, 0xED]: @[token, operand, 0xC9]
              else: @[token, 0xC9]
            for index, value in payload:
              spc.ram[(pointer + 6 + index) and 65535] = value.uint8
            let
              instrumentIndex = if instrument < 128: instrument else: (instrument - 0xCA + 37) and 255
              instrumentPointer = 0x6E00 + 6 * instrumentIndex
              instrumentData = [0x35, 0xA6, 0x73, 0x25, 0x12, 0x34]
            for index, value in instrumentData: spc.ram[instrumentPointer + index] = value.uint8
            let before = spc.ram[]
            var expected: seq[PortWrite]
            if token == 0xE0:
              for register in 0 .. 3: expected.addDsp(channel * 8 + 4 + register, instrumentData[register])
            elif token == 0xE1:
              expected = panWrites(channel, 156, 0xCA, 10, spc.ram[0x4D6].int, inhibit)
            elif token == 0xED and oldControl != 0:
              expected = panWrites(channel, operand, oldControl, oldControl, spc.ram[0x4D6].int, inhibit)
            elif token >= 128 and token != 0xC9 and token != 0xED:
              if inhibit == 0:
                let pitch = pitchWord(token * 256 + fraction)
                expected.addDsp(channel * 8 + 2, pitch and 255)
                expected.addDsp(channel * 8 + 3, pitch shr 8)
            doAssert spc.execute(0xFB7, (if token == 0: 0x1491 else: ReturnAddress.int),
              budget=2000, minimumSp=0xE7) == expected
            doAssert spc.ram[0x4B8 + port] == 0 # Actual13A0 expired the tick first.
            let consumed = if token == 0xED and oldControl == 0: 1
              elif token in [0xE0, 0xE1, 0xED]: 3
              elif token in 1 .. 127: 2 else: 1
            doAssert spc.ram[0xD0 + port].int == consumed
            doAssert spc.ram[0x4DE].int == fraction
            doAssert spc.x.int == (if token == 0: 2 * port + 1 else: port)
            # Source-pointer high read INC X remains live on the zero-token handoff.
            let marker = if token == 0xED and oldControl == 0: 0
              elif token in [0xE0, 0xE1, 0xED] or token in 1 .. 127 or token == 0xC9: 0xC9
              elif token == 0: before[0x4C8 + port].int else: 0
            doAssert spc.ram[0x4C8 + port].int == marker
            if token in 1 .. 127:
              let
                first = if token == 127: 4 else: before[0x1068 + token - 1].int
                second = if token == 127: 2 else: before[0x1068 + token].int
              doAssert spc.ram[0x4BC + port].int == first and spc.ram[0x4C0 + port].int == second
              if token == 127: doAssert spc.ram[0x46] == (before[0x46] or before[0x4D7])
            if token == 0xE0:
              doAssert spc.word(0x220 + channel) == 0x1234 and spc.ram[0x47] == 0
              doAssert spc.ram[0x211 + channel] == before[0x211 + channel]
            if token == 0xE1 or token == 0xED and oldControl != 0:
              let
                control = if token == 0xE1: 0xCA else: oldControl
                gain = if token == 0xE1: 156 else: operand
              doAssert spc.ram[0x4DB].int == gain and spc.ram[0x4DC].int == control
              doAssert spc.ram[0x463 + 8 * port].int == gain
              doAssert spc.ram[0x464 + 8 * port].int == control
            inc result

proc checkInstallAndRoutes(spc: var Spc): int =
  ## Execute real setup tails with authored records, ordinary selectors and retarget prefixes.
  for port in 0 .. 3:
    for selector in 0 .. 255:
      for firstToken in [0, 0xC9, 0xE0, 255]:
        for entry in [0xF56, 0xF4B, 0x1170, 0x1176]:
          spc.prepare(selector)
          let
            pointer = 0x6003
            state = 0x460 + port * 8
            record = [9, 156, 10, 0x35, selector, firstToken]
            bit = 1 shl (port + 4)
          for index, value in record: spc.ram[pointer + index] = value.uint8
          spc.putWord(pointer - 3, 0x7123) # Authored port-two replacement table entry.
          spc.ram[0x2E] = port.uint8
          spc.ram[0x2F] = (2 * port).uint8
          spc.ram[0x2D] = 6
          spc.ram[0x4D7] = bit.uint8
          spc.putWord(0x2A, state)
          if entry in [0x1170, 0x1176]:
            spc.putWord(0x20, pointer)
            spc.sp = 0xEE
            spc.ram[0x1EF] = 0x2A # Real saved lookup offset consumed by route POP X.
          else:
            spc.a = (pointer and 255).uint8
            spc.y = (pointer shr 8).uint8
          let
            before = spc.ram[]
            index = (selector - 1) and 255
            first = if selector == 127: 4 else: before[0x1068 + index].int
            second = if selector == 127: 2 else: before[0x1068 + ((index + 1) and 255)].int
            configuration = [first, second, record[0], record[1], record[2], record[5], record[3]]
            marked = entry in [0xF4B, 0x1170]
          doAssert spc.execute(entry, budget=250, minimumSp=0xE9).len == 0
          var changes = {0x20: state and 255, 0x21: state shr 8,
            0x22: 0xD8, 0x23: 4, 0x4BC + port: first, 0x4C0 + port: second,
            0x480 + 2 * port: pointer and 255, 0x481 + 2 * port: pointer shr 8,
            0x4C8 + port: (if firstToken == 0xC9: 0xC9 else: 0),
            0x4CC + port: 0, 0x4B8 + port: 0, 0xD0 + port: 0,
            0xD4 + port: 0, 0xD8 + port: 0, 0x49C + port: ord(marked),
            0x4B0 + port: 0, 0x450 + port: 0, 0x454 + port: 0,
            0x4B4 + port: 6, 0x1A: before[0x1A].int or bit,
            0x46: before[0x46].int or bit}.toTable
          for offset, value in configuration:
            changes[0x4D8 + offset] = value
            changes[state + offset] = value
          if entry in [0x1170, 0x1176]: changes[0x4B2] = (if port == 2: 0 else: 1)
          spc.guard(before, changes, [0x1EA, 0x1EB])
          if entry in [0x1170, 0x1176]: doAssert spc.word(0x17C5) == 0x7123
          doAssert spc.a.int == (if marked: 1 else: 6) and spc.x.int == port and spc.y == 7
          inc result
  for command in 0 .. 255:
    spc.prepare(command)
    spc.ram[0x4B0] = command.uint8
    spc.ram[0x4B4] = 0
    spc.ram[0x4D0] = 0
    spc.putWord(0x24, 0x6000)
    let before = spc.ram[]
    doAssert spc.execute(0x1184).len == 0
    spc.guard(before, {0x2A: 0x60, 0x2B: 4, 0x20: 0, 0x21: 0x40,
      0x4D6: 0xEF, 0x4D7: 0x10, 0x4DF: 8, 0x4D5: 0x40,
      0x2D: command, 0x2E: 0, 0x2F: 0}.toTable)
    doAssert spc.word(0x24) == 0x6000 and spc.x == 0 and spc.y == 0x10
    inc result
  for command in [1, 129]:
    spc.prepare(command)
    spc.ram[0x4B0] = command.uint8
    spc.ram[0x4D0] = 255
    spc.putWord(0x24, 0x6000) # Caller-supplied lookup pointer, not set by1184.
    spc.putWord(0x6000, 0x7003)
    spc.putWord(0x180D, 0x7003) # One proven native pointer-table slot.
    spc.putWord(0x7000, 0x148A)
    spc.ram[0x7002] = 8
    # Tiny authored record/program: JMP1663, not a patched original RET.
    for index, value in [0x5F, 0x63, 0x16]: spc.ram[0x7003 + index] = value.uint8
    doAssert spc.execute(0x1184).len == 0
    doAssert spc.ram[0x4B0].int == command and spc.ram[0x2D].int == command
    doAssert spc.ram[0x50] == 0x14 and spc.word(0x440) == 0x148A
    doAssert spc.word(0x24) == 0x6001 and spc.ram[0x48C] == 8
    doAssert spc.a == 0x14 and spc.x == 0 and spc.y == 0
    inc result

proc checkStreamEdges(spc: var Spc): int =
  ## Prove shared-RET, byte-index wrap and the E0 operand-wrap fallthrough causally.
  spc.installCurves()
  for port in 0 .. 3:
    spc.prepareStream(port, 0x6000, 10, 0x35, 0)
    spc.ram[0x4B8 + port] = 0
    spc.ram[0x450 + port] = 1
    spc.ram[0x454 + port] = 0
    spc.ram[0x4C8 + port] = 1
    spc.ram[0xD0 + port] = 77
    let before = spc.ram[]
    doAssert spc.execute(0xFB7, 0xFB6).len == 0
    spc.guard(before, {0x4B8 + port: 1}.toTable)
    doAssert spc.sp == 0xEF and spc.a == 1 and (spc.psw and PswZ) == 0
    spc.step() # The original shared RET consumes the original native caller frame.
    doAssert spc.pc == ReturnAddress and spc.sp == 0xF1
    inc result
    for cursor in 0 .. 255:
      for first in [0xC9, 0x7F]:
        spc.prepareStream(port, 0x6000, 10, 0x35, 255)
        spc.ram[0xD0 + port] = cursor.uint8
        let offset = (cursor + 6) and 255
        spc.ram[0x6000 + offset] = first.uint8
        spc.ram[0x6000 + ((offset + 1) and 255)] = 0xC9
        let before = spc.ram[]
        doAssert spc.execute(0xFB7, minimumSp=0xE9).len == 0
        doAssert spc.ram[0xD0 + port].int == ((cursor + (if first == 0x7F: 2 else: 1)) and 255)
        doAssert spc.ram[0x4C8 + port] == 0xC9
        if first == 0x7F:
          doAssert spc.ram[0x4BC + port] == 4 and spc.ram[0x4C0 + port] == 2
          doAssert spc.ram[0x46] == (before[0x46] or before[0x4D7])
        inc result
    for inhibit in [0, 255]:
      let channel = 8 + 2 * port
      spc.prepareStream(port, 0x6000, 10, 0x35, inhibit)
      spc.ram[0xD0 + port] = 254
      for index, value in [0xE0, 1, 0xC9, 0xC9]: spc.ram[0x6004 + index] = value.uint8
      let record = [0x35, 0xA6, 0x73, 0x25, 0x01, 0]
      for index, value in record: spc.ram[0x6E06 + index] = value.uint8
      var expected: seq[PortWrite]
      for index in 0 .. 3: expected.addDsp(channel * 8 + 4 + index, record[index])
      for write in panWrites(channel, 156, 0xC9, 9, 0, inhibit): expected.add write
      doAssert spc.execute(0xFB7, budget=500, minimumSp=0xE9) == expected
      doAssert spc.ram[0xD0 + port] == 2 and spc.ram[0x4C8 + port] == 0xC9
      doAssert spc.ram[0x4DB] == 156 and spc.ram[0x4DC] == 0xC9
      doAssert spc.ram[0x47] == 0 # Instrument's actual mask reaches fallthrough stereo.
      inc result

proc checkCompleteZero(spc: var Spc): int =
  ## Let zero tokens execute real1491 reset/stereo/instrument tails with authored state.
  spc.installCurves()
  for port in 0 .. 3:
    for inhibit in [0, 255]:
      for oldMask in [0, 255]:
        for gain in [0, 156, 255]:
          for phase in [0, 0xC0]:
            let
              channel = 8 + 2 * port
              bit = 1 shl (channel div 2)
              mask = 255 xor bit
              finalInhibit = inhibit and mask
              finalMask = oldMask or bit
              unguarded = (finalMask and finalInhibit) == 0
            spc.prepareStream(port, 0x6000, 10, 0x35, inhibit)
            spc.ram[0x6006] = 0
            spc.ram[0x47] = oldMask.uint8
            spc.ram[0x4E0 + channel] = gain.uint8
            spc.ram[0x4F0 + channel] = phase.uint8
            spc.ram[0x330 + channel] = 0
            spc.ram[0x331 + channel] = 10
            spc.ram[0x211 + channel] = 3
            let record = [0x35, 0xA6, 0x73, 0x25, 0x12, 0x34]
            for index, value in record: spc.ram[0x6E12 + index] = value.uint8
            let before = spc.ram[]
            var expected = panWrites(channel, gain, phase, 10, finalMask, finalInhibit)
            if unguarded:
              for index in 0 .. 3: expected.addDsp(channel * 8 + 4 + index, record[index])
            doAssert spc.execute(0xFB7, budget=600, minimumSp=0xE9) == expected
            doAssert spc.ram[0x1A].int == finalInhibit and spc.ram[0x47].int == finalMask
            doAssert spc.ram[0x5E] == (before[0x5E] or bit.uint8)
            doAssert spc.ram[0x321 + channel].int == gain and spc.ram[0x351 + channel].int == phase
            doAssert spc.word(0x330 + channel) == 10 * 256
            doAssert spc.ram[0x4B4 + port] == 0 and spc.ram[0x4C8 + port] == 0 and spc.ram[0x48C + port] == 0
            doAssert spc.ram[0x46] == (before[0x46] or bit.uint8)
            doAssert spc.x.int == port and spc.a == spc.ram[0x46]
            doAssert spc.ram[0x211 + channel] == 3
            doAssert spc.word(0x220 + channel) == (if unguarded: 0x1234 else: 0x0100)
            inc result

proc checkPrefixCycle(spc: var Spc): int =
  ## Observe a closed authored timing-prefix cycle without claiming bounded scan termination.
  for port in 0 .. 3:
    spc.prepareStream(port, 0x6000, 10, 0x35, 0)
    for index in 0 .. 255: spc.ram[0x6000 + index] = 1
    doAssert spc.execute(0xFB7, 0x0FCB).len == 0
    # Complete one prefix, then observe the same native state after another256.
    var prefixes = 0
    spc.step()
    while spc.pc != 0x0FCB:
      doAssert prefixes < 200
      spc.step()
      inc prefixes
    let
      memory = spc.ram[]
      oldA = spc.a
      oldX = spc.x
      oldY = spc.y
      oldSp = spc.sp
      oldStatus = spc.psw
    prefixes = 0
    var instructions = 0
    while prefixes < 256:
      spc.step()
      inc instructions
      doAssert instructions < 15000 and spc.sp >= 0xED
      doAssert spc.pc != ReturnAddress and spc.pc != 0x1491
      if spc.pc == 0x0FCB: inc prefixes
    doAssert spc.ram[] == memory
    doAssert spc.a == oldA and spc.x == oldX and spc.y == oldY
    doAssert spc.sp == oldSp and spc.psw == oldStatus
    inc result

proc main() =
  ## Count only executed checks; engineImages fails without a byte-identical user-ROM rebuild.
  var panPitch, parser, edges, finishes, cycles, installs: int
  for image in engineImages("bin/spc_record_parser_extract"):
    var spc = newSpc()
    for index in 0 ..< DriverLength:
      spc.ram[DriverStart + index] = image[DriverMap + DriverStart + index]
    panPitch += spc.checkPanAndPitch()
    parser += spc.checkParser()
    edges += spc.checkStreamEdges()
    finishes += spc.checkCompleteZero()
    cycles += spc.checkPrefixCycle()
    installs += spc.checkInstallAndRoutes()
  echo &"SPC record parser passed: {panPitch} pan/pitch checks, {parser} parser cases, " &
    &"{edges} shared-RET/wrap cases, {finishes} complete zero finishes, " &
    &"{cycles} closed prefix-cycle observations, {installs} installs/routes/port-zero cases " &
    "across original/rebuilt images."

when isMainModule:
  main()
