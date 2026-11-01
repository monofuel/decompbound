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
  ReturnAddress = 0x1E00'u16
  Edges = [0, 1, 127, 128, 255]

proc loaded(rom: seq[uint8]): Spc =
  ## Load original resident code with authored zero state and a native caller frame.
  result = newSpc()
  for index in 0 ..< DriverLength:
    result.ram[DriverStart + index] = rom[DriverPayload + index]
  result.sp = 0xEF
  result.ram[0x1F0] = 0
  result.ram[0x1F1] = 0x1E
  result.readHook = proc(address: uint16): int =
    doAssert false, "unexpected selection I/O read at $" & address.toHex(4)
    -1
  result.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, "unexpected selection I/O write at $" & address.toHex(4)
    false

proc runTo(spc: var Spc, stop: uint16, budget: int) =
  ## Execute unmodified code to a named boundary under a finite instruction budget.
  var steps = 0
  while spc.pc != stop:
    doAssert steps < budget, "budget at $" & spc.pc.toHex(4)
    spc.step()
    inc steps

proc checkSelection(rom: seq[uint8]) =
  ## Check wrapped table mapping from raw selection through the actual shared cursor/key-off tail.
  var spc = loaded(rom)
  for address in 0x2E48 .. 0x3045:
    spc.ram[address] = ((address * 37 + 19) and 255).uint8
  for selection in 0 .. 255:
    for inhibit in 0 .. 255:
      let
        index = if selection < 128: selection * 2 else: (2 * ((selection and 127) + 1)) and 255
        table = (if selection < 128: 0x2E48 else: 0x2F46) + index
        low = spc.ram[table]
        high = spc.ram[table + 1]
        pending = (selection xor inhibit).uint8
      spc.pc = 0x772
      spc.sp = 0xEF
      spc.a = selection.uint8
      spc.y = 0x39
      spc.psw = PswI or PswB or PswH or PswV
      spc.ram[0x1A] = inhibit.uint8
      spc.ram[0x46] = pending
      spc.ram[0x08] = (selection xor 0xC3).uint8
      for address in [0x491,0x4B1,0x4B5]: spc.ram[address] = 0xA7
      spc.runTo(ReturnAddress, 50)
      doAssert spc.ram[4].int == selection and spc.ram[8].int == (selection xor 0xC3)
      doAssert spc.ram[0x40] == low and spc.ram[0x41] == high and spc.ram[0x0C] == 2
      doAssert spc.ram[0x46].int == (pending.int or (inhibit xor 255))
      for address in [0x491,0x4B1,0x4B5]: doAssert spc.ram[address] == 0
      doAssert spc.x.int == index and spc.y == high and spc.sp == 0xF1
      doAssert (spc.psw and (PswI or PswB or PswH or PswV)) == (PswI or PswB)
      doAssert (spc.psw and PswC).int == (if selection == 255: 1 else: 0)
  echo "actual full selection/key-off contexts=65536; all selection/inhibit bytes"

proc checkNegativeEntry(rom: seq[uint8]) =
  ## Check the direct mapper's flags and wrapped word selection before its shared continuation.
  var spc = loaded(rom)
  for selection in 0 .. 255:
    for seed in [0, 255 and not PswP.int]:
      let
        index = (2 * ((selection and 127) + 1)) and 255
        low = spc.ram[0x2F46 + index].int
        high = spc.ram[0x2F47 + index].int
        carry = if selection mod 128 == 127: PswC.int else: 0
        flags = (seed and (PswH or PswV or PswP or PswI or PswB).int) or
          carry or (low and 128) or (if low == 0: PswZ.int else: 0)
      spc.pc = 0x79A
      spc.sp = 0xEF
      spc.a = selection.uint8
      spc.psw = seed.uint8
      spc.runTo(0x782, 10)
      doAssert spc.a.int == low and spc.y.int == high and spc.x.int == index
      doAssert spc.sp == 0xEF and spc.psw.int == flags
  echo "direct negative mapper contexts=512; stop=$0782"

proc checkReset(rom: seq[uint8]) =
  ## Check all eight channels and untouched neighbors using actual pan setters from dirty authored RAM.
  var contexts = 0
  for seed in 0 .. 255:
    for override in Edges:
      var spc = loaded(rom)
      for address in 0 .. 0x4FF:
        spc.ram[address] = ((address * 17 + seed) and 255).uint8
      spc.ram[0x431] = override.uint8
      spc.ram[0x1F0] = 0
      spc.ram[0x1F1] = 0x1E
      spc.psw = PswH or PswV or PswI or PswB
      spc.y = seed.uint8
      spc.pc = 0x7A9
      var expected = spc.ram[]
      for channel in countup(0,14,2):
        expected[0x301 + channel] = 255
        for base in [0x351,0x331]: expected[base + channel] = 10
        for base in [0x330,0x211,0x381,0x2F0,0x280,0x400,0xB1,0xC1]:
          expected[base + channel] = 0
      for address in [0x47,0x5A,0x68,0x54,0x50,0x42,0x5F]: expected[address] = 0
      expected[0x20] = 10 # Actual pan setter's saved operand.
      expected[0x59] = 0xC0
      expected[0x53] = 0x20
      spc.readHook = proc(address:uint16):int =
        doAssert false, "unexpected reset I/O read"
        -1
      spc.writeHook = proc(address:uint16,value:uint8):bool =
        doAssert false, "unexpected reset I/O write"
        false
      spc.runTo(ReturnAddress, 400)
      for address in 0 .. 0x4FF:
        if address notin 0x1EE .. 0x1EF:
          doAssert spc.ram[address] == expected[address], "reset address $" & address.toHex(4)
      doAssert spc.a == 0 and spc.x == 0xFE and spc.y.int == seed and spc.sp == 0xF1
      doAssert spc.psw == (PswH or PswV or PswI or PswB or PswC or PswZ)
      inc contexts
  echo "all-eight-channel dirty reset contexts=", contexts

