## Bounded host-service lookup/native/continuation behavior, independent of source assembly.
## External record routes $126D..12C6 remain unclaimed; unsafe kind targets are not run.
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
  PointerTables = [0x180D, 0x17D5, 0x17C5, 0x16C7]
  NativeFixture = 0x7003
  StableFlags = PswH or PswV or PswI or PswB or PswP

proc nz(value: int): uint8 =
  ## Express byte negative/zero status without consulting the CPU implementation.
  (if value == 0: PswZ elif value >= 128: PswN else: 0'u8)

proc word(spc: Spc, address: int): int =
  ## Read a wrapping little-endian word from fixture/runtime memory.
  spc.ram[address and 65535].int or (spc.ram[(address + 1) and 65535].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Write a tiny authored pointer, including wrapping boundaries.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address + 1) and 65535] = (value shr 8).uint8

proc prepare(spc: var Spc, port, seed: int) =
  ## Guard scratch/channel state and arrange an external native caller frame.
  for address in 0 .. 0x4FF:
    spc.ram[address] = ((address * 37 + seed * 19 + 113) and 255).uint8
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.sp = 0xEF
  spc.x = port.uint8
  spc.a = 0xA6
  spc.y = 0xC5
  spc.psw = if (seed and 1) == 0: 0 else: 0xDF
  spc.ram[0x2E] = port.uint8
  spc.ram[0x2F] = (port * 2).uint8
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected hardware read ${address:04X}"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, &"unexpected hardware write ${address:04X}"
    true

proc execute(spc: var Spc, entry, stop: int, budget = 120) =
  ## Execute original instructions until a defined local handoff or real RET.
  spc.pc = entry.uint16
  var instructions = 0
  while spc.pc.int != stop:
    doAssert instructions < budget, &"entry ${entry:04X} PC ${spc.pc:04X}"
    doAssert spc.sp >= 0xED and spc.sp <= 0xF1
    spc.step()
    inc instructions
  doAssert spc.word(0x1F0) == ReturnAddress.int

proc guard(spc: Spc, before: array[0x10000, uint8], changes: Table[int, int],
           scratch: openArray[int] = []) =
  ## Check named outputs and all unrelated low-memory/stack neighbors.
  for address in 0 .. 0x4FF:
    if address in scratch or address in 0x1EE .. 0x1EF: continue
    let expected = if changes.hasKey(address): changes[address].uint8 else: before[address]
    doAssert spc.ram[address] == expected, &"RAM ${address:04X}={spc.ram[address]} expected{expected}"

proc checkAdapters(spc: var Spc): int =
  ## Exhaust masked input bytes with disabled lookup/continuation and phase-byte edges.
  for port in 1 .. 3:
    for pending in 0 .. 255:
      for feedback in [0, 1, 127, 128, 255]:
        spc.prepare(port, pending)
        spc.ram[0x4B0 + port] = pending.uint8
        spc.ram[0x4B4 + port] = 0
        spc.ram[0x4D0 + port] = 0 # Exclusive capacity zero accepts no new command.
        spc.ram[0x19] = feedback.uint8
        let
          before = spc.ram[]
          oldFeedbackRecords = [spc.ram[0x18EF], spc.ram[0x18F7], spc.ram[0x18FF]]
          channel = 8 + 2 * port
          parameterBase = 0x40 + 16 * port
          state = 0x460 + 8 * port
          mask = 255 xor (1 shl (port + 4))
          changes = {0x4B0 + port: pending and 127,
            0x24: PointerTables[port] and 255, 0x25: PointerTables[port] shr 8,
            0x2A: state and 255, 0x2B: state shr 8,
            0x4D6: mask, 0x4D7: 1 shl (port + 4),
            0x4DF: channel, 0x4D5: parameterBase,
            0x2E: port, 0x2F: port * 2, 0x2D: pending and 127, 0x20: 0,
            0x21: parameterBase}.toTable
        spc.execute([0x1198, 0x11BA, 0x11DC][port - 1], ReturnAddress.int)
        spc.guard(before, changes)
        if port == 3:
          for address in [0x18EF, 0x18F7, 0x18FF]: doAssert spc.ram[address].int == feedback
        else:
          doAssert [spc.ram[0x18EF], spc.ram[0x18F7], spc.ram[0x18FF]] == oldFeedbackRecords
        doAssert spc.a == 0 and spc.x.int == port and spc.y.int == (1 shl (port + 4))
        doAssert spc.sp == 0xF1 and (spc.psw and PswZ) != 0
        inc result

