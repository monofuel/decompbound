## Independently check resident record helpers using authored data and silent port hooks.
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
  StableFlags = PswH or PswV or PswI or PswB or PswP

proc nz(value: int): uint8 =
  ## Derive byte negative/zero flags mathematically.
  if value == 0: PswZ elif value >= 128: PswN else: 0

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

proc execute(spc: var Spc, entry: int, stop = ReturnAddress.int, budget = 200): seq[PortWrite] =
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
    doAssert spc.sp >= 0xEB
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

proc checkReaders(spc: var Spc): int =
  ## Check both readers over every authored payload byte and wrapping source pointers.
  for entry in [0xF2D, 0xF3C]:
    for pointer in [0, 0x6000, 0xFFFC, 0xFFFF]:
      for seed in 0 .. 255:
        spc.prepare(seed)
        let
          count = if entry == 0xF2D: 7 else: 3
          destination = if entry == 0xF2D: 0x4D8 else: 0x4DA
          oldX = spc.x
          status = spc.psw
        for index in 0 ..< count:
          spc.ram[(pointer + index) and 65535] = ((seed + 47 * index) and 255).uint8
        spc.a = (pointer and 255).uint8
        spc.y = (pointer shr 8).uint8
        let before = spc.ram[]
        var changes = {0x20: pointer and 255, 0x21: pointer shr 8}.toTable
        for index in 0 ..< count: changes[destination + index] = (seed + 47 * index) and 255
        doAssert spc.execute(entry).len == 0
        spc.guard(before, changes)
        doAssert spc.a.int == ((seed + 47 * (count - 1)) and 255)
        doAssert spc.x == oldX and spc.y.int == count
        doAssert spc.psw == ((status and StableFlags) or PswC or PswZ)
        inc result

