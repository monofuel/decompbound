import
  std/strutils,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x4000'u16
  Retained = PswH or PswV or PswP or PswI or PswB
  Edges = [0, 1, 127, 128, 255]

proc putWord(spc: var Spc, address, value: int) =
  ## Write an authored pointer with sixteen-bit address wrap.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address + 1) and 65535] = (value shr 8).uint8

proc word(spc: Spc, address: int): int =
  ## Read a wrapped little-endian structural word.
  spc.ram[address and 65535].int + 256 * spc.ram[(address + 1) and 65535].int

proc loaded(rom: seq[uint8], port, pointer, seed: int): Spc =
  ## Supply dirty authored state, an accepted lookup's saved byte, and original caller frame.
  result = newSpc()
  for index in 0 ..< DriverLength:
    result.ram[DriverStart + index] = rom[DriverPayload + index]
  for address in 0 .. 0x4FF:
    result.ram[address] = ((address * 37 + seed) and 255).uint8
  for address in (pointer and 0xFF00) .. (pointer and 0xFF00) + 6:
    result.ram[address] = ((address * 11 + seed + 83) and 255).uint8
  result.putWord(0x20, pointer)
  result.putWord(0x2A, 0x5000 + port * 16)
  result.ram[0x2D] = seed.uint8
  result.ram[0x2E] = port.uint8
  result.ram[0x2F] = (2 * port).uint8
  result.ram[0x4D7] = (1 shl (port + 3)).uint8
  result.sp = 0xEE
  result.ram[0x1EF] = 0xA6 # Actual accepted lookup PUSH byte, not another return address.
  result.putWord(0x1F0, ReturnAddress.int)
  result.psw = (if (seed and 1) == 0: Retained and not PswP else: 0)
  result.readHook = proc(address: uint16): int =
    doAssert false, "unexpected record-route hardware read $" & address.toHex(4)
    -1
  result.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, "unexpected record-route hardware write $" & address.toHex(4)
    false

proc runTo(spc: var Spc, stop: uint16, budget = 400) =
  ## Execute unchanged source/callees to the named boundary with a finite budget.
  var steps = 0
  while spc.pc != stop:
    doAssert steps < budget, "record route stalled at $" & spc.pc.toHex(4)
    doAssert spc.sp >= 0xEB
    spc.step()
    inc steps

proc checkBasic(rom: seq[uint8]) =
  ## Predict complete slot state and guarded RAM through real basic-route callees.
  var contexts = 0
  for kind in [0, 2, 4, 6]:
    for port in 0 .. 3:
      for pointer in [0x6000, 0x60FD, 0xFFFE]:
        for seed in Edges:
          for selector in (if kind in [4, 6]: @[0, 1, 2, 126, 127, 128,
              255] else: @[127]):
            for firstToken in [0, 0xC9, 255]:
              var spc = loaded(rom, port, pointer, seed)
              for index in 0 .. 6: spc.ram[(pointer + index) and 65535] = ((
                  seed + index * 19) and 255).uint8
              if kind in [4, 6]:
                spc.ram[(pointer + 4) and 65535] = selector.uint8
                spc.ram[(pointer + 5) and 65535] = firstToken.uint8
              let
                before = spc.ram[]
                entryStatus = spc.psw
              var expected = before
              var state: array[7, uint8]
              for index in 0 .. 6: state[index] = before[(pointer + index) and 65535]
              expected[0x4C8 + port] = 0
              if kind in [4, 6]:
                let
                  selectorIndex = (selector - 1) and 255
                  periodLow = if selector == 127: 4'u8 else: before[0x1068 + selectorIndex]
                  periodHigh = if selector == 127: 2'u8 else: before[0x1068 + ((
                      selectorIndex + 1) and 255)]
                expected[0x4D8] = periodLow
                expected[0x4D9] = periodHigh
                expected[0x4DA] = state[0]
                expected[0x4DB] = state[1]
                expected[0x4DC] = state[2]
                expected[0x4DD] = state[5]
                expected[0x4DE] = state[3]
                expected[0x480 + 2 * port] = (pointer and 255).uint8
                expected[0x481 + 2 * port] = (pointer shr 8).uint8
                expected[0x4C8 + port] = (if firstToken ==
                    0xC9: 0xC9 else: 0).uint8
                let originalState = state
                state = [periodLow, periodHigh, originalState[0], originalState[
                    1], originalState[2], originalState[5], originalState[3]]
              let source = if kind in [4, 6]: 0x4D8 else: pointer
              expected[0x22] = (source and 255).uint8
              expected[0x23] = (source shr 8).uint8
              expected[0x20] = ((0x5000 + port * 16) and 255).uint8
              expected[0x21] = 0x50
              expected[0x4CC + port] = 0
              expected[0x4BC + port] = state[0]
              expected[0x4C0 + port] = state[1]
              for index, value in state: expected[0x5000 + port * 16 + index] = value
              for address in [0x1A, 0x46]: expected[address] = before[
                  address] or before[0x4D7]
              for address in [0x4B8, 0xD0, 0xD4, 0xD8, 0x49C, 0x4B0, 0x450,
                  0x454]: expected[address + port] = 0
              expected[0x4B4 + port] = before[0x2D]
              if kind == 6: expected[0x49C + port] = 1
              spc.pc = (if kind in [0, 2]: 0x1280 elif kind ==
                  4: 0x1270 else: 0x1278).uint16
              spc.runTo(ReturnAddress)
              for address in 0 .. 65535:
                if address notin 0x1EC .. 0x1EF:
                  doAssert spc.ram[address] == expected[address],
                      "basic kind=" & $kind & " pointer=" & $pointer &
                      " seed=" & $seed & " RAM $" & address.toHex(4) & " got=" &
                      $spc.ram[address] & " expected=" & $expected[address]
              let value = if kind == 6: 1 else: before[0x2D].int
              doAssert spc.a.int == value and spc.x.int == port and spc.y ==
                  7 and spc.sp == 0xF1
              doAssert spc.psw.int == ((entryStatus.int and Retained.int) or
                  1 or (value and 128) or (if value == 0: 2 else: 0))
              inc contexts
  echo "complete basic-route contexts=", contexts, "; actual original callees; ordinary and special selectors"

