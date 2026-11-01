## Independent checks of original APU $0CD3..$0CF6 using both caller array bases.
## Synthetic words exercise the dirty-mask branch and wrapping sixteen-bit sum.

import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  ApplyEntry = 0x0CD3'u16
  ReturnAddress = 0x1E00'u16
  ArrayBases = [0x0300, 0x0330]
  BoundaryWords = [0, 1, 255, 256, 32767, 32768, 65534, 65535]
  Targets = [0, 1, 127, 255]
  ArrayGuardStart = 0x02FF
  ArrayGuardEnd = 0x0360
  StackGuard = 0xA5'u8
  StepLimit = 32

proc word(spc: Spc, address: int): int =
  ## Read a little-endian RAM word for an independent comparison.
  spc.ram[address].int or (spc.ram[address + 1].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Write a synthetic word modulo sixteen bits.
  spc.ram[address] = uint8(value and 255)
  spc.ram[address + 1] = uint8((value shr 8) and 255)

proc checkApply(spc: var Spc, base, channel, current, step, target, dirty,
    mask: int, incomingZero: bool) =
  ## Verify one call, including neighboring arrays, inputs, stack and final byte flags.
  let
    expectedDirty = dirty or mask
    adding = expectedDirty != 0
    expected = if adding: (current + step) and 65535 else: target * 256
    initialStatus = PswI or PswB or PswH or PswV or
      (if incomingZero: PswZ else: PswC)
  # Both proven callers pass a base whose low byte can be adjusted without
  # overflowing. Other pointer low bytes would require a different contract.
  doAssert base in ArrayBases
  doAssert channel in 0 .. 14 and channel mod 2 == 0
  for address in ArrayGuardStart .. ArrayGuardEnd:
    spc.ram[address] = uint8((address * 53 + 29) and 255)
  spc.putWord(base + channel, current)
  spc.putWord(base + 0x10 + channel, step)
  spc.ram[base + 0x20 + channel] = target.uint8
  spc.putWord(0x14, 0xB47D)
  spc.putWord(0x16, 0x6AC3)
  spc.ram[0x47] = mask.uint8
  spc.ram[0x5E] = dirty.uint8
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1ED] = StackGuard
  spc.ram[0x1F2] = StackGuard
  let
    beforeArrays = spc.ram[ArrayGuardStart .. ArrayGuardEnd]
    beforeDp = spc.ram[0 .. 0xEF]
  spc.a = uint8(base and 255)
  spc.y = uint8(base shr 8)
  spc.x = channel.uint8
  spc.sp = 0xEF
  spc.psw = initialStatus
  spc.pc = ApplyEntry
  var steps = 0
  while spc.pc != ReturnAddress:
    doAssert steps < StepLimit
    doAssert spc.sp in 0xED'u8 .. 0xF1'u8
    spc.step()
    inc steps
  doAssert spc.word(base + channel) == expected,
    $[base, channel, current, step, target, dirty, mask, incomingZero.int,
      expected, spc.word(base + channel)]
  doAssert spc.ram[0x5E].int == expectedDirty
  doAssert spc.ram[0x47].int == mask
  doAssert spc.word(base + 0x10 + channel) == step
  doAssert spc.ram[base + 0x20 + channel].int == target
  doAssert spc.word(0x14) == base
  doAssert spc.word(0x16) == base + (if adding: 0x10 else: 0x1F)
  for address in ArrayGuardStart .. ArrayGuardEnd:
    if address != base + channel and address != base + channel + 1:
      doAssert spc.ram[address] == beforeArrays[address - ArrayGuardStart],
        &"helper modified neighboring array byte ${address:04X}"
  for address in 0 .. 0xEF:
    if address notin [0x14, 0x15, 0x16, 0x17, 0x5E]:
      doAssert spc.ram[address] == beforeDp[address],
        &"helper modified unrelated DP byte ${address:02X}"
  doAssert spc.x.int == channel and spc.y.int == channel + 1
  doAssert spc.a.int == (expected shr 8)
  doAssert spc.sp == 0xF1 and spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1ED] == StackGuard and spc.ram[0x1F2] == StackGuard
  doAssert (spc.psw and (PswI or PswB or PswP)) == (initialStatus and (PswI or PswB or PswP))
  doAssert ((spc.psw and PswC) != 0) == (adding and current + step > 65535)
  doAssert ((spc.psw and PswN) != 0) == (expected >= 32768)
  doAssert ((spc.psw and PswZ) != 0) == ((expected shr 8) == 0)
  doAssert not spc.stopped

proc checkImage(image: seq[uint8]): tuple[adds, snaps: int] =
  ## Run representative carry, wrapping and branch cases on each base and channel.
  var spc = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    spc.ram[address] = image[DriverMap + address]
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, &"step helper unexpectedly wrote I/O ${address:04X}=${value:02X}"
    false
  var pairs: seq[tuple[current, step: int]]
  for index, current in BoundaryWords:
    pairs.add (current, current)
    pairs.add (current, BoundaryWords[(index + 3) mod BoundaryWords.len])
  pairs.add (255, 1)       # Carry from the low byte into the high byte.
  pairs.add (65535, 1)     # Carry out of the full sixteen-bit word.
  for base in ArrayBases:
    for voice in 0 ..< 8:
      for pairIndex, pair in pairs:
        for dirty in [0, 1, 128]:
          for mask in [0, 1, 128]:
            for incomingZero in [false, true]:
              # Targets vary independently of dirty-mask and incoming-Z choices;
              # addition cases still verify that the target byte is preserved.
              let target = Targets[(pairIndex + voice) mod Targets.len]
              spc.checkApply(base, voice * 2, pair.current, pair.step, target,
                dirty, mask, incomingZero)
              if (dirty or mask) == 0:
                inc result.snaps
              else:
                inc result.adds

proc main() =
  ## Check original and freshly rebuilt driver code without DSP or audible output.
  var total = 0
  for index, image in engineImages("bin/spc_step_apply_extract"):
    let
      counts = checkImage(image)
      name = if index == 0: "original" else: "rebuilt"
    total += counts.adds + counts.snaps
    echo &"{name}: {counts.adds} step additions and {counts.snaps} target snaps passed"
  echo &"SPC step apply: {total} executed cases across both images"

when isMainModule:
  main()