proc checkTiming(spc: var Spc): int =
  ## Use untouched runtime lookup bytes with a host indexing law, including selector zero.
  for selector in 0 .. 255:
    for mask in 0 .. 255:
      spc.prepare(mask)
      spc.ram[0x22] = selector.uint8
      spc.ram[0x46] = mask.uint8
      spc.ram[0x4D7] = (mask xor 0xA5).uint8
      let
        before = spc.ram[]
        oldX = spc.x
        oldY = spc.y
        status = spc.psw
        index = (selector - 1) and 255
        first = if selector == 127: 4 else: before[0x1068 + index].int
        second = if selector == 127: 2 else: before[0x1068 + ((index + 1) and 255)].int
      var changes = {0x4D8: first, 0x4D9: second}.toTable
      if selector == 127: changes[0x46] = mask or (mask xor 0xA5)
      doAssert spc.execute(0xFA1).len == 0
      spc.guard(before, changes)
      doAssert spc.a.int == second and spc.x == oldX
      doAssert spc.y.int == (if selector == 127: oldY.int else: (index + 1) and 255)
      doAssert spc.psw == ((status and StableFlags) or nz(second) or
        (if selector >= 127: PswC else: 0'u8))
      inc result

proc checkReaderAliases(spc: var Spc): int =
  ## Predict scratch overlays and forward-overlap propagation from the initial source period.
  for entry in [0xF2D, 0xF3C]:
    let
      count = if entry == 0xF2D: 7 else: 3
      destination = if entry == 0xF2D: 0x4D8 else: 0x4DA
    for pointer in [0x20, 0x21, destination - 2, destination - 1,
        destination, destination + 1]:
      for seed in 0 .. 255:
        spc.prepare(seed)
        spc.a = (pointer and 255).uint8
        spc.y = (pointer shr 8).uint8
        let
          before = spc.ram[]
          status = spc.psw
          oldX = spc.x
          period = destination - pointer
        var changes = {0x20: pointer and 255, 0x21: pointer shr 8}.toTable
        for index in 0 ..< count:
          let source = pointer + (if period > 0 and period < count: index mod period else: index)
          changes[destination + index] = if source == 0x20: pointer and 255
            elif source == 0x21: pointer shr 8 else: before[source].int
        doAssert spc.execute(entry).len == 0
        spc.guard(before, changes)
        doAssert spc.a.int == changes[destination + count - 1]
        doAssert spc.x == oldX and spc.y.int == count
        doAssert spc.psw == ((status and StableFlags) or PswC or PswZ)
        inc result

proc checkPositionAndRetarget(spc: var Spc): int =
  ## Exhaust pointer words for independent port slots and copied prefix destinations.
  for value in 0 .. 65535:
    let port = value and 3
    spc.prepare(value and 255)
    spc.a = (value and 255).uint8
    spc.y = (value shr 8).uint8
    spc.ram[0x2E] = port.uint8
    spc.ram[0x2F] = (2 * ((port + 1) and 3)).uint8 # Explicit mismatch proof.
    let
      before = spc.ram[]
      status = spc.psw
      slot = spc.ram[0x2F].int
      changes = {0x458 + slot: value and 255, 0x459 + slot: value shr 8,
        0x454 + port: 1}.toTable
    doAssert spc.execute(0x10FC).len == 0
    spc.guard(before, changes)
    doAssert spc.a == 1 and spc.x.int == port and spc.y.int == value shr 8
    doAssert spc.psw == ((status and not (PswN or PswZ)))
    inc result
  for pointer in [0, 1, 2, 0x6003, 65535]:
    for value in 0 .. 65535:
      spc.prepare(value and 255)
      spc.putWord(0x20, pointer)
      spc.putWord(pointer - 3, value)
      let
        before = spc.ram[]
        oldY = spc.y
        status = spc.psw
      doAssert spc.execute(0x1152).len == 0
      spc.guard(before, {0x4B2: 1}.toTable)
      doAssert spc.word(0x20) == pointer and spc.word(0x17C5) == value
      doAssert spc.a == 1 and spc.x == 0 and spc.y == oldY
      doAssert spc.psw == ((status and not (PswN or PswZ)) or
        (if pointer == 0: PswZ elif pointer >= 32768: PswN else: 0'u8))
      inc result

proc addDsp(writes: var seq[PortWrite], register, value: int) =
  ## Specify ordered hardware writes without constructing an audio device.
  writes.add (0xF2'u16, register.uint8)
  writes.add (0xF3'u16, value.uint8)

proc checkRetargetAliases(spc: var Spc): int =
  ## Predict read-time scratch values and the destination high-to-low write hazard.
  for pointer in [0x20, 0x21, 0x22, 0x23, 0x24, 0x17C7, 0x17C8, 0x17C9, 0x17CA]:
    for seed in 0 .. 255:
      spc.prepare(seed)
      spc.putWord(pointer - 3, seed or ((seed xor 0xA5) shl 8))
      spc.putWord(0x20, pointer)
      let
        before = spc.ram[]
        status = spc.psw
        oldY = spc.y
        highSource = pointer - 2
        lowSource = pointer - 3
        high = if highSource == 0x20: (pointer - 2) and 255
          elif highSource == 0x21: (pointer - 2) shr 8 else: before[highSource].int
        low = if lowSource == 0x20: (pointer - 3) and 255
          elif lowSource == 0x21: (pointer - 3) shr 8
          elif lowSource == 0x17C6: high else: before[lowSource].int
      doAssert spc.execute(0x1152).len == 0
      spc.guard(before, {0x4B2: 1}.toTable)
      doAssert spc.word(0x17C5) == (low or (high shl 8))
      doAssert spc.word(0x20) == pointer and spc.a == 1 and spc.x == 0 and spc.y == oldY
      doAssert spc.psw == (status and not (PswN or PswZ))
      inc result

proc checkWriters(spc: var Spc): int =
  ## Exhaust every register base/value pair, including wrap and inherited-carry cases.
  for entry in [0x110D, 0x1124, 0x1144]:
    for base in 0 .. 255:
      for value in 0 .. 255:
        spc.prepare(value)
        spc.ram[0x4D5] = base.uint8
        spc.ram[0x1A] = 255
        spc.ram[0x1B] = 255
        spc.ram[0x47] = 255
        let
          before = spc.ram[]
          oldX = spc.x
          oldY = spc.y.int
          status = spc.psw
          addend = if entry == 0x110D: 5 else: 7
          sum = base + addend
          register = if entry == 0x1144: (base + 1) and 255 else: sum and 255
        var
          expected: seq[PortWrite]
          changes = initTable[int, int]()
        if entry == 0x110D:
          expected.addDsp((base + 5) and 255, value)
          expected.addDsp(register + 1 and 255, oldY)
          changes[0x20] = register
        elif entry == 0x1124: expected.addDsp(register, value)
        else:
          expected.addDsp(base, value)
          expected.addDsp(register, value)
        doAssert spc.execute(entry) == expected
        spc.guard(before, changes)
        doAssert spc.x == oldX
        doAssert spc.a.int == (if entry == 0x110D: oldY else: value)
        doAssert spc.y.int == (if entry == 0x110D: (register + 1) and 255 else: register)
        let flags = if entry == 0x1144: (status and not (PswN or PswZ)) or nz(register)
          else: (status and (PswP or PswI or PswB)) or
            nz(if entry == 0x110D: (register + 1) and 255 else: register) or
            (if sum >= 256: PswC else: 0'u8) or
            (if (base and 15) + addend >= 16: PswH else: 0'u8) or
            (if base < 128 and (sum and 255) >= 128: PswV else: 0'u8)
        doAssert spc.psw == flags
        inc result

proc checkInstruments(spc: var Spc): int =
  ## Feed authored six-byte instrument records through the actual unguarded interior call.
  for channel in countup(0, 14, 2):
    for operand in 0 .. 255:
      for noise in [false, true]:
        spc.prepare(operand)
        spc.ram[0x4DF] = channel.uint8
        spc.ram[0x4D6] = (255 xor (1 shl (channel div 2))).uint8
        spc.ram[0x49] = 255
        spc.ram[0x48] = 0xA0
        spc.ram[0x1A] = 255
        spc.ram[0x1B] = 255
        spc.ram[0x5F] = 37
        let
          index = if operand < 128: operand else: (operand - 0xCA + 37) and 255
          pointer = 0x6E00 + 6 * index
          sample = if noise: 0x80 or (operand and 31) else: operand and 127
          record = [sample, 0xA6, operand xor 0xC5, 0x73, 0x12, 0x34]
        for offset, value in record: spc.ram[pointer + offset] = value.uint8
        let before = spc.ram[]
        var
          expected: seq[PortWrite]
          changes = {0x49: spc.ram[0x4D6].int, 0x47: 0,
            0x14: pointer and 255, 0x15: pointer shr 8,
            0x220 + channel: 0x34, 0x221 + channel: 0x12}.toTable
        if noise: changes[0x48] = 0x20 or (operand and 31)
        for register in 0 .. 3:
          expected.addDsp(channel * 8 + 4 + register,
            if register == 0 and noise: 0 else: record[register])
        doAssert spc.execute(0x1130) == expected
        spc.guard(before, changes)
        doAssert spc.a == 0x34 and spc.y == 5 and spc.x.int == channel
        doAssert (spc.psw and (PswC or PswN or PswZ)) == PswC
        inc result

proc main() =
  ## Require fresh byte-identical images; count only completed behavior checks.
  var readers, timing, positions, writers, instruments: int
  for image in engineImages("bin/spc_record_interpreter_extract"):
    var spc = newSpc()
    for index in 0 ..< DriverLength:
      spc.ram[DriverStart + index] = image[DriverMap + DriverStart + index]
    readers += spc.checkReaders()
    readers += spc.checkReaderAliases()
    timing += spc.checkTiming()
    positions += spc.checkPositionAndRetarget()
    positions += spc.checkRetargetAliases()
    writers += spc.checkWriters()
    instruments += spc.checkInstruments()
  echo &"SPC record helpers passed: {readers} readers, {timing} timings, " &
    &"{positions} positions/retargets, {writers} DSP writers, {instruments} instrument calls " &
    "across original/rebuilt images."

when isMainModule:
  main()