proc checkExtended(rom: seq[uint8]) =
  ## Predict header extraction and full original control/state initialization, including pointer truncation.
  var contexts = 0
  for port in 0 .. 3:
    for pointer in [2, 0x6000, 0x60FD, 0xFFFE]:
      for parameter in Edges:
        for control in [0, 31, 32, 128, 255]:
          var spc = loaded(rom, port, pointer, parameter)
          for index in - 5 .. 6: spc.ram[(pointer + index) and 65535] = ((
              index * 19 + 117) and 255).uint8
          spc.ram[(pointer + 5) and 65535] = parameter.uint8
          spc.ram[(pointer + 6) and 65535] = (parameter xor 0xA3).uint8
          spc.ram[0x48] = control.uint8
          let
            before = spc.ram[]
            entryStatus = spc.psw
            combined = (control and 0xE0) or parameter
            effective = if combined == 0: pointer and 0xFF00 else: pointer
          var expected = before
          for offset in 0 .. 1:
            expected[0x26 + offset] = before[(pointer - 3 + offset) and 65535]
            expected[0x28 + offset] = before[(pointer - 5 + offset) and 65535]
          expected[0x2C] = before[(pointer + 6) and 65535]
          expected[0x24] = parameter.uint8
          expected[0x48] = combined.uint8
          expected[0x4CC + port] = combined.uint8
          expected[0x22] = (effective and 255).uint8
          expected[0x23] = (effective shr 8).uint8
          expected[0x20] = (port * 16).uint8
          expected[0x21] = 0x50
          expected[0x4BC + port] = before[effective]
          expected[0x4C0 + port] = before[(effective + 1) and 65535]
          for index in 0 .. 6: expected[0x5000 + port * 16 + index] = before[(
              effective + index) and 65535]
          for address in [0x1A, 0x46]: expected[address] = before[address] or
              before[0x4D7]
          for address in [0x4B8, 0xD0, 0xD4, 0xD8, 0x49C, 0x4B0,
              0x450]: expected[address + port] = 0
          expected[0x4B4 + port] = before[0x2D]
          expected[0x458 + 2 * port] = 0
          expected[0x459 + 2 * port] = 0
          expected[0x454 + port] = 1
          spc.pc = 0x1288
          spc.runTo(ReturnAddress)
          for address in 0 .. 65535:
            if address notin 0x1E8 .. 0x1EF:
              doAssert spc.ram[address] == expected[address], "extended RAM $" &
                  address.toHex(4)
          doAssert spc.a == 1 and spc.y == 0 and spc.x.int == port and spc.sp == 0xF1
          doAssert spc.psw == ((entryStatus and Retained) or PswC)
          inc contexts
  echo "complete extended-route contexts=", contexts, "; raw control and wrapped header/pointer cases"

