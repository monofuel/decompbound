## Verify pitch-offset commands and event preparation using authored state/records.
import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

const
  DriverPayload = 0x260042
  DriverStart = 0x500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  Guard = 0xA5'u8
  Edges = [0, 1, 127, 128, 255]
  Fractions = [0, 1, 127, 255]
  Bases = [0x100, 0x210, 0x220, 0x2A0, 0x2B0, 0x2D0, 0x2F0, 0x360, 0x380]
  Record = [23, 81, 162, 67, 132, 53]

type
  PortWrite = tuple[address: uint16, value: uint8]
  Totals = object
    dispatchCalls, directSetterCalls, eventCalls, instrumentCalls: int
    offsetContexts, eventContexts, remapContexts: int

proc word(spc: Spc, address: int): int =
  ## Read an authored word with sixteen-bit address wrap.
  spc.ram[address and 65535].int or
    (spc.ram[(address + 1) and 65535].int shl 8)

proc putWord(spc: var Spc, address, value: int) =
  ## Write synthetic state without depending on driver arithmetic.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address + 1) and 65535] = ((value shr 8) and 255).uint8

proc stack(spc: var Spc) =
  ## Set the caller frame and guards outside the deepest expected native call.
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1EA] = Guard
  spc.ram[0x1F2] = Guard
  spc.sp = 0xEF

proc execute(spc: var Spc, entry: uint16, event: bool): seq[PortWrite] =
  ## Execute original instructions silently and capture every port write.
  var
    writes: seq[PortWrite]
    reads = 0
    instructions = 0
  spc.readHook = proc(address: uint16): int =
    inc reads
    -1
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    writes.add (address, value)
    false
  spc.pc = entry
  while spc.pc != ReturnAddress and not (event and spc.pc == 0x0696):
    doAssert instructions < 180, &"pitch entry ${entry:04X} at ${spc.pc:04X}"
    doAssert spc.sp in 0xEB'u8 .. 0xF1'u8
    spc.step()
    inc instructions
  doAssert reads == 0 and not spc.stopped
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1EA] == Guard and spc.ram[0x1F2] == Guard
  spc.readHook = nil
  spc.writeHook = nil
  result = writes

proc dispatch(spc: var Spc, command, channel, operand, stream: int,
    totals: var Totals) =
  ## Produce an offset through real command dispatch, including cursor wrap.
  spc.putWord(0x30 + channel, stream)
  spc.ram[stream] = operand.uint8
  spc.stack()
  spc.x = channel.uint8
  spc.a = command.uint8
  spc.y = (operand xor 255).uint8
  spc.psw = PswH or PswV or PswI or PswB or PswC
  doAssert spc.execute(0x0943, false).len == 0
  doAssert spc.sp == 0xF1 and spc.x.int == channel
  doAssert spc.a.int == operand and spc.y.int == operand
  doAssert spc.word(0x30 + channel) == ((stream + 1) and 65535)
  doAssert (spc.psw and not (PswN or PswZ)) == (PswH or PswV or PswI or PswB)
  doAssert ((spc.psw and PswZ) != 0) == (operand == 0)
  doAssert ((spc.psw and PswN) != 0) == (operand >= 128)
  inc totals.dispatchCalls