proc checkLookup(spc: var Spc): int =
  ## Check unsigned capacity/offset arithmetic independently using authored pointer records.
  for port in 0 .. 3:
    for command in 0 .. 255:
      for capacity in [0, 1, 2, 127, 128, 254, 255]:
        spc.prepare(port, command)
        spc.ram[0x4B0 + port] = command.uint8
        spc.ram[0x4B4 + port] = 0
        spc.ram[0x4D0 + port] = capacity.uint8
        spc.putWord(0x24, 0x6000)
        spc.ram[0x20] = 10
        spc.ram[0x21] = 0x50
        let
          offset = ((command - 1) * 2) and 255
          accepted = command != 0 and command < capacity
        spc.putWord(0x6000 + offset, NativeFixture)
        spc.ram[NativeFixture - 1] = 8
        let
          before = spc.ram[]
          initialFlags = spc.psw
        spc.execute(0x1207, if accepted: 0x1258 else: ReturnAddress.int)
        var changes = {0x4D6: 0xA6, 0x4D7: 0xC5, 0x4DF: 10, 0x4D5: 0x50,
          0x2E: port, 0x2F: 2 * port, 0x2D: command}.toTable
        if accepted:
          changes[0x20] = NativeFixture and 255
          changes[0x21] = NativeFixture shr 8
          changes[0x24] = 1
          changes[0x48C + port] = 8
          spc.guard(before, changes)
          doAssert spc.word(0x20) == NativeFixture
          doAssert spc.word(0x24) == 0x6001
          doAssert spc.ram[0x2D].int == command and spc.ram[0x48C + port] == 8
          doAssert spc.a == 8 and spc.x == 8 and spc.y.int == offset
          doAssert spc.sp == 0xEE and spc.ram[0x1EF].int == offset
          doAssert ((spc.psw and PswC) != 0) == (command >= 129)
          doAssert (spc.psw and (PswN or PswZ)) == 0
          doAssert spc.psw == ((initialFlags and StableFlags) or
            (if command >= 129: PswC else: 0'u8))
          spc.step()
          doAssert spc.pc == 0x12C7
        else:
          changes[0x20] = 0
          spc.guard(before, changes)
          doAssert spc.ram[0x48C + port] == before[0x48C + port]
          doAssert spc.sp == 0xF1
          doAssert spc.a == 0 and spc.x.int == port and spc.y == 0xC5
          doAssert ((spc.psw and PswC) != 0) == (command != 0)
          doAssert (spc.psw and (PswN or PswZ)) == PswZ
          doAssert spc.psw == ((initialFlags and StableFlags) or PswZ or
            (if command != 0: PswC else: 0'u8))
        inc result

proc checkRawKinds(spc: var Spc): int =
  ## Demonstrate unchecked kind bytes/unaligned table reads without running unsafe targets.
  for pointer in [0, 1, NativeFixture, 65535]:
    for kind in 0 .. 255:
      spc.prepare(1, kind)
      spc.ram[0x4B1] = 1
      spc.ram[0x4D1] = 2
      spc.putWord(0x24, 0x6000)
      spc.putWord(0x6000, pointer)
      spc.ram[(pointer - 1) and 65535] = kind.uint8
      let initialFlags = spc.psw
      spc.execute(0x1207, 0x1258)
      doAssert spc.word(0x20) == pointer and spc.ram[0x48D].int == kind
      let target = spc.word(0x125B + kind)
      spc.step()
      doAssert spc.pc.int == target and spc.sp == 0xEE
      doAssert spc.psw == ((initialFlags and StableFlags) or nz(kind))
      inc result
  for base in [0xFFFE, 0xFFFF]:
    spc.prepare(1, base and 255)
    spc.ram[0x4B1] = 1
    spc.ram[0x4D1] = 2
    spc.putWord(0x24, base)
    spc.putWord(base, NativeFixture)
    spc.ram[NativeFixture - 1] = 8
    spc.execute(0x1207, 0x1258)
    doAssert spc.word(0x20) == NativeFixture
    doAssert spc.word(0x24) == ((base + 1) and 65535)
    inc result

proc checkNative(spc: var Spc): int =
  ## Run tiny authored JMP-to-original-handler records and preserve the external frame.
  for port in 0 .. 3:
    for high in 0 .. 255:
      let
        continuation = (high shl 8) or (high xor 0xA5)
        pointer = [0, 1, NativeFixture, 65535][high and 3]
      spc.prepare(port, high)
      spc.putWord(0x20, pointer)
      spc.putWord(PointerTables[port], pointer) # One proven pointer-table slot only.
      spc.putWord(pointer - 3, continuation)
      spc.ram[(pointer - 1) and 65535] = 8
      # Authored native fixture: JMP $1663. It is not a patched driver RET.
      spc.ram[pointer] = 0x5F
      spc.ram[(pointer + 1) and 65535] = 0x63
      spc.ram[(pointer + 2) and 65535] = 0x16
      spc.sp = 0xEE
      spc.ram[0x1EF] = 0 # Saved pointer-table byte offset, consumed by POP X.
      spc.y = 0
      let before = spc.ram[]
      spc.execute(0x12C7, ReturnAddress.int)
      let changes = {0x20: (pointer - 3) and 255,
        0x21: ((pointer - 3) and 65535) shr 8,
        0x22: continuation and 255, 0x23: high,
        0x440 + 2 * port: continuation and 255,
        0x441 + 2 * port: high, 0x50: high}.toTable
      spc.guard(before, changes)
      doAssert spc.a.int == high and spc.x == 0 and spc.y == 0 and spc.sp == 0xF1
      doAssert ((spc.psw and PswC) != 0) == (port != 0)
      doAssert ((spc.psw and PswN) != 0) == (high >= 128)
      doAssert ((spc.psw and PswZ) != 0) == (high == 0)
      doAssert (spc.psw and (PswH or PswV or PswI or PswB or PswP)) ==
        (if (high and 1) == 0: 0'u8 else: 0xDF'u8 and (PswH or PswV or PswI or PswB or PswP))
      inc result
  for port in 1 .. 3:
    for continuation in [0, 0x148A, 65535]:
      spc.prepare(port, continuation and 255)
      spc.ram[0x4B0 + port] = 1
      spc.ram[0x4D0 + port] = 2
      spc.putWord(PointerTables[port], NativeFixture)
      spc.putWord(NativeFixture - 3, continuation)
      spc.ram[NativeFixture - 1] = 8
      # Complete adapter-to-authored-record chain; original driver code is intact.
      spc.ram[NativeFixture] = 0x5F # JMP $1663: global pitch-offset setter.
      spc.ram[NativeFixture + 1] = 0x63
      spc.ram[NativeFixture + 2] = 0x16
      spc.execute([0x1198, 0x11BA, 0x11DC][port - 1], ReturnAddress.int)
      doAssert spc.ram[0x50].int == (continuation shr 8)
      doAssert spc.word(0x440 + 2 * port) == continuation
      doAssert spc.ram[0x48C + port] == 8 and spc.word(0x20) == NativeFixture - 3
      doAssert spc.a.int == (continuation shr 8) and spc.x == 0 and spc.y == 0
      doAssert spc.sp == 0xF1 and spc.word(0x1F0) == ReturnAddress.int
      inc result

proc checkContinuations(spc: var Spc): int =
  ## Verify continuation gates, native RET routing and unchecked cached-kind reads.
  for port in 0 .. 3:
    for command in 0 .. 255:
      for capacity in [0, 1, 2, 127, 128, 254, 255]:
        spc.prepare(port, command)
        spc.ram[0x4B4 + port] = command.uint8
        spc.ram[0x4D0 + port] = capacity.uint8
        spc.ram[0x48C + port] = 8
        spc.putWord(0x440 + 2 * port, 0x148A) # Original single RET, never patched.
        let
          before = spc.ram[]
          accepted = command != 0 and command < capacity
          initialFlags = spc.psw
        spc.execute(0x131A, ReturnAddress.int)
        spc.guard(before, {0x20: command}.toTable)
        doAssert spc.x.int == (if accepted: 2 * port else: port)
        doAssert spc.a.int == (if accepted: 8 else: command)
        doAssert spc.y == 0xC5
        let expectedFlags = (initialFlags and StableFlags) or
          (if accepted: nz(2 * port)
           elif command == 0: PswZ
           else: nz((command - capacity) and 255) or PswC)
        doAssert spc.psw == expectedFlags
        doAssert spc.sp == 0xF1
        inc result
  for port in 0 .. 3:
    for status in [0'u8, 0xDF]:
      spc.prepare(port, 0)
      spc.psw = status
      spc.ram[0x4B4 + port] = 0
      let before = spc.ram[]
      spc.execute(0x131A, ReturnAddress.int)
      spc.guard(before, {0x20: 0}.toTable)
      doAssert spc.psw == ((status and (StableFlags or PswC)) or PswZ)
      doAssert spc.a == 0 and spc.x.int == port and spc.y == 0xC5
      inc result
  for kind in 0 .. 255:
    spc.prepare(1, kind)
    spc.ram[0x4B5] = 1
    spc.ram[0x4D1] = 2
    spc.ram[0x48D] = kind.uint8
    spc.execute(0x131A, 0x132A)
    let target = spc.word(0x132E + kind)
    spc.step()
    doAssert spc.pc.int == target and spc.sp == 0xEF
    inc result

proc checkRuntimeNative(spc: var Spc, rom: seq[uint8]): int =
  ## Execute unmodified native records 5/6/7/8 separately from authored fixtures.
  for command in [5, 6, 7, 8]:
    for tempo in [0, 1, 127, 128, 254, 255]:
      for seed in [0, 1, 126, 255]:
        for index in 0 ..< DriverLength:
          spc.ram[DriverStart + index] = rom[DriverMap + DriverStart + index]
        spc.prepare(1, seed)
        spc.ram[0x4B1] = command.uint8
        spc.ram[0x4D1] = 29
        spc.ram[0x53] = tempo.uint8
        let
          offset = 2 * (command - 1)
          pointer = spc.word(0x17D5 + offset)
          continuation = spc.word(pointer - 3)
          before = spc.ram[]
        doAssert spc.ram[pointer - 1] == 8 and continuation == 0x148A
        spc.execute(0x1198, ReturnAddress.int)
        doAssert spc.x.int == offset and spc.sp == 0xF1
        doAssert spc.word(0x442) == continuation and spc.ram[0x48D] == 8
        case command
        of 5:
          doAssert pointer == 0x2DC6
          doAssert spc.ram[0x438] == 0x70 and spc.ram[0x50] == 0x0E
          doAssert spc.ram[0x493].int == tempo and spc.word(0x52) == 0xC800
          doAssert spc.a == 0 and spc.y == 0xC8
        of 6:
          doAssert pointer == 0x148A and spc.a == 0x14 and spc.y.int == offset
        of 7:
          doAssert pointer == 0x2DED and spc.ram[0x43A] == 0x28
          doAssert spc.a == 0x28 and spc.y.int == offset
        of 8:
          doAssert pointer == 0x2E0B and spc.ram[0x439] == 0x69
          doAssert spc.a == 0x69 and spc.y.int == offset
        else: doAssert false
        var changes = {0x20: (pointer - 3) and 255, 0x21: (pointer - 3) shr 8,
          0x22: continuation and 255, 0x23: continuation shr 8,
          0x24: 0xD6, 0x25: 0x17, 0x2A: 0x68, 0x2B: 4,
          0x2D: command, 0x2E: 1, 0x2F: 2,
          0x4D6: 0xDF, 0x4D7: 0x20, 0x4DF: 10, 0x4D5: 0x50,
          0x48D: 8, 0x442: continuation and 255, 0x443: continuation shr 8}.toTable
        if command == 5:
          changes[0x438] = 0x70; changes[0x50] = 0x0E
          changes[0x493] = tempo; changes[0x52] = 0; changes[0x53] = 0xC8
        elif command == 7: changes[0x43A] = 0x28
        elif command == 8: changes[0x439] = 0x69
        spc.guard(before, changes)
        # Each arm preserves pending tempo/master fades and all live stream cursors.
        for address in 0x54 .. 0x5D: doAssert spc.ram[address] == before[address]
        for address in 0x30 .. 0x3F: doAssert spc.ram[address] == before[address]
        inc result

proc checkServicePasses(image: seq[uint8]): int =
  ## Preserve actual native-arm outputs into a second complete original service pass.
  for command in [5, 6, 7, 8]:
    for tempo in [0, 1, 128, 255]:
      var spc = newSpc()
      for index in 0 ..< DriverLength:
        spc.ram[DriverStart + index] = image[DriverMap + DriverStart + index]
      for address in 0x1E8 .. 0x1F2: spc.ram[address] = 0xA5
      spc.ram[0x1EF] = 7 # Pending timer byte above real nested CALL frames.
      spc.sp = 0xEE
      spc.psw = 0xDF
      spc.ram[0x4B1] = command.uint8
      spc.ram[0x4D1] = 29 # Authored capacity: allow known native records only.
      spc.ram[0x53] = tempo.uint8
      spc.ram[0x59] = 0xA3
      spc.ram[0x19] = 0x55
      let
        nativeEntry = [0x2DC6, 0x148A, 0x2DED, 0x2E0B][command - 5]
        liveGuard = spc.ram[0x200 .. 0x3FF]
      var
        reads: seq[uint16]
        writes: seq[PortWrite]
      spc.readHook = proc(address: uint16): int =
        doAssert address in [0xF5'u16, 0xF6, 0xF7]
        reads.add address
        0 # Stable authored host input consumes rather than requeues the command.
      spc.writeHook = proc(address: uint16, value: uint8): bool =
        writes.add (address, value)
        true
      for pass in 0 .. 1:
        reads.setLen(0)
        writes.setLen(0)
        spc.pc = 0x0596
        var
          instructions = 0
          seenNative = 0
          seenDispatch = 0
        while spc.pc != 0x05C6:
          doAssert instructions < 1000, &"service command{command} PC ${spc.pc:04X}"
          doAssert spc.sp in 0xEA'u8 .. 0xEE'u8
          if spc.pc.int == nativeEntry: inc seenNative
          if spc.pc == 0x1198: inc seenDispatch
          spc.step()
          inc instructions
        doAssert seenDispatch == 1 and seenNative == (if pass == 0: 1 else: 0)
        doAssert reads == @[0xF7'u16, 0xF7, 0xF6, 0xF6, 0xF5, 0xF5]
        doAssert writes == @[(0xF7'u16, 0'u8), (0xF6'u16, 0'u8), (0xF5'u16, 0'u8)]
        doAssert spc.sp == 0xEE and spc.ram[0x1EF] == 7
        doAssert spc.ram[0x1E8] == 0xA5 and spc.ram[0x1F0] == 0xA5
        doAssert spc.ram[0x1F1] == 0xA5 and spc.ram[0x1F2] == 0xA5
        doAssert spc.ram[0x4B1] == 0 and spc.ram[0x4B2] == 0 and spc.ram[0x4B3] == 0
        doAssert spc.ram[0x48D] == 8 and spc.word(0x442) == 0x148A
        doAssert spc.ram[0x200 .. 0x3FF] == liveGuard
        doAssert spc.ram[0x59] == 0xA3
        case command
        of 5:
          doAssert spc.ram[0x438].int == 0x70 - pass and spc.ram[0x50] == 0x0E
          doAssert spc.ram[0x493].int == tempo and spc.word(0x52) == 0xC800
          doAssert spc.ram[0x439] == 0 and spc.ram[0x43A] == 0
        of 6:
          doAssert spc.ram[0x438] == 0 and spc.ram[0x439] == 0 and spc.ram[0x43A] == 0
          doAssert spc.ram[0x53].int == tempo
        of 7:
          doAssert spc.ram[0x43A].int == 0x28 - pass
          doAssert spc.ram[0x438] == 0 and spc.ram[0x439] == 0
          doAssert spc.ram[0x53].int == tempo
        of 8:
          doAssert spc.ram[0x439].int == 0x69 - pass
          doAssert spc.ram[0x438] == 0 and spc.ram[0x43A] == 0
          doAssert spc.ram[0x53].int == tempo
        else: doAssert false
        inc result

proc main() =
  ## Require fresh byte-identical images and count completed bounded behavior checks.
  var adapters, lookups, kinds, native, continuations, runtime, servicePasses: int
  for image in engineImages("bin/spc_service_dispatch_extract"):
    var spc = newSpc()
    for index in 0 ..< DriverLength:
      spc.ram[DriverStart + index] = image[DriverMap + DriverStart + index]
    adapters += spc.checkAdapters()
    lookups += spc.checkLookup()
    kinds += spc.checkRawKinds()
    native += spc.checkNative()
    continuations += spc.checkContinuations()
    runtime += spc.checkRuntimeNative(image)
    servicePasses += checkServicePasses(image)
  echo &"SPC service dispatch passed: {adapters} adapters, " &
    &"{lookups} lookups, {kinds} raw kinds/wraps, {native} authored native records, " &
    &"{continuations} continuations, {runtime} untouched runtime-native records, " &
    &"{servicePasses} complete service passes across original/rebuilt images."

when isMainModule:
  main()
