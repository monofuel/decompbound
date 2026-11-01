## Independent prefix/control-flow checks using authored dictionaries and unchanged driver code.

import
  std/strformat,
  decompbound/spc700,
  ./engine/rebuilt_rom

type
  Observation = object
    ports: seq[(uint16, uint8)]
    prepare, held, transition, dispatch, fetches, prefixes: int
  Totals = object
    parses, counters, callbacks, prepareCalls, commands, held, zeroKinds,
      inheritedFlags, services, schedules: int

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x1E00'u16
  Events = [0, 1, 127, 128, 0xA4, 0xC7, 0xC8, 0xC9, 0xCA, 0xDF]
  Record = [23, 81, 162, 67, 1, 0]

proc word(spc: Spc, address: int): int =
  ## Read an authored wrapping little-endian state word.
  spc.ram[address and 65535].int+256*spc.ram[(address+1) and 65535].int
proc putWord(spc: var Spc, address, value: int) =
  ## Store a synthetic word with APU address wrap.
  spc.ram[address and 65535] = (value and 255).uint8
  spc.ram[(address+1) and 65535] = ((value shr 8) and 255).uint8
proc seed(spc: var Spc, channel, stream: int) =
  ## Initialize distinguishable input fields and standard callback prerequisites.
  for address in 0 .. 0xEF: spc.ram[address] = 0xA5
  for address in 0x100 .. 0x3AF: spc.ram[address] = 0xA5
  spc.putWord(0x0E, 0)
  spc.putWord(0x30+channel, stream)
  spc.ram[0x44] = channel.uint8
  spc.ram[0x47] = (1 shl(channel div 2)).uint8
  spc.ram[0x1A] = 0
  spc.ram[0x1B] = 0x80
  spc.ram[0x400+channel] = 0
  spc.ram[0x200+channel] = 225
  spc.ram[0x201+channel] = 255
  spc.ram[0x210+channel] = 0x6A
  spc.putWord(0x220+channel, 256)
  spc.putWord(0x360+channel, 0xB47D)
  spc.ram[0x381+channel] = 125
  spc.ram[0x280+channel] = 0
  spc.ram[0x50] = 0
  spc.ram[0x5F] = 0
  spc.ram[0x2F0+channel] = 0
  spc.ram[0xB1+channel] = 0
  spc.ram[0x71+channel] = 0
  spc.x = channel.uint8
  spc.psw = PswI or PswB or PswH or PswV or PswC
proc run(spc: var Spc, entry: uint16, exits: set[uint16], stopChannel = -1): Observation =
  ## Execute original callbacks with a guarded native frame, never patched returns.
  var observed: Observation
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    doAssert address in [0xF2'u16, 0xF3'u16]
    observed.ports.add (address, value)
    false
  spc.readHook = proc(address: uint16): int =
    doAssert false, &"unexpected hardware read ${address:04X}"
    -1
  spc.putWord(0x1F0, ReturnAddress.int)
  spc.ram[0x1DF] = 0xA5
  spc.ram[0x1F2] = 0xA5
  spc.sp = 0xEF
  spc.pc = entry
  var steps = 0
  while spc.pc notin exits or (stopChannel >= 0 and spc.x.int != stopChannel):
    doAssert steps < 3000
    doAssert spc.sp in 0xE0'u8 .. 0xF1'u8
    case spc.pc
    of 0x654: inc observed.prepare
    of 0xCF7: inc observed.held
    of 0xB84: inc observed.transition
    of 0x943: inc observed.dispatch
    of 0x955: inc observed.fetches
    of 0x89E: inc observed.prefixes
    else: discard
    spc.step()
    inc steps
  doAssert spc.sp == 0xEF
  doAssert spc.word(0x1F0) == ReturnAddress.int
  doAssert spc.ram[0x1DF] == 0xA5 and spc.ram[0x1F2] == 0xA5
  spc.writeHook = nil
  spc.readHook = nil
  result = observed
proc installTables(spc: var Spc, variant: int) =
  ## Install two distinct authored packed-prefix dictionaries, including zero/high-bit values.
  for index in 0 ..< 8: spc.ram[0x6F80+index] = ((index*37+variant*129) and 255).uint8
  for index in 0 ..< 16: spc.ram[0x6F88+index] = ((index*19+variant*127) and 255).uint8
