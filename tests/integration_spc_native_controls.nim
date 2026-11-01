import
  std/strutils,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x4000'u16
  Entries = [0x2CDA, 0x2CE6, 0x2CF2, 0x2CFE, 0x2D0A, 0x2D16, 0x2D22, 0x2D2E]
  Rows = [0x2CAF, 0x2CB4, 0x2CB9, 0x2CBE, 0x2CC3, 0x2CC3, 0x2CCD, 0x2CD2]
  Channels = [2, 4, 6, 8, 10]
  Edges = [0, 1, 127, 128, 255]
  Stable = PswP or PswI or PswB

proc word(spc: Spc, address: int): int =
  ## Read a structural pointer or authored state word without exporting assets.
  spc.ram[address].int + 256 * spc.ram[address + 1].int

proc putWord(spc: var Spc, address, value: int) =
  ## Write an authored state word modulo sixteen bits.
  spc.ram[address] = (value and 255).uint8
  spc.ram[address + 1] = ((value shr 8) and 255).uint8

proc signedStep(target, current: int): int =
  ## Calculate the signed target-minus-current quotient for twenty update counts.
  let delta = target - current
  ((if delta < 0: -1 else: 1) * (abs(delta) * 256 div 20)) and 65535

proc prepare(spc: var Spc, seed, variant, index: int) =
  ## Author targets/current words and guards without importing original preset content.
  for address in 0 .. 0x4FF:
    spc.ram[address] = ((address * 37 + seed * 19 + variant) and 255).uint8
  spc.ram[0xE] = 0
  spc.ram[0xF] = 0
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.sp = 0xEF
  spc.pc = 0x1198
  spc.a = 0xA6
  spc.x = 0x37
  spc.y = 0x5A
  spc.psw = (if (seed and 1) == 0: 0'u8 else: 0xDF'u8)
  spc.ram[0x4B1] = (index + 9).uint8
  spc.ram[0x4B5] = 1 # Authored existing native continuation state, not created by this callback.
  spc.ram[0x4D1] = 29 # Actual startup's exclusive port-one capacity.
  for voice in 0 .. 7:
    let channel = voice * 2
    spc.putWord(0x30 + channel, 0x4800 + channel)
    spc.putWord(0x300 + channel, (Edges[(variant +
        voice) mod Edges.len] shl 8) or
      ((seed xor (channel * 37)) and 255))
    spc.ram[0x210 + channel] = 255
    spc.ram[0xC1 + channel] = 0
  spc.ram[0x59] = 255
  for offset in 0 .. 4:
    spc.ram[Rows[index] + offset] = ((seed + offset * 53) and 255).uint8
  spc.readHook = proc(address: uint16): int =
    doAssert false, "unexpected native-control hardware read $" & address.toHex(4)
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert false, "unexpected native-control hardware write $" &
        address.toHex(4)
    false

proc tickProduced(spc: var Spc, initial: array[0x10000, uint8], targets: array[5, int]) =
  ## Feed untouched produced transitions through real volume updates, stopping before stereo output.
  for index, channel in Channels:
    let
      start = initial[0x300 + channel].int + 256 * initial[0x301 + channel].int
      step = signedStep(targets[index], start div 256)
    for tick in 1 .. 21:
      spc.sp = 0xEF
      spc.x = channel.uint8
      spc.ram[0x47] = (1 shl (channel div 2)).uint8
      spc.pc = 0xC40
      var steps = 0
      while spc.pc != 0xC79:
        doAssert steps < 150 and spc.sp >= 0xE9
        spc.step()
        inc steps
      let
        value = (start + min(tick, 20) * step) and 65535
        third = 253 * (value div 256) div 256
      doAssert spc.word(0x300 + channel) == value
      doAssert spc.ram[0x90 + channel].int == max(0, 20 - tick)
      doAssert spc.word(0x310 + channel) == step and spc.ram[0x320 +
          channel].int == targets[index]
      doAssert spc.ram[0x321 + channel].int == third * third div 256
      doAssert spc.sp == 0xEF and spc.x.int == channel
      doAssert spc.word(0x30 + channel) == initial[0x30 + channel].int +
        256 * initial[0x31 + channel].int