proc checkRejected(rom: seq[uint8]) =
  ## Verify the no-PUSH rejection route really executes existing-state continuation and returns.
  var contexts = 0
  for port in 0 .. 3:
    for state in 0 .. 255:
      var spc = loaded(rom, port, 0x6000, state)
      spc.sp = 0xEF
      spc.x = port.uint8
      spc.ram[0x4B4 + port] = state.uint8
      spc.ram[0x4D0 + port] = state.uint8 # Equal capacity rejects every nonzero state.
      spc.pc = 0x126D
      spc.runTo(ReturnAddress, 10)
      doAssert spc.sp == 0xF1 and spc.a.int == state and spc.x.int == port
      doAssert spc.ram[0x20].int == state
      inc contexts
  echo "actual rejected-route return contexts=", contexts

proc checkHandoffs(rom: seq[uint8]) =
  ## Sweep every PSW byte for local tails, stopping before DP-dependent external callees.
  var basic, extended: int
  for status in 0 .. 255:
    let page = if (status and PswP.int) == 0: 0 else: 256
    for high in [0, 1, 127, 128, 255]:
      for (entry, target) in [(0x1270, 0xF56), (0x1278, 0xF4B), (0x1280, 0x14DF)]:
        var spc = loaded(rom, 0, 0x6000, 0)
        let pointer = high * 256 + 0xA3
        spc.putWord(page + 0x20, pointer)
        spc.ram[0x1EF] = (status xor 0xA6).uint8
        spc.pc = entry.uint16
        spc.psw = status.uint8
        spc.runTo(target.uint16, 5)
        let flags = (status and not (PswN or PswZ).int) or (high and 128) or
          (if high == 0: PswZ.int else: 0)
        doAssert spc.a == 0xA3 and spc.y.int == high
        doAssert spc.x.int == (status xor 0xA6) and spc.sp == 0xEF
        doAssert spc.word(0x1F0) == ReturnAddress.int and spc.psw.int == flags
        inc basic
    for pointer in [2, 0x6000, 0x60FD, 0xFFFE]:
      var spc = loaded(rom, 0, 0x6000, 0)
      for index in - 5 .. 6:
        spc.ram[(pointer + index) and 65535] = ((index * 17 + status) and 255).uint8
      spc.putWord(page + 0x20, pointer)
      let before = spc.ram[]
      spc.pc = 0x1288
      spc.psw = status.uint8
      spc.runTo(0x14EE, 40)
      doAssert spc.word(page + 0x20) == pointer
      doAssert spc.word(page + 0x26) == before[(pointer - 3) and 65535].int +
        256 * before[(pointer - 2) and 65535].int
      doAssert spc.word(page + 0x28) == before[(pointer - 5) and 65535].int +
        256 * before[(pointer - 4) and 65535].int
      doAssert spc.ram[page + 0x2C] == before[(pointer + 6) and 65535]
      doAssert spc.x == before[(pointer + 5) and 65535]
      doAssert spc.a.int == (pointer and 255) and spc.y.int == pointer div 256
      doAssert spc.sp == 0xED and spc.word(0x1EE) == 0x12C0
      doAssert spc.word(0x1F0) == ReturnAddress.int
      let high = pointer div 256
      doAssert spc.psw.int == ((status and not (PswN or PswZ).int) or
        (high and 128) or (if high == 0: PswZ.int else: 0))
      inc extended
  echo "local all-PSW handoffs: basic=", basic, " extended=", extended,
    "; page-one stops before external callee execution"

proc checkExtendedAlias(rom: seq[uint8]) =
  ## Check that the first header write becomes the overlapping second header's source.
  var contexts = 0
  for first in [0, 1, 0x2211, 0x4433, 65535]:
    for second in [0, 1, 0x2211, 0x4433, 65535]:
      var spc = loaded(rom, 0, 0x002B, 0)
      spc.putWord(0x26, first)
      spc.putWord(0x28, second)
      spc.ram[0x30] = 0xA7
      spc.ram[0x31] = 0xB8
      spc.pc = 0x1288
      spc.runTo(0x14EE, 40)
      doAssert spc.word(0x26) == second and spc.word(0x28) == second
      doAssert spc.word(0x20) == 0x002B and spc.a == 0x2B and spc.y == 0
      doAssert spc.x == 0xA7 and spc.ram[0x2C] == 0xB8
      doAssert spc.sp == 0xED and spc.word(0x1EE) == 0x12C0
      doAssert spc.word(0x1F0) == ReturnAddress.int
      inc contexts
  echo "extended overlapping-header handoffs=", contexts