proc pitch(position: int): int =
  ## Predict the previously verified conversion using the authored quadratic curve.
  let
    n = position div 256
    adjusted = (position+(if n < 19: -2*(19-n) elif n >= 52: n-52 else: 0)) and 65535
    reduced = (adjusted div 256) and 127
    index = reduced mod 12
    quotient = reduced div 12
    lower = 0x1000+index*0x90+index*index*3
    upper = 0x1000+(index+1)*0x90+(index+1)*(index+1)*3
    interpolated = (lower+(((upper-lower) and 255)*(adjusted and
        255) div 256)) and 65535
  if quotient > 6: 0 else: ((interpolated*2) and 65535) shr(6-quotient)
proc appendPitch(writes: var seq[(uint16, uint8)], channel, value: int) =
  ## Specify the exact two pitch-register port pairs independently of driver instructions.
  writes.add (0xF2'u16, (channel*8+2).uint8)
  writes.add (0xF3'u16, (value and 255).uint8)
  writes.add (0xF2'u16, (channel*8+3).uint8)
  writes.add (0xF3'u16, (value div 256).uint8)
proc checkPrefix(spc: var Spc, first, second, third, stream: int) =
  ## Predict optional byte consumption, both table indices, final classification and counters.
  let
    channel = ((first xor second xor third) and 7)*2
    duration = if first < 128: first else: 225
    packed = first < 128 and second < 128
    factor = if packed: spc.ram[0x6F80+second div 16].int else: 255
    gain = if packed: spc.ram[0x6F88+(second and 15)].int else: 0x6A
    token = if first >= 128: first elif second >= 128: second else: third
    consumed = if first >= 128: 0 elif second >= 128: 1 else: 2
    product = duration*factor div 256
    count = max(1, product)
  spc.seed(channel, stream)
  spc.ram[stream] = second.uint8
  spc.ram[(stream+1) and 65535] = third.uint8
  let
    before = spc.ram[0 .. 0xEF]
    arrays = spc.ram[0x200 .. 0x3AF]
  spc.a = first.uint8
  spc.y = first.uint8
  spc.psw = (spc.psw and not(PswN or PswZ)) or
    (if first >= 128: PswN else: 0) or (if first == 0: PswZ else: 0)
  let observed = spc.run(0x89E, {0x8C4'u16, 0x8ED'u16})
  doAssert observed.ports.len == 0 and observed.prepare == 0 and
      observed.dispatch == 0
  doAssert observed.fetches == consumed and observed.prefixes == 1
  doAssert spc.x.int == channel and spc.word(0x30+channel) == ((
      stream+consumed) and 65535)
  doAssert spc.ram[0x200+channel].int == duration
  doAssert spc.ram[0x201+channel].int == factor and spc.ram[
      0x210+channel].int == gain
  if token >= 224:
    doAssert spc.pc == 0x8C4 and spc.a.int == token and spc.y.int == token
    let difference = (token-224) and 255
    doAssert spc.psw == (PswI or PswB or PswH or PswV or PswC or
      (if difference == 0: PswZ else: 0) or (if difference >=
          128: PswN else: 0))
  else:
    doAssert spc.pc == 0x8ED and spc.ram[0x70+channel].int == duration
    doAssert spc.ram[0x71+channel].int == count
    doAssert spc.a.int == count and spc.y.int == product
    doAssert (spc.psw and PswC) == 0 and (spc.psw and PswZ) == 0
    doAssert spc.psw == (PswI or PswB or PswH or PswV or (if count >=
        128: PswN else: 0))
  for address in 0 .. 0xEF:
    if address notin [0x30+channel, 0x31+channel] and
        not(token < 224 and address in [0x70+channel, 0x71+channel]):
      doAssert spc.ram[address] == before[address]
  for address in 0x200 .. 0x3AF:
    if address notin [0x200+channel, 0x201+channel, 0x210+channel]:
      doAssert spc.ram[address] == arrays[address-0x200]
proc checkCounters(spc: var Spc, duration, factor: int) =
  ## Exercise full-byte multiplication and min-one behavior independently of table ranges.
  let channel = ((duration xor factor) and 7)*2
  spc.seed(channel, 0x5000)
  spc.ram[0x200+channel] = duration.uint8
  spc.ram[0x201+channel] = factor.uint8
  spc.psw = PswI or PswB or PswN or PswZ or
    (if ((duration xor factor) and 1) != 0: PswC else: 0) or
    (if (duration and 1) != 0: PswH else: 0) or (if (factor and 1) !=
        0: PswV else: 0)
  let
    before = spc.ram[0 .. 0xEF]
    flags = spc.psw and not(PswN or PswZ)
  let observed = spc.run(0x8D4, {0x8ED'u16})
  let product = duration*factor div 256
  doAssert observed.ports.len == 0 and spc.ram[0x70+channel].int == duration
  doAssert spc.ram[0x71+channel].int == max(1, product)
  doAssert spc.a.int == max(1, product) and spc.y.int == product
  doAssert spc.psw == (flags or (if max(1, product) >= 128: PswN else: 0))
  for address in 0 .. 0xEF:
    if address notin [0x70+channel, 0x71+channel]: doAssert spc.ram[address] ==
        before[address]
proc checkCallback(spc: var Spc, channel, token, mode, overlay: int,
    inhibited: bool): int =
  ## Execute the actual prefix-to-event callback and compare its authored register output.
  spc.seed(channel, 0x5000)
  spc.ram[0x1B] = mode.uint8
  spc.ram[0x400+channel] = overlay.uint8
  spc.ram[0x1A] = (if inhibited: 1 shl(channel div 2) else: 0).uint8
  spc.ram[0x5000] = 19
  spc.ram[0x5001] = 0
  spc.ram[0x5002] = token.uint8
  if token >= 0xCA:
    for index, value in Record: spc.ram[0x6E00+(
        token-0xCA)*6+index] = value.uint8
  let
    invoked = (mode or overlay) == 0
    accepted = invoked and not inhibited and token notin [0xC8, 0xC9]
    integer = if token >= 0xCA: 36 else: token and 127
    observed = spc.run(0x882, {0x8ED'u16})
  doAssert observed.prepare == (if invoked: 1 else: 0) and observed.dispatch == 0
  doAssert spc.x.int == channel
  doAssert spc.word(0x30+channel) == 0x5003 and spc.ram[0x70+channel] == 19
  doAssert spc.ram[0x71+channel].int == max(1, 19*spc.ram[0x6F80].int div 256)
  doAssert spc.word(0x360+channel) == (if accepted: integer*256+125 else: 0xB47D)
  var expected: seq[(uint16, uint8)]
  if accepted:
    if token >= 0xCA:
      for index in 0 ..< 4:
        expected.add (0xF2'u16, (channel*8+4+index).uint8)
        expected.add (0xF3'u16, Record[index].uint8)
    expected.appendPitch(channel, pitch(integer*256+125))
  doAssert observed.ports == expected
  result = observed.prepare
proc checkCommand(spc: var Spc, channel, kind, stream: int) =
  ## Run real finite handlers through command loopback, without treating metadata as width.
  spc.seed(channel, stream)
  let arguments = case kind
    of 0: @[0xE7, 0x37]
    of 1: @[0xF3]
    of 2: @[0xF1, 5, 3, 255]
    of 3: @[0xF2, 5, 3, 255]
    of 4: @[0xF9, 5, 3, 100]
    of 5: @[0xE1, 0xC0]
    else: @[0xEF, 0, 0x70, 2]
  for index, value in arguments: spc.ram[(stream+index) and 65535] = value.uint8
  if kind == 6:
    spc.ram[0x7000] = 19
    spc.ram[0x7001] = 0x7F
    spc.ram[0x7002] = 0x80
  else: spc.ram[(stream+arguments.len) and 65535] = 0x80
  let observed = spc.run(0x882, {0x8ED'u16})
  doAssert observed.ports.len == 0 and observed.prepare == 0 and
      observed.dispatch == 1
  doAssert observed.fetches == (if kind == 6: 7 else: arguments.len+1)
  doAssert spc.x.int == channel
  doAssert spc.word(0x30+channel) == (if kind == 6: 0x7003 else: (
      stream+arguments.len+1) and 65535)
  case kind
  of 0: doAssert spc.word(0x52) == 0x3700
  of 1: doAssert spc.ram[0x280+channel] == 0
  of 2, 3:
    doAssert spc.ram[0x281+channel] == 5 and spc.ram[0x280+channel] == 3
    doAssert spc.ram[0x291+channel] == 255 and spc.ram[0x290+channel].int == (
        if kind == 2: 1 else: 0)
  of 4:
    doAssert spc.ram[0xA1+channel] == 5 and spc.ram[0xA0+channel] == 3
    doAssert spc.ram[0x380+channel] == 100
    doAssert spc.word(0x370+channel) == ((-(80*256 div 3)) and 65535)
  of 5: doAssert spc.ram[0x351+channel] == 10 # Seeded global $0431 overrides E1 here.
  else:
    doAssert spc.word(0x230+channel) == ((stream+4) and 65535)
    doAssert spc.word(0x240+channel) == 0x7000 and spc.ram[0x80+channel] == 2
proc checkHeld(spc: var Spc, channel, mode, remaining: int) =
  ## Run both actual held callbacks, including final snap followed immediately by new F9.
  spc.seed(channel, 0x5000)
  spc.ram[0x1B] = mode.uint8
  spc.ram[0x71+channel] = 0
  spc.ram[0xA0+channel] = remaining.uint8
  spc.ram[0xA1+channel] = (if remaining == 2: 1 else: 0)
  spc.putWord(0x360+channel, 36*256+125)
  spc.putWord(0x370+channel, 0x0123)
  spc.ram[0x380+channel] = 64
  for index, value in [0xF9, 5, 3, 100]: spc.ram[0x5000+index] = value.uint8
  let observed = spc.run(0x8E6, {0x8F0'u16})
  doAssert observed.prepare == 0 and spc.x.int == channel
  if mode != 0:
    doAssert observed.held == 0 and observed.transition == 0 and
        observed.ports.len == 0
    doAssert spc.word(0x30+channel) == 0x5000 and spc.ram[0xA0+channel].int == remaining
  else:
    doAssert observed.held == 1 and observed.transition == 1
    if remaining == 2:
      doAssert spc.ram[0xA0+channel] == 2 and spc.ram[0xA1+channel] == 0
      doAssert spc.word(0x30+channel) == 0x5000 and observed.ports.len == 0
    else:
      doAssert spc.ram[0xA0+channel] == 3 and spc.ram[0xA1+channel] == 5
      doAssert spc.word(0x30+channel) == 0x5004 and spc.ram[0x380+channel] == 100
      doAssert spc.word(0x360+channel) == (if remaining ==
          1: 64*256 else: 36*256+125)
      var expected: seq[(uint16, uint8)]
      if remaining == 1: expected.appendPitch(channel, pitch(64*256))
      doAssert observed.ports == expected
proc checkZeroKind(spc: var Spc, channel, stream, kind: int) =
  ## Distinguish normal initial zero, direct-entry zero duration and packed-prefix third zero.
  spc.seed(channel, stream)
  if kind == 0:
    spc.ram[0x80+channel] = 0
    spc.ram[stream] = 0
    let observed = spc.run(0x882, {0x81A'u16})
    doAssert observed.ports.len == 0 and observed.prefixes == 0 and
        observed.fetches == 1
    doAssert spc.word(0x30+channel) == ((stream+1) and 65535)
    doAssert spc.ram[0x200+channel] == 225 and spc.ram[0x80+channel] == 0
  else:
    let duration = if kind == 1: 0 else: 19
    if kind == 1:
      spc.a = 0
      spc.y = 0
      spc.psw = (spc.psw and not PswN) or PswZ
      spc.ram[stream] = 0
      spc.ram[(stream+1) and 65535] = 0x80
    else:
      spc.ram[stream] = 19
      spc.ram[(stream+1) and 65535] = 0
      spc.ram[(stream+2) and 65535] = 0
    let observed = spc.run((if kind == 1: 0x89E else: 0x882), {0x8ED'u16})
    doAssert observed.ports.len == 0 and observed.prepare == 0 and
        observed.prefixes == 1
    doAssert observed.fetches == (if kind == 1: 2 else: 3)
    doAssert spc.word(0x30+channel) == ((stream+observed.fetches) and 65535)
    doAssert spc.ram[0x200+channel].int == duration and spc.ram[
        0x70+channel].int == duration
    doAssert spc.ram[0x201+channel] == spc.ram[0x6F80]
    doAssert spc.ram[0x210+channel] == spc.ram[0x6F88]
    doAssert spc.ram[0x71+channel].int == max(1, duration*spc.ram[
        0x6F80].int div 256)
  doAssert spc.x.int == channel

proc checkInheritedN(spc: var Spc, channel, first: int, negative: bool) =
  ## Deliberately mismatch A/N to prove the entry flag dependency, not normal fetch behavior.
  spc.seed(channel, 0x5000)
  spc.a = first.uint8
  spc.y = first.uint8
  spc.psw = (spc.psw and not PswN) or (if negative: PswN else: 0)
  spc.ram[0x5000] = 0x80
  let
    duration = if negative: 225 else: first
    token = if negative: first else: 128
    observed = spc.run(0x89E, {0x8C4'u16, 0x8ED'u16})
  doAssert observed.ports.len == 0 and observed.prepare == 0 and
      observed.dispatch == 0
  doAssert observed.fetches == (if negative: 0 else: 1)
  doAssert spc.word(0x30+channel) == (if negative: 0x5000 else: 0x5001)
  doAssert spc.ram[0x200+channel].int == duration
  if token >= 224: doAssert spc.pc == 0x8C4
  else:
    doAssert spc.pc == 0x8ED and spc.ram[0x70+channel].int == duration
    doAssert spc.ram[0x71+channel].int == max(1, duration*255 div 256)
  doAssert spc.x.int == channel

proc checkEventService(spc: var Spc, channel, mode: int) =
  ## Prove an event's actual BRA $08ED consumes F9 despite a nonzero processing mode.
  spc.seed(channel, 0x5000)
  spc.ram[0x1B] = mode.uint8
  spc.ram[0xA0+channel] = 0
  for index, value in [0x80, 0xF9, 5, 3, 100]: spc.ram[
      0x5000+index] = value.uint8
  let
    pendingDurationDelay = spc.word(0x280+channel)
    pendingModeInterval = spc.word(0x290+channel)
    observed = spc.run(0x882, {0x8F0'u16})
  doAssert observed.prepare == 0 and observed.held == 0 and
      observed.transition == 1
  doAssert observed.ports.len == 0 and observed.dispatch == 0
  doAssert spc.x.int == channel and spc.word(0x30+channel) == 0x5005
  doAssert spc.ram[0x1B].int == mode and spc.ram[0xA0+channel] == 3 and spc.ram[
      0xA1+channel] == 5
  doAssert spc.word(0x360+channel) == 0xB47D and spc.ram[0x380+channel] == 100
  doAssert spc.word(0x370+channel) == ((-(80*256 div 3)) and 65535)
  doAssert spc.word(0x280+channel) == pendingDurationDelay
  doAssert spc.word(0x290+channel) == pendingModeInterval

proc checkSchedule(spc: var Spc, channel, followingEvent: int) =
  ## Connect authored prefix factors to real countdown decrements and guarded KOFF decisions.
  spc.seed(channel, 0x5000)
  for address in 0 .. 0xEF: spc.ram[address] = 0
  spc.ram[0x04] = 1
  spc.ram[0x400 + channel] = 1
  spc.putWord(0x30 + channel, 0x5000)
  spc.ram[0x70 + channel] = 1
  spc.ram[0x6F80] = 255
  spc.ram[0x6F88] = 128
  for index, value in [4, 0, 0xC8, 4, 0, followingEvent, 4, 0, 0xC8]:
    spc.ram[0x5000 + index] = value.uint8
  let initialPitch = spc.word(0x360 + channel)
  for tick in 0 .. 4:
    spc.x = channel.uint8
    spc.psw = PswI or PswB
    let observed = spc.run(0x07F9, {0x08F0'u16}, channel)
    doAssert observed.prepare == 0 and observed.dispatch == 0
    doAssert spc.x.int == channel and spc.word(0x360 + channel) == initialPitch
    doAssert spc.ram[0x200 + channel] == 4 and spc.ram[0x201 + channel] == 255
    doAssert spc.ram[0x210 + channel] == 128
    if tick in [0, 4]:
      doAssert observed.prefixes == 1 and observed.fetches == 3 and observed.held == 0
      doAssert spc.word(0x30 + channel) == (if tick == 0: 0x5003 else: 0x5006)
      doAssert spc.ram[0x70 + channel] == 4 and spc.ram[0x71 + channel] == 3
    else:
      doAssert observed.prefixes == 0 and observed.fetches == 0 and observed.held == 1
      doAssert spc.word(0x30 + channel) == 0x5003
      doAssert spc.ram[0x70 + channel].int == 4 - tick
      doAssert spc.ram[0x71 + channel].int == 3 - tick
    let release = followingEvent == 0xC9 and tick in [2, 3]
    if release:
      doAssert observed.ports == @[(0xF2'u16, 0x5C'u8),
        (0xF3'u16, (1 shl (channel div 2)).uint8)]
    else:
      doAssert observed.ports.len == 0

proc checkImage(image: seq[uint8]): Totals =
  ## Exercise one original or freshly rebuilt driver image with no source-assembler dependency.
  var
    spc = newSpc()
  for address in DriverStart ..< DriverStart+DriverLength:
    spc.ram[address] = image[DriverMap+address]
  for variant in 0 .. 1:
    spc.installTables(variant)
    for first in 0 .. 255:
      for second in 0 .. 255:
        spc.checkPrefix(first, second, (first*37+second*11) and 255,
          (if (first xor second) mod 2 == 0: 0x5000 else: 0xFFFF))
        inc result.parses
    for packed in 0 .. 127:
      for third in 0 .. 255:
        spc.checkPrefix(19, packed, third, 0xFFFF)
        inc result.parses
  for duration in 0 .. 255:
    for factor in 0 .. 255:
      spc.checkCounters(duration, factor)
      inc result.counters
  for index in 0 .. 12: spc.putWord(0xEBC+index*2,
      0x1000+index*0x90+index*index*3)
  spc.ram[0x431] = 255
  for channel in countup(0, 14, 2):
    for event in Events:
      for mode in [0, 1, 128, 255]:
        for overlay in [0, 1, 128, 255]:
          for inhibited in [false, true]:
            result.prepareCalls+=spc.checkCallback(channel, event, mode,
                overlay, inhibited)
            inc result.callbacks
    for kind in 0 .. 6:
      for stream in [0x5000, 0xFFFD]:
        spc.checkCommand(channel, kind, stream)
        inc result.commands
    for mode in [0, 1, 128, 255]:
      for remaining in [0, 1, 2]:
        spc.checkHeld(channel, mode, remaining)
        inc result.held
    for stream in [0x5000, 0xFFFF]:
      for kind in 0 .. 2:
        spc.checkZeroKind(channel, stream, kind)
        inc result.zeroKinds
    for first in [0, 19, 127, 128, 223, 255]:
      for negative in [false, true]:
        spc.checkInheritedN(channel, first, negative)
        inc result.inheritedFlags
    for mode in [1, 128, 255]:
      spc.checkEventService(channel, mode)
      inc result.services
    for followingEvent in [0xC8, 0xC9]:
      spc.checkSchedule(channel, followingEvent)
      inc result.schedules

proc main() =
  ## Run every matrix on original and independently rebuilt ROMs without playback or patched code.
  for index, image in engineImages("bin/spc_sequence_prefix_extract"):
    let
      counts = checkImage(image)
      name = if index == 0: "original" else: "rebuilt"
    echo &"{name}: {counts.parses} prefix/classification, {counts.counters} counter, " &
      &"{counts.callbacks} event contexts ({counts.prepareCalls} real event-setup calls), " &
      &"{counts.commands} command loops, {counts.held} held-service contexts, " &
      &"{counts.zeroKinds} zero distinctions, {counts.inheritedFlags} inherited-N entries, " &
      &"{counts.services} mode-independent event-service chains and " &
      &"{counts.schedules} complete prefix-to-held schedules passed."
when isMainModule: main()