proc continueSaved(spc: var Spc) =
  ## Use the callback's actual saved continuation without rearming the fades or patching code.
  let before = spc.ram[]
  doAssert spc.word(0x442) == 0x148A and spc.ram[0x48D] == 8 and spc.ram[
      0x4B5] == 1
  spc.ram[0x4B1] = 0
  spc.sp = 0xEF
  spc.pc = 0x1198
  var steps, continuationEntries, fadeEntries = 0
  while spc.pc != ReturnAddress:
    doAssert steps < 100
    if spc.pc == 0x148A: inc continuationEntries
    if spc.pc == 0x2D37: inc fadeEntries
    spc.step()
    inc steps
  doAssert continuationEntries == 1 and fadeEntries == 0 and spc.sp == 0xF1
  for channel in Channels:
    for base in [0x90, 0x300, 0x301, 0x310, 0x311, 0x320]:
      doAssert spc.ram[base + channel] == before[base + channel]

proc checkControls(rom: seq[uint8]) =
  ## Check real native dispatch, five full-byte targets, register/flag effects and untouched neighbors.
  var spc = newSpc()
  for index in 0 ..< DriverLength:
    spc.ram[DriverStart + index] = rom[DriverPayload + index]
  var contexts, tickChains, ticks, continuations: int
  for index, entry in Entries:
    for seed in 0 .. 255:
      for variant in 0 .. 4:
        spc.prepare(seed, variant, index)
        var steps = 0
        while spc.pc.int != entry:
          doAssert steps < 100 and spc.sp >= 0xED
          spc.step()
          inc steps
        doAssert spc.x.int == 2 * (index + 8) and spc.y == spc.x
        doAssert spc.a == 0x14 and spc.sp == 0xEF
        doAssert spc.word(0x442) == 0x148A and spc.ram[0x48D] == 8
        let
          before = spc.ram[]
          status = spc.psw
        var
          expected = before
          targets: array[5, int]
          signScratch = before[0x12].int
          lastDelta = 0
          lastStep = 0
          setters = 0
        for targetIndex, channel in Channels:
          let
            target = before[Rows[index] + targetIndex].int
            current = before[0x301 + channel].int
            delta = target - current
            step = signedStep(target, current)
          targets[targetIndex] = target
          expected[0x90 + channel] = 20
          expected[0x320 + channel] = target.uint8
          expected[0x310 + channel] = (step and 255).uint8
          expected[0x311 + channel] = (step shr 8).uint8
          signScratch = (signScratch shr 1) or (if delta < 0: 128 else: 0)
          if delta < 0:
            let magnitude = abs(delta) * 256 div 20
            expected[0x14] = (magnitude and 255).uint8
            expected[0x15] = (magnitude shr 8).uint8
          lastDelta = delta
          lastStep = step
        expected[0x12] = signScratch.uint8
        expected[0x20] = targets[4].uint8
        expected[0x22] = (Rows[index] and 255).uint8
        expected[0x23] = (Rows[index] shr 8).uint8
        expected[0x44] = 10
        while spc.pc != ReturnAddress:
          doAssert steps < 400 and spc.sp >= 0xE9
          doAssert spc.pc != 0x148A # Native handler RET does not implicitly invoke its continuation.
          if spc.pc == 0x166E: inc setters
          spc.step()
          inc steps
        doAssert setters == 5 and spc.sp == 0xF1
        doAssert spc.x == 10 and spc.y == 4 and spc.a.int == lastStep div 256
        let
          high = lastStep div 256
          carry = if lastDelta < 0: 0 else: (before[0x12].int shr 4) and 1
          half = if lastDelta < 0: 0 else: (if ((lastDelta mod 20) and 15) >=
              4: PswH.int else: 0)
          flags = (status.int and Stable.int) or carry or half or
            (high and 128) or (if high == 0: PswZ.int else: 0)
        doAssert spc.psw.int == flags
        for address in 0 .. 0x4FF:
          if address notin 0x1EA .. 0x1EF:
            doAssert spc.ram[address] == expected[address], "native RAM $" &
                address.toHex(4)
        for offset in 0 .. 4: doAssert spc.ram[Rows[index] + offset] == before[
            Rows[index] + offset]
        inc contexts
        if seed in [0, 1, 127, 255]:
          spc.continueSaved()
          inc continuations
          spc.tickProduced(before, targets)
          inc tickChains
          ticks += 5 * 21
  echo "real native adapter/control contexts=", contexts, "; five setters per context"
  echo "producer-to-tick chains=", tickChains, "; actual channel ticks=", ticks,
    "; actual saved-continuation returns=", continuations

proc main() =
  ## Require original and independently rebuilt images; all target parameters are authored locally.
  for index, image in engineImages("bin/spc_native_controls_extract"):
    echo "image=", (if index == 0: "original" else: "fresh rebuild")
    checkControls(image)
  echo "SPC native controls passed across both images."

when isMainModule:
  main()
