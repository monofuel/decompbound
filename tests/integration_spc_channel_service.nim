## Eight-voice output loop/caller integration with authored state and silent port capture.
import
  std/[strformat, tables],
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  PortWrite = tuple[address: uint16, value: uint8]
  Visit = tuple[channel: uint8, mask: uint8]

const
  DriverMap = 0x25FB42
  DriverStart = 0x500
  DriverLength = 16779
  ReturnAddress = 0x5000'u16
  WordEdges = [0, 1, 0x00FF, 0x0100, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]
  Steps = [1, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFF00, 0xFFFF, 0]
  PanSteps = [0, 1, 0x100, 0xFF00, 0xFFFF]
  Durations = [0, 1, 2, 255]

proc word(spc: Spc, address: int): int =
  ## Read one little-endian synthetic channel word.
  spc.ram[address].int or (spc.ram[address + 1].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Write authored word state without copying ROM data.
  spc.ram[address] = (value and 255).uint8
  spc.ram[address + 1] = (value shr 8).uint8

proc gainWord(master, channelFactor, integer: int): int =
  ## Model the existing multiply-high chain with truncation before squaring.
  let scaled = (((255 * master div 256) * channelFactor div 256) * integer) div 256
  scaled * scaled div 256

proc curve(position: int): int =
  ## Interpolate an authored nonlinear curve using an unsigned low-byte slope.
  let
    integer = position shr 8
    fraction = position and 255
    first = integer * integer div 2
    second = (integer + 1) * (integer + 1) div 2
  first + ((second - first) * fraction div 256)

proc appendStereo(writes: var seq[PortWrite], voice, gain, position, phase: int) =
  ## Specify ascending left/right register transactions from the stereo law.
  let
    left = gain * curve(position) div 256
    right = gain * curve(20 * 256 - position) div 256
    leftByte = (if (phase and 128) != 0: -left else: left) and 255
    rightByte = (if (phase and 64) != 0: -right else: right) and 255
  writes.add (0xF2'u16, (voice * 16).uint8)
  writes.add (0xF3'u16, leftByte.uint8)
  writes.add (0xF2'u16, (voice * 16 + 1).uint8)
  writes.add (0xF3'u16, rightByte.uint8)

proc checkCase(spc: var Spc, activeBits, high, seed, inhibit: int, upstream = false): int =
  ## Run all eight original calls and compare independent state/output predictions.
  for address in 0 .. 0x4FF:
    spc.ram[address] = ((address * 37 + seed * 19 + 113) and 255).uint8
  for index in 0 .. 21: spc.ram[0xE73 + index] = (index * index div 2).uint8
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.sp = 0xEF
  spc.x = 0xA6
  spc.y = (seed xor 0xA5).uint8
  spc.a = 0x5A
  spc.psw = if (seed and 1) == 0: 0 else: 0xDF
  spc.ram[0x44] = 0xC4 # The output pass must not use/refresh saved channel X.
  spc.ram[0x1A] = inhibit.uint8
  spc.ram[0x1B] = 255
  spc.ram[0x04] = (if upstream: 1 else: 0)
  spc.ram[0x00] = 0
  spc.ram[0x08] = 0
  spc.ram[0x0C] = 0
  spc.ram[0x54] = 0
  spc.ram[0x68] = 0
  spc.ram[0x5A] = 0
  spc.ram[0x59] = (seed xor 0xD5).uint8
  spc.ram[0x5E] = (if upstream: 0 else: [0, 1, 128, 255][seed and 3]).uint8
  for voice in 0 .. 7:
    let
      channel = voice * 2
      active = (activeBits and (1 shl voice)) != 0 and high != 0
      cursorHigh = if active: high else: 0
    spc.ram[0x30 + channel] = ((voice * 37 + seed) and 255).uint8
    spc.ram[0x31 + channel] = cursorHigh.uint8
    spc.ram[0x70 + channel] = 2 # Real upstream pass holds rather than fetches.
    spc.ram[0x90 + channel] = Durations[(voice + seed) and 3].uint8
    spc.ram[0x91 + channel] = Durations[(voice + seed div 7 + 1) and 3].uint8
    spc.ram[0xC1 + channel] = 0 # Isolate the proven volume/pan consumer math.
    spc.ram[0x210 + channel] = ((voice * 29 + seed) and 255).uint8
    spc.putWord(0x300 + channel, WordEdges[(voice + seed) and 7])
    spc.putWord(0x310 + channel, Steps[(voice + seed div 3) and 7])
    spc.putWord(0x330 + channel, 10 * 256 + ((voice * 37 + seed) and 255))
    spc.putWord(0x340 + channel, PanSteps[(voice + seed) mod PanSteps.len])
    spc.ram[0x351 + channel] = (((voice + seed) and 3) shl 6).uint8
  let
    before = spc.ram[]
    initialStatus = spc.psw
  var
    changes = {0x47: 0}.toTable
    expectedWrites: seq[PortWrite]
    expectedVisits: seq[Visit]
    dirty = before[0x5E].int
    expectedA = 0
    expectedY = if upstream: 0 else: spc.y.int
  if upstream: changes[0x44] = 14
  for voice in 0 .. 7:
    let
      channel = 2 * voice
      bit = 1 shl voice
      active = before[0x31 + channel] != 0
    if active:
      expectedVisits.add (channel.uint8, bit.uint8)
      let
        volumeCounter = before[0x90 + channel].int
        panCounter = before[0x91 + channel].int
        volume = (spc.word(0x300 + channel) + (if volumeCounter != 0: spc.word(0x310 + channel) else: 0)) and 65535
        position = (spc.word(0x330 + channel) + (if panCounter != 0: spc.word(0x340 + channel) else: 0)) and 65535
        gain = gainWord(before[0x59].int, before[0x210 + channel].int, volume shr 8)
      if upstream: changes[0x70 + channel] = 1
      changes[0x321 + channel] = gain
      if volumeCounter != 0:
        changes[0x90 + channel] = volumeCounter - 1
        changes[0x300 + channel] = volume and 255
        changes[0x301 + channel] = volume shr 8
        changes[0x14] = 0; changes[0x15] = 3
        changes[0x16] = 0x10; changes[0x17] = 3
        dirty = dirty or bit
      if panCounter != 0:
        changes[0x91 + channel] = panCounter - 1
        changes[0x330 + channel] = position and 255
        changes[0x331 + channel] = position shr 8
        changes[0x14] = 0x30; changes[0x15] = 3
        changes[0x16] = 0x40; changes[0x17] = 3
        dirty = dirty or bit
      if (dirty and bit) != 0:
        changes[0x10] = position and 255
        changes[0x11] = position shr 8
        changes[0x12] = voice * 16 + 2
        if (inhibit and bit) == 0:
          expectedWrites.appendStereo(voice, gain, position, before[0x351 + channel].int)
        expectedY = position shr 8
        if voice == 7: expectedA = position and 255
      else:
        expectedY = gain
  changes[0x5E] = dirty
  var
    writes: seq[PortWrite]
    observed: seq[Visit]
    minimumSp = 255
    instructions = 0
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected hardware read ${address:04X}"
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address in [0xF2'u16, 0xF3]
    writes.add (address, value)
    true
  spc.pc = if upstream: 0x05D8 else: 0x0930
  let stop = if upstream: 0x05DB'u16 else: ReturnAddress
  while spc.pc != stop:
    doAssert instructions < 3000, &"channel pass at${spc.pc:04X}"
    if spc.pc == 0x0939:
      observed.add (spc.x, spc.ram[0x47])
      doAssert spc.sp == (if upstream: 0xED'u8 else: 0xEF'u8)
    spc.step()
    minimumSp = min(minimumSp, spc.sp.int)
    inc instructions
  doAssert observed == expectedVisits and writes == expectedWrites
  doAssert spc.x == 16 and spc.ram[0x47] == 0
  doAssert spc.a.int == expectedA and spc.y.int == expectedY
  doAssert spc.sp == (if upstream: 0xEF'u8 else: 0xF1'u8)
  doAssert minimumSp >= (if upstream: 0xE7 else: 0xE9)
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert (spc.psw and (PswC or PswN or PswZ)) == (PswC or PswZ)
  doAssert (spc.psw and (PswP or PswI or PswB)) == (initialStatus and (PswP or PswI or PswB))
  if expectedVisits.len == 0:
    doAssert (spc.psw and (PswH or PswV)) == (initialStatus and (PswH or PswV))
  for address in 0 .. 0x4FF:
    if address in (if upstream: 0x1E8 else: 0x1EA) .. 0x1EF: continue
    let expected = if changes.hasKey(address): changes[address].uint8 else: before[address]
    doAssert spc.ram[address] == expected, &"RAM${address:04X} got{spc.ram[address]} expected{expected}"
  result = expectedVisits.len

proc main() =
  ## Require both images and count only completed direct/caller checks and actual callbacks.
  var contexts, callbacks, upstream: int
  for image in engineImages("bin/spc_channel_service_extract"):
    var spc = newSpc()
    for index in 0 ..< DriverLength:
      spc.ram[DriverStart + index] = image[DriverMap + DriverStart + index]
    for pattern in 0 .. 255:
      for high in [1, 128, 255]:
        for seed in [0, 1, 127, 255]:
          for inhibit in [0, 255]:
            callbacks += spc.checkCase(pattern, high, seed, inhibit)
            inc contexts
    for voice in 0 .. 7:
      for high in 0 .. 255:
        callbacks += spc.checkCase(1 shl voice, high, high, 255)
        inc contexts
    for pattern in [0, 1, 128, 0x55, 0xAA, 255]:
      for seed in [0, 1, 127, 255]:
        for inhibit in [0, 255]:
          callbacks += spc.checkCase(pattern, 0x60, seed, inhibit, true)
          inc upstream
  echo &"SPC channel service passed: {contexts} direct contexts, " &
    &"{upstream} actual $05D8→$07F9 caller contexts, {callbacks} original $0C40 callbacks " &
    "across original/rebuilt images."

when isMainModule:
  main()