proc checkEvent(spc: var Spc, token, channel, globalOffset, channelOffset,
    fraction, mode, inhibit, mask, remap: int, noise: bool, totals: var Totals) =
  ## Compare event effects with independent modular arithmetic and authored records.
  # The active offsets must remain the actual outputs of E9 and EA dispatch.
  doAssert spc.ram[0x50].int == globalOffset
  doAssert spc.ram[0x2F0 + channel].int == channelOffset
  for base in Bases:
    for i in 0 ..< 16:
      if base != 0x2F0 or i != channel:
        spc.ram[base + i] = Guard
  for i in 0 ..< 16:
    spc.ram[0xB0 + i] = Guard
    spc.ram[0xC0 + i] = Guard
  spc.ram[0x381 + channel] = fraction.uint8
  spc.ram[0x2B1 + channel] = mode.uint8
  spc.ram[0x1A] = inhibit.uint8
  spc.ram[0x47] = mask.uint8
  spc.ram[0x5F] = remap.uint8
  spc.ram[0x45] = 0x20
  spc.ram[0x5E] = 0x40
  spc.ram[0x48] = 0xE7
  spc.ram[0x49] = 0xA5
  spc.putWord(0x14, 0x6655)
  let
    instrument = token >= 0xCA
    blocked = (inhibit and mask) != 0
    accepted = token notin [0xC8, 0xC9] and not blocked
    effective = if instrument: 0xA4 else: token
    recordIndex = (token - 0xCA + remap) and 255
    recordAddress = 0x6E00 + recordIndex * 6
    firstByte = if noise: 0xB7 else: Record[0]
  if instrument:
    for i, value in Record:
      spc.ram[recordAddress + i] = (if i == 0: firstByte else: value).uint8
  spc.stack()
  spc.x = channel.uint8
  spc.a = token.uint8
  spc.y = token.uint8
  spc.psw = PswI or PswB or (if (globalOffset xor channelOffset) mod 2 == 0: PswC else: 0)
  let writes = spc.execute(0x0654, true)
  doAssert spc.x.int == channel and spc.y.int == effective
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  doAssert spc.sp == (if accepted: 0xEF else: 0xF1)
  doAssert spc.pc == (if accepted: 0x0696'u16 else: ReturnAddress)
  doAssert spc.ram[0x50].int == globalOffset
  doAssert spc.ram[0x2F0 + channel].int == channelOffset
  doAssert spc.ram[0x381 + channel].int == fraction
  doAssert spc.ram[0x2B1 + channel].int == mode
  doAssert spc.ram[0x1A].int == inhibit and spc.ram[0x47].int == mask
  doAssert spc.ram[0x5F].int == remap
  if accepted:
    doAssert spc.ram[0x361 + channel].int ==
      (((effective and 127) + globalOffset + channelOffset) and 255)
    doAssert spc.ram[0x360 + channel].int == fraction
    doAssert spc.ram[0x2A0 + channel].int == ((mode and 1) * 128)
    for address in [0x100, 0xB0, 0xC0, 0x2D0]:
      doAssert spc.ram[address + channel] == 0
    doAssert spc.ram[0x45].int == (0x20 or mask)
    doAssert spc.ram[0x5E].int == (0x40 or mask)
    doAssert spc.a == 0 and (spc.psw and PswC) == 0
  else:
    for address in [0x360, 0x361, 0x2A0, 0x100, 0xB0, 0xC0, 0x2D0]:
      doAssert spc.ram[address + channel] == Guard
    doAssert spc.ram[0x45] == 0x20 and spc.ram[0x5E] == 0x40
  if instrument:
    inc totals.instrumentCalls
    doAssert spc.ram[0x211 + channel].int == token
    doAssert spc.word(0x14) == recordAddress
  else:
    doAssert spc.ram[0x211 + channel] == Guard and spc.word(0x14) == 0x6655
  if instrument and not blocked:
    doAssert writes.len == 8
    for i in 0 ..< 4:
      doAssert writes[i * 2] == (0xF2'u16, (channel * 8 + 4 + i).uint8)
      doAssert writes[i * 2 + 1] ==
        (0xF3'u16, (if i == 0: (if noise: 0 else: firstByte) else: Record[i]).uint8)
    doAssert spc.ram[0x221 + channel].int == Record[4]
    doAssert spc.ram[0x220 + channel].int == Record[5]
    doAssert spc.ram[0x48].int == (if noise: 0x37 else: 0xE7)
    doAssert spc.ram[0x49].int == (if noise: 0xA5 or mask else: 0xA5 and (255 xor mask))
  else:
    doAssert writes.len == 0
    doAssert spc.ram[0x221 + channel] == Guard and spc.ram[0x220 + channel] == Guard
    doAssert spc.ram[0x48] == 0xE7 and spc.ram[0x49] == 0xA5
  for base in Bases:
    for i in 0 ..< 16:
      let activeField = if base in [0x210, 0x2B0, 0x380]: i == channel + 1
        elif base in [0x220, 0x360]: i in [channel, channel + 1]
        else: i == channel
      if not activeField:
        doAssert spc.ram[base + i] == Guard, &"event changed neighbor ${base + i:04X}"
  for i in 0 ..< 16:
    if i != channel:
      doAssert spc.ram[0xB0 + i] == Guard and spc.ram[0xC0 + i] == Guard
  inc totals.eventCalls

proc offsets(spc: var Spc, channel, globalOffset, channelOffset, stream: int,
    totals: var Totals) =
  ## Feed both real setters directly into the next event without rewriting their outputs.
  spc.dispatch(0xE9, channel, globalOffset, stream, totals)
  spc.dispatch(0xEA, channel, channelOffset, stream, totals)

proc directSetters(spc: var Spc, totals: var Totals) =
  ## Check that direct entries use A rather than Y and preserve every status bit.
  for command in [0xE9, 0xEA]:
    for channel in countup(0, 14, 2):
      for operand in 0 .. 255:
        for status in [0, 0xDF]:
          for i in 0 ..< 16: spc.ram[0x2F0 + i] = Guard
          spc.ram[0x50] = Guard
          spc.putWord(0x360 + channel, 0x5AA5)
          spc.stack()
          spc.a = operand.uint8
          spc.y = (operand xor 255).uint8
          spc.x = channel.uint8
          spc.psw = status.uint8
          doAssert spc.execute((if command == 0xE9: 0xA52 else: 0xA55), false).len == 0
          doAssert spc.a.int == operand and spc.y.int == (operand xor 255)
          doAssert spc.x.int == channel and spc.sp == 0xF1 and spc.psw.int == status
          doAssert spc.word(0x360 + channel) == 0x5AA5
          doAssert spc.ram[0x50].int == (if command == 0xE9: operand else: Guard.int)
          for i in 0 ..< 16:
            doAssert spc.ram[0x2F0 + i].int ==
              (if command == 0xEA and i == channel: operand else: Guard.int)
          inc totals.directSetterCalls

proc matrices(spc: var Spc, totals: var Totals) =
  ## Cover every offset pair, every event byte, all source fractions and mode bits.
  for globalOffset in 0 .. 255:
    for channelOffset in 0 .. 255:
      let
        voice = (globalOffset xor channelOffset) and 7
        channel = voice * 2
        stream = if (globalOffset and 1) == 0: 0x4800 else: 0xFFFF
      spc.offsets(channel, globalOffset, channelOffset, stream, totals)
      spc.checkEvent(0xA4, channel, globalOffset, channelOffset,
        globalOffset xor channelOffset, (globalOffset + channelOffset) and 255,
        0, 1 shl voice, 0, false, totals)
      inc totals.offsetContexts
  for token in 0 .. 255:
    for globalOffset in Edges:
      for channelOffset in Edges:
        for fraction in Fractions:
          for inhibit in [0, 255]:
            for zeroMask in [false, true]:
              let
                voice = (token + globalOffset + channelOffset + fraction) and 7
                channel = voice * 2
                mode = (token + globalOffset + channelOffset) and 255
                remap = [0, 1, 127, 255][(token + fraction) and 3]
                noise = ((token + globalOffset + fraction) and 1) != 0
              spc.offsets(channel, globalOffset, channelOffset, 0x48FF, totals)
              spc.checkEvent(token, channel, globalOffset, channelOffset, fraction,
                mode, inhibit, (if zeroMask: 0 else: 1 shl voice), remap, noise, totals)
              inc totals.eventContexts
  for remap in 0 .. 255:
    for voice in 0 ..< 8:
      let channel = voice * 2
      spc.offsets(channel, 255, 128, 0xFFFF, totals)
      spc.checkEvent(0xFF, channel, 255, 128, remap, remap,
        0, 1 shl voice, remap, (remap and 1) != 0, totals)
      inc totals.remapContexts

proc main() =
  ## Run original and independently rebuilt driver images with no speakers or assets.
  var totals: Totals
  for image in engineImages("bin/spc_pitch_offsets_extract"):
    var spc = newSpc()
    for i in 0 ..< DriverLength: spc.ram[DriverStart + i] = image[DriverPayload + i]
    spc.directSetters(totals)
    spc.matrices(totals)
  echo &"SPC pitch offsets passed: {totals.dispatchCalls} setter dispatches, " &
    &"{totals.directSetterCalls} direct setter calls, {totals.eventCalls} event-prefix " &
    &"entries (including {totals.instrumentCalls} instrument calls); " &
    &"{totals.offsetContexts} offset-pair, {totals.eventContexts} event-matrix and " &
    &"{totals.remapContexts} remap contexts."

when isMainModule:
  main()