proc checkGuard(rom: seq[uint8]) =
  ## Stop negative prior selections at the classifier interior without assuming its Y setup.
  var spc = loaded(rom)
  for prior in 0 .. 255:
    for seed in [0,255 and not PswP.int]:
      spc.pc = 0x7F4
      spc.sp = 0xEF
      spc.ram[8] = prior.uint8
      spc.ram[0] = 0x5A
      spc.a = 0x91
      spc.x = 0x37
      spc.y = 0xC6
      spc.psw = seed.uint8
      spc.runTo((if prior >= 128: 0x7FF'u16 else: ReturnAddress), 4)
      doAssert spc.a.int == prior and spc.x == 0x37 and spc.y == 0xC6
      doAssert spc.sp == (if prior >= 128:0xEF'u8 else:0xF1'u8)
      doAssert spc.ram[0] == 0x5A and spc.ram[8].int == prior
      let flags = (seed and not (PswN or PswZ).int) or (prior and 128) or
        (if prior == 0: PswZ.int else:0)
      doAssert spc.psw.int == flags
  echo "prior-selection sign guard contexts=512; negative stop=$07FF"

proc checkPrelude(rom: seq[uint8]) =
  ## Execute original external helpers in idle state, stopping at the selector fall-through.
  var
    spc = loaded(rom)
    writes:seq[PortWrite]
    calls:seq[int]
  spc.pc = 0x75E
  spc.ram[8] = 0xC7
  spc.readHook = proc(address:uint16):int = 0
  spc.writeHook = proc(address:uint16,value:uint8):bool =
    writes.add (address,value)
    true
  var steps = 0
  while spc.pc != 0xEE1:
    doAssert steps < 10000, "prelude budget at $" & spc.pc.toHex(4)
    if spc.pc.int in [0x762,0x765,0x768,0x76B]:
      spc.step()
      calls.add spc.pc.int
    else: spc.step()
    inc steps
  doAssert calls == @[0x749,0x141A,0x1453,0xEE1]
  doAssert spc.sp == 0xED and spc.ram[8] == 0xC7
  doAssert writes.len >= 2 and writes[0] == (0xF2'u16,0x5C'u8) and writes[1] == (0xF3'u16,0xFF'u8)
  for step in 0 ..< 30: spc.step()
  doAssert spc.pc.int in [0xEEB,0xEEE,0xEF0]
  doAssert spc.sp == 0xED and spc.ram[8] == 0xC7
  doAssert (0xF4'u16,0xAA'u8) in writes and (0xF5'u16,0xBB'u8) in writes
  echo "prelude calls=4; stop=$0EE1 after ",steps,
    " steps; actual uploader then waits for host CC (30 bounded instructions)"
  spc = loaded(rom)
  spc.pc = 0x76E
  spc.ram[8] = 0xC7
  spc.ram[4] = 0xA5
  spc.ram[0x1A] = 0x36
  spc.runTo(ReturnAddress, 50)
  doAssert spc.ram[8] == 0 and spc.ram[4] == 0 and spc.ram[0xC] == 2
  doAssert spc.ram[0x46] == (0x36 xor 255).uint8 and spc.sp == 0xF1
  echo "post-helper tail $076E->actual zero selector context=1"
  for selection in 0 .. 255:
    for entry in [0x7E4,0x7E7]:
      spc.pc = entry.uint16
      spc.a = selection.uint8
      spc.sp = 0xEF
      spc.step()
      doAssert spc.pc.int == (if entry == 0x7E4:0x75E else:0x772)
      doAssert spc.a.int == selection and spc.sp == 0xEF
  echo "native-frame-preserving shared JMP tails=512"

proc main() =
  ## Require original and independently rebuilt images with no audio device or patched code.
  for index, image in engineImages("bin/spc_sequence_selection_extract"):
    echo "image=", (if index == 0: "original" else: "fresh rebuild")
    checkSelection(image)
    checkNegativeEntry(image)
    checkReset(image)
    checkGuard(image)
    checkPrelude(image)
  echo "SPC sequence selection passed across both images."

when isMainModule:
  main()