proc checkAdapterChains(rom: seq[uint8]) =
  ## Use real port adapters and lookup tables with authored pointers, records and actual callees.
  var contexts = 0
  for port in 1 .. 3:
    for kind in [2, 4, 6, 10, 12, 16]:
      for rawCommand in [1, 7, 8, 127, 129, 255]:
        for selector in [0, 1, 127, 255]:
          let
            command = rawCommand and 127
            pointer = 0x6000
            table = [0, 0x17D5, 0x17C5, 0x16C7][port]
            stateAddress = 0x0460 + port * 8
            token = if (rawCommand and 1) == 0: 0 else: 0xC9
          var spc = loaded(rom, port, pointer, rawCommand)
          spc.sp = 0xEF
          spc.ram[0x4B0 + port] = rawCommand.uint8
          spc.ram[0x4D0 + port] = 128
          spc.ram[0x48] = 0
          spc.putWord(table + 2 * (command - 1), pointer)
          spc.putWord(pointer - 5, 0x1234)
          spc.putWord(pointer - 3, 0x5678)
          spc.ram[pointer - 1] = kind.uint8
          let record = [21'u8, 43, 65, 87, selector.uint8, token.uint8, 109]
          for index, value in record: spc.ram[pointer + index] = value
          var expected = record
          if kind in [4, 6, 10, 12]:
            let
              index = (selector - 1) and 255
              low = if selector == 127: 4'u8 else: spc.ram[0x1068 + index]
              high = if selector == 127: 2'u8 else: spc.ram[0x1068 + ((index +
                  1) and 255)]
            expected = [low, high, record[0], record[1], record[2], record[5],
                record[3]]
          spc.pc = [0, 0x1198, 0x11BA, 0x11DC][port].uint16
          var sawLookup, sawRoute: bool
          var steps = 0
          while spc.pc != ReturnAddress:
            doAssert steps < 400
            if spc.pc == 0x1258: sawLookup = true
            if spc.pc.int in [0x1270, 0x1278, 0x1280, 0x1288]: sawRoute = true
            doAssert spc.sp >= 0xE9
            spc.step()
            inc steps
          doAssert sawLookup and sawRoute and spc.sp == 0xF1
          for index, value in expected:
            doAssert spc.ram[stateAddress + index] == value
          doAssert spc.ram[0x4B4 + port].int == command
          doAssert spc.ram[0x48C + port].int == kind
          doAssert spc.ram[0x49C + port].int == (if kind in [6, 12]: 1 else: 0)
          if kind in [10, 12]: doAssert spc.word(0x17C5) == 0x5678
          if kind == 16:
            doAssert spc.word(0x26) == 0x5678 and spc.word(0x28) == 0x1234
            doAssert spc.word(0x458 + 2 * port) == 0 and spc.ram[0x454 +
                port] == 1
          inc contexts
  echo "actual adapter->lookup->route->callee chains=", contexts,
    "; includes ordinary selectors and kind10/12 preludes"

proc checkRejectedContinuation(rom: seq[uint8]) =
  ## Let rejected new input resume a real native continuation with a visible state effect.
  for port in 0 .. 3:
    var spc = loaded(rom, port, 0x6000, 0)
    spc.sp = 0xEF
    spc.x = port.uint8
    spc.a = 0xD5
    spc.y = 0x80
    spc.ram[0x4B0 + port] = 0
    spc.ram[0x4B4 + port] = 1
    spc.ram[0x4D0 + port] = 2
    spc.ram[0x48C + port] = 8
    spc.putWord(0x440 + 2 * port, 0x1663) # Original global-offset setter, not a patched RET.
    spc.ram[0x50] = 0x91
    spc.pc = 0x1207
    var sawRejected, sawSetter: bool
    var steps = 0
    while spc.pc != ReturnAddress:
      doAssert steps < 70
      if spc.pc == 0x126D:
        sawRejected = true
        doAssert spc.sp == 0xEF
      if spc.pc == 0x1663:
        sawSetter = true
        doAssert spc.sp == 0xEF
      spc.step()
      inc steps
    doAssert sawRejected and sawSetter and spc.ram[0x50] == 8
    doAssert spc.sp == 0xF1
  echo "rejected new lookup->actual saved continuation chains=4"

proc main() =
  ## Require original and fresh byte-identical rebuilt images without audio or patched callees.
  for index, image in engineImages("bin/spc_record_routes_extract"):
    echo "image=", (if index == 0: "original" else: "fresh rebuild")
    checkBasic(image)
    checkExtended(image)
    checkRejected(image)
    checkHandoffs(image)
    checkExtendedAlias(image)
    checkAdapterChains(image)
    checkRejectedContinuation(image)
  echo "SPC record routes passed across both images."

when isMainModule:
  main()
