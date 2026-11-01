import
  std/strutils,
  decompbound/[apu, spc700],
  ./engine/rebuilt_rom

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x4000
  Defaults = [(0x4D3, 0x80), (0x4D2, 9), (0x4D1, 29), (0x4D4, 0xC0)]
  StatusStable = PswH or PswV or PswP or PswI or PswB

proc loaded(rom: seq[uint8], seed: int): Spc =
  ## Dirty every non-code byte with authored values, then restore original resident code/data.
  result = newSpc()
  for address in 0 .. 65535:
    result.ram[address] = ((address * 37 + seed * 19 + 113) and 255).uint8
  for index in 0 ..< DriverLength:
    result.ram[DriverStart + index] = rom[DriverPayload + index]
  result.readHook = proc(address: uint16): int =
    doAssert false, "unexpected initializer hardware read $" & address.toHex(4)
    -1
  result.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, "unexpected initializer hardware write $" & address.toHex(4)
    false

proc setFrame(spc: var Spc, stack: int) =
  ## Create a genuine wrapping native caller frame, without patching a RET instruction.
  spc.sp = stack.uint8
  spc.ram[0x100 + ((stack + 1) and 255)] = (ReturnAddress and 255).uint8
  spc.ram[0x100 + ((stack + 2) and 255)] = (ReturnAddress shr 8).uint8

proc checkFill(rom: seq[uint8], fill, status, stack: int): bool =
  ## Predict full RAM and the actual return target, including unsafe page-one frame alias cases.
  var spc = loaded(rom, fill xor status)
  spc.setFrame(stack)
  spc.a = fill.uint8
  spc.x = 0xA5
  spc.y = 0x5A
  spc.psw = status.uint8
  let page = if (status and PswP.int) == 0: 0 else: 256
  var expected = spc.ram[]
  for address in 0x420 .. 0x4FF: expected[address] = fill.uint8
  for address in 0xE800 + fill .. 0xFEFF: expected[address] = fill.uint8
  expected[page + 0x24] = 0
  expected[page + 0x25] = 255
  for (address, value) in Defaults: expected[address] = value.uint8
  let target = expected[0x100 + ((stack + 1) and 255)].int +
    256 * expected[0x100 + ((stack + 2) and 255)].int
  spc.pc = 0x16A5
  var steps, tailEntries: int
  while spc.pc != 0x2FDC:
    doAssert steps < 40000
    doAssert spc.sp.int == stack
    if spc.pc == 0x2FC8: inc tailEntries
    spc.step()
    inc steps
  spc.step() # Execute the original RET once; do not execute a corrupted return target.
  doAssert tailEntries == 1 and spc.pc.int == target
  doAssert spc.sp.int == ((stack + 2) and 255)
  doAssert spc.a == 0xC0 and spc.x == 0 and spc.y == 0
  doAssert spc.psw == ((status.uint8 and StatusStable) or PswC or PswN)
  doAssert spc.ram[] == expected
  result = target != ReturnAddress

proc checkTail(rom: seq[uint8]) =
  ## Pin the shared defaults entry independently of the fill, across PSW and wrapping frames.
  var contexts = 0
  for status in 0 .. 255:
    for stack in [0, 1, 0x22, 0x23, 0x24, 0xFE, 0xFF]:
      var spc = loaded(rom, status)
      spc.setFrame(stack)
      spc.a = status.uint8
      spc.x = (status xor 0x5A).uint8
      spc.y = (status xor 0xA5).uint8
      spc.psw = status.uint8
      var expected = spc.ram[]
      for (address, value) in Defaults: expected[address] = value.uint8
      spc.pc = 0x2FC8
      var steps = 0
      while spc.pc.int != ReturnAddress:
        doAssert steps < 10 and spc.sp.int == stack
        spc.step()
        inc steps
      doAssert spc.ram[] == expected and spc.sp.int == ((stack + 2) and 255)
      doAssert spc.a == 0xC0 and spc.x == (status xor 0x5A).uint8
      doAssert spc.y == (status xor 0xA5).uint8
      doAssert spc.psw == ((status.uint8 and not (PswN or PswZ)) or PswN)
      inc contexts
  echo "shared defaults PSW/frame contexts=", contexts

proc checkStartup(rom: seq[uint8]) =
  ## Witness the real startup CALL/JMP/RET chain without duplicating its hardware or inventory suites.
  let machine = newApu()
  for index in 0 ..< DriverLength:
    machine.spc.ram[DriverStart + index] = rom[DriverPayload + index]
  machine.spc.pc = 0x500
  var sawCall, sawFill, sawTail, sawReturn: bool
  var steps = 0
  while machine.spc.pc != 0x546:
    doAssert steps < 40000
    case machine.spc.pc.int
    of 0x50C:
      sawCall = true
      doAssert machine.spc.a == 0 and machine.spc.sp == 0xCF
    of 0x16A5:
      sawFill = true
      doAssert machine.spc.a == 0 and machine.spc.sp == 0xCD
    of 0x2FC8:
      sawTail = true
      doAssert machine.spc.sp == 0xCD and machine.spc.ram[0x25] == 255
    of 0x50F:
      sawReturn = true
      doAssert machine.spc.a == 0xC0 and machine.spc.sp == 0xCF
    else: discard
    machine.spc.step()
    inc steps
  doAssert sawCall and sawFill and sawTail and sawReturn
  echo "actual startup $050C CALL -> $16A5 -> $2FC8 -> RET $050F witnessed"

proc checkImage(rom: seq[uint8]) =
  ## Check direct initializer contracts and deliberately unsafe frame aliases independently.
  var fills, aliases: int
  for fill in 0 .. 255:
    for status in [0, 255]:
      doAssert not checkFill(rom, fill, status, 0xEF)
      inc fills
  for status in 0 .. 255:
    doAssert not checkFill(rom, 0, status, 0xEF)
    inc fills
  for page in [0, PswP.int]:
    for stack in [0, 1, 0x22, 0x23, 0x24, 0xFE, 0xFF]:
      let aliased = checkFill(rom, 0, page, stack)
      doAssert aliased == (page != 0 and stack in [0x22, 0x23, 0x24])
      if aliased: inc aliases
      inc fills
  doAssert fills == 782 and aliases == 3
  echo "full fill contexts=", fills, "; predicted unsafe page-one frame aliases=", aliases
  checkTail(rom)
  checkStartup(rom)

proc main() =
  ## Require original and independently rebuilt images, using no audio device or patched code.
  for index, image in engineImages("bin/spc_driver_state_init_extract"):
    echo "image=", (if index == 0: "original" else: "fresh rebuild")
    checkImage(image)
  echo "SPC driver state initialization passed across both images."

when isMainModule:
  main()
