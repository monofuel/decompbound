import
  std/[tables, strutils, algorithm],
  ../decompbound/[apu, dsp, music_player, rom_pipeline, spc700]

type
  ReadSite = object
    count, first, last: int
  PortWrite = tuple[address: uint16, value: uint8]
  BoundaryState = object
    direct: array[0xF0, uint8]
    a, x, y, stack, status, timer, writes: int
  LookAheadState = object
    channel, stack, gate, cursor, repeats, target, continuation, request, queued, dirty: int

const
  SongId = 3
  SampleRate = 32000
  DriverMap = 0x25FB42 # Package-one file offset minus its APU origin.
  PreservedStatus = PswH or PswV or PswP or PswI or PswB

proc word(spc: Spc, address: int): int =
  ## Read a structural live-RAM word without exporting its contents.
  spc.ram[address].int + spc.ram[address + 1].int * 256

proc snapshot(spc: Spc, writes: int): BoundaryState =
  ## Save the bounded direct page, native registers and pending timer frame.
  for address in 0 ..< result.direct.len:
    result.direct[address] = spc.ram[address]
  result.a = spc.a.int
  result.x = spc.x.int
  result.y = spc.y.int
  result.stack = spc.sp.int
  result.status = spc.psw.int
  result.timer = spc.ram[0x100 + ((spc.sp.int + 1) and 255)].int
  result.writes = writes

proc checkStatus(spc: Spc, before: BoundaryState, value, carry: int) =
  ## Check final arithmetic flags and all status bits the fragments preserve.
  let expected = (before.status and PreservedStatus.int) or carry or
    (if value == 0: PswZ.int else: 0) or (value and PswN.int)
  doAssert spc.psw.int == expected

proc convertedPitch(spc: Spc, compensate: bool): int =
  ## Calculate the conversion oracle from live scratch and curve words without exporting data.
  var position = spc.ram[0x10].int + spc.ram[0x11].int * 256
  if compensate:
    let integer = position div 256
    position = (position + (if integer < 19: -2 * (19 - integer)
      elif integer >= 52: integer - 52 else: 0)) and 65535
  let
    integer = (position div 256) and 127
    segment = integer mod 12
    quotient = integer div 12
    address = 0x0EBC + segment * 2
    base = spc.ram[address].int + spc.ram[address + 1].int * 256
    next = spc.ram[address + 2].int + spc.ram[address + 3].int * 256
    interpolation = (base + ((next - base) and 255) * (position mod 256) div 256) and 65535
  result = if quotient > 6: 0 else: ((interpolation * 2) and 65535) shr (6 - quotient)

proc main() =
  ## Trace driver reads and verify bounded pitch, gain, call, phase and publication contracts.
  let
    rom = readGoldBaserom()
    machine = newApu()
  applyPackageBlocks(machine.spc.ram[], rom, packFileOffset(rom, 1))
  for pack in songPackIndices(rom, SongId):
    applyPackageBlocks(machine.spc.ram[], rom, packFileOffset(rom, pack))
  machine.spc.pc = 0x500
  machine.spc.sp = 0xEF
  for sample in 0 ..< SampleRate div 5:
    discard machine.runSample()
  for command in [(3, 0x57), (1, 1), (0, 0)]:
    machine.portsIn[command[0]] = command[1].uint8
    for sample in 0 ..< SampleRate div 200:
      discard machine.runSample()
  machine.portsIn[0] = SongId.uint8
  var
    sites: Table[int, ReadSite]
    commands: Table[int, int]
    voices: set[uint8]
    scaledPitch: uint32
    pitchPending = false
    pitchChecks = 0
    phasePending = false
    phaseSum, phaseHigh, phaseChecks = 0
    gainPending = false
    gainChannel, expectedGain, gainChecks = 0
    callPending = false
    callChannel, callTarget, callCount, callReturn, callStack, callChecks = 0
    eventPending = false
    eventChannel, eventInteger, eventFraction, eventMode, eventChecks = 0
    conversionPending = false
    conversionExpected, conversionChecks = 0
    lookAheadPending = false
    lookAhead: LookAheadState
    lookAheadChecks = 0
    flushPending, settlePending: bool
    flush, settle: BoundaryState
    flushPorts, expectedPorts: seq[PortWrite]
    writeCount, flushChecks, bypassChecks, publishedPairs, settleChecks: int
    settleEqual, settleIncrement, fullFlushes, partialFlushes, keyFlushes: int
    lastSource: int
  let apuWriteHook = machine.spc.writeHook
  doAssert apuWriteHook != nil
  # Observe writes while retaining the real DSP, timer and communication hooks.
  machine.spc.writeHook = proc(address: uint16, value: uint8): bool =
    inc writeCount
    if flushPending:
      flushPorts.add (address, value)
    result = apuWriteHook(address, value)
  for sample in 0 ..< SampleRate * 2:
    let start = machine.spc.cycles
    while machine.spc.cycles - start < CyclesPerSample:
      doAssert not machine.spc.stopped
      let
        pc = machine.spc.pc.int
        opcode = machine.spc.ram[pc]
      if pc == 0x0546:
        doAssert not flushPending
        flush = snapshot(machine.spc, writeCount)
        doAssert (machine.spc.psw and PswP) == 0
        flushPorts.setLen(0)
        expectedPorts.setLen(0)
        if flush.direct[0x1B] == 0:
          for index in countdown(10, 1):
            if index >= 6 or (flush.direct[0x4C] < 128 and
                (index == 5 or flush.direct[0x4C] == flush.direct[0x4D])):
              let
                register = rom[DriverMap + 0xEA7 + index]
                source = rom[DriverMap + 0xEB1 + index].int
              doAssert machine.spc.ram[0xEA7 + index] == register
              doAssert machine.spc.ram[0xEB1 + index].int == source
              doAssert source < flush.direct.len
              expectedPorts.add (0xF2'u16, register)
              expectedPorts.add (0xF3'u16, flush.direct[source])
              lastSource = source
        flushPending = true
      if flushPending and pc in [0x0579, 0x05D8]:
        doAssert machine.spc.sp.int == flush.stack
        doAssert machine.spc.ram[0x100 + ((flush.stack + 1) and 255)].int == flush.timer
        doAssert flushPorts == expectedPorts
        if flush.direct[0x1B] != 0:
          doAssert pc == 0x05D8
          doAssert machine.spc.a == flush.direct[0x1B]
          doAssert machine.spc.x.int == flush.x and machine.spc.y.int == flush.y
          checkStatus(machine.spc, flush, flush.direct[0x1B].int, flush.status and 1)
          for address in 0 ..< flush.direct.len:
            doAssert machine.spc.ram[address] == flush.direct[address]
          inc bypassChecks
        else:
          doAssert pc == 0x0579
          let
            oldHigh = flush.direct[0x18].int
            oldLow = flush.direct[0x19].int
            feedback = oldHigh xor oldLow
            newHigh = (oldHigh shr 1) or ((1 - ((feedback shr 1) and 1)) shl 7)
            newLow = (oldLow shr 1) or ((oldHigh and 1) shl 7)
          doAssert machine.spc.a.int == feedback shr 2
          doAssert machine.spc.x.int == lastSource and machine.spc.y == 0
          checkStatus(machine.spc, flush, newLow, oldLow and 1)
          for address in 0 ..< flush.direct.len:
            let expected = case address
              of 0x18: newHigh
              of 0x19: newLow
              of 0x45, 0x46: 0
              else: flush.direct[address].int
            doAssert machine.spc.ram[address].int == expected
          inc flushChecks
          publishedPairs += expectedPorts.len div 2
          case expectedPorts.len div 2
          of 10: inc fullFlushes
          of 6: inc partialFlushes
          of 5: inc keyFlushes
          else: doAssert false
        flushPending = false
      if pc == 0x05C6:
        doAssert not settlePending
        settle = snapshot(machine.spc, writeCount)
        doAssert (machine.spc.psw and PswP) == 0
        settlePending = true
      if settlePending and pc == 0x05CD:
        let
          old = settle.direct[0x4C].int
          requested = settle.direct[0x4D].int
          expected = if old == requested: old else: (old + 1) and 255
        doAssert machine.spc.a.int == settle.a and machine.spc.x.int == settle.x
        doAssert machine.spc.y.int == settle.y and machine.spc.sp.int == settle.stack
        doAssert machine.spc.ram[0x100 + ((settle.stack + 1) and 255)].int == settle.timer
        doAssert writeCount == settle.writes
        for address in 0 ..< settle.direct.len:
          doAssert machine.spc.ram[address].int ==
            (if address == 0x4C: expected else: settle.direct[address].int)
        checkStatus(machine.spc, settle, (if old == requested: 0 else: expected),
          (if old >= requested: 1 else: 0))
        if old == requested: inc settleEqual
        else: inc settleIncrement
        inc settleChecks
        settlePending = false
      if pc == 0x05CD:
        let
          timerCount = machine.spc.ram[0x100 + ((machine.spc.sp.int + 1) and 255)].int
          product = timerCount * machine.spc.ram[0x53].int
        phaseSum = machine.spc.ram[0x51].int + (product and 255)
        phaseHigh = product shr 8
        phasePending = true
      if pc == 0x0CF7:
        let channel = machine.spc.x.int
        lookAhead = LookAheadState(channel: channel, stack: machine.spc.sp.int,
          gate: machine.spc.ram[0x71 + channel].int,
          cursor: machine.spc.word(0x30 + channel),
          repeats: machine.spc.ram[0x80 + channel].int,
          target: machine.spc.word(0x240 + channel),
          continuation: machine.spc.word(0x230 + channel),
          request: machine.spc.ram[0x13].int, queued: machine.spc.ram[0x46].int,
          dirty: machine.spc.ram[0x5E].int)
        lookAheadPending = true
      if lookAheadPending and pc == 0x0D60:
        let channel = lookAhead.channel
        doAssert machine.spc.x.int == channel and machine.spc.sp.int == lookAhead.stack
        doAssert machine.spc.ram[0x71 + channel].int == max(0, lookAhead.gate - 1)
        doAssert machine.spc.word(0x30 + channel) == lookAhead.cursor
        doAssert machine.spc.ram[0x80 + channel].int == lookAhead.repeats
        doAssert machine.spc.word(0x240 + channel) == lookAhead.target
        doAssert machine.spc.word(0x230 + channel) == lookAhead.continuation
        doAssert machine.spc.ram[0x13].int == lookAhead.request
        doAssert machine.spc.ram[0x46].int == lookAhead.queued
        doAssert machine.spc.ram[0x5E].int == lookAhead.dirty
        lookAheadPending = false
        inc lookAheadChecks
      if pc == 0x0667:
        eventChannel = machine.spc.x.int
        eventInteger = ((machine.spc.y.int and 127) + machine.spc.ram[0x50].int +
          machine.spc.ram[0x2F0 + eventChannel].int) and 255
        eventFraction = machine.spc.ram[0x381 + eventChannel].int
        eventMode = (machine.spc.ram[0x2B1 + eventChannel].int and 1) * 128
        eventPending = true
      if eventPending and pc == 0x0684:
        doAssert machine.spc.x.int == eventChannel
        doAssert machine.spc.ram[0x361 + eventChannel].int == eventInteger
        doAssert machine.spc.ram[0x360 + eventChannel].int == eventFraction
        doAssert machine.spc.ram[0x2A0 + eventChannel].int == eventMode
        eventPending = false
        inc eventChecks
      if phasePending and pc in [0x05D8, 0x05E0]:
        doAssert pc == (if phaseSum > 255: 0x05D8 else: 0x05E0)
        doAssert machine.spc.ram[0x51].int == (phaseSum and 255)
        doAssert machine.spc.a.int == (phaseSum and 255) and machine.spc.y.int == phaseHigh
        phasePending = false
        inc phaseChecks
      if pc == 0x0E61:
        gainChannel = machine.spc.x.int
        let
          first = machine.spc.a.int * machine.spc.ram[0x59].int div 256
          second = first * machine.spc.ram[0x210 + gainChannel].int div 256
          third = second * machine.spc.ram[0x301 + gainChannel].int div 256
        expectedGain = third * third div 256
        gainPending = true
      if pc == 0x0E72:
        doAssert gainPending
        doAssert machine.spc.x.int == gainChannel
        doAssert machine.spc.a.int == expectedGain and machine.spc.y.int == expectedGain
        doAssert machine.spc.ram[0x321 + gainChannel].int == expectedGain
        gainPending = false
        inc gainChecks
      if pc in [0x06BE, 0x06D4] and not conversionPending:
        conversionExpected = convertedPitch(machine.spc, pc == 0x06BE)
        conversionPending = true
      if pc == 0x070E:
        if conversionPending:
          doAssert machine.spc.ram[0x14].int + machine.spc.ram[0x15].int * 256 == conversionExpected
          conversionPending = false
          inc conversionChecks
        let
          channel = machine.spc.x.int
          pitch = machine.spc.ram[0x14].uint32 or (machine.spc.ram[0x15].uint32 shl 8)
          factor = machine.spc.ram[0x220 + channel].uint32 or
            (machine.spc.ram[0x221 + channel].uint32 shl 8)
        scaledPitch = ((pitch * factor) shr 8) and 65535
        pitchPending = true
      if pc == 0x0733:
        doAssert pitchPending
        doAssert (machine.spc.ram[0x16].uint32 or (machine.spc.ram[0x17].uint32 shl 8)) == scaledPitch
        pitchPending = false
        inc pitchChecks
      if pc == 0x0943:
        let command = machine.spc.a.int
        commands[command] = commands.getOrDefault(command) + 1
        voices.incl machine.spc.x
      if pc == 0x0AAC:
        callChannel = machine.spc.x.int
        let pointer = machine.spc.ram[0x30 + callChannel].int or
          (machine.spc.ram[0x31 + callChannel].int shl 8)
        callTarget = machine.spc.a.int or (machine.spc.ram[pointer].int shl 8)
        callCount = machine.spc.ram[(pointer + 1) and 65535].int
        callReturn = (pointer + 2) and 65535
        callStack = machine.spc.sp.int
        callPending = true
      if callPending and pc == 0x0ACE:
        doAssert machine.spc.x.int == callChannel and machine.spc.sp.int == callStack
        doAssert machine.spc.ram[0x80 + callChannel].int == callCount
        for address in [0x30, 0x240]:
          doAssert (machine.spc.ram[address + callChannel].int or
            (machine.spc.ram[address + callChannel + 1].int shl 8)) == callTarget
        doAssert (machine.spc.ram[0x230 + callChannel].int or
          (machine.spc.ram[0x231 + callChannel].int shl 8)) == callReturn
        callPending = false
        inc callChecks
      if opcode in [0xF7'u8, 0xE7'u8]:
        let
          dp = (if (machine.spc.psw and PswP) == 0: 0 else: 256)
          pointer = (machine.spc.ram[(pc + 1) and 65535].int +
            (if opcode == 0xE7: machine.spc.x.int else: 0)) and 255
          target = ((machine.spc.ram[dp + pointer].int or
            (machine.spc.ram[dp + ((pointer + 1) and 255)].int shl 8)) + (if opcode == 0xF7: machine.spc.y.int else: 0)) and 65535
        if target >= 0x4800:
          var site = sites.getOrDefault(pc)
          if site.count == 0:
            site.first = target
          inc site.count
          site.last = target
          sites[pc] = site
      machine.spc.step()
    machine.tickTimers(CyclesPerSample)
    discard machine.dsp.mixSample()
  machine.spc.writeHook = apuWriteHook
  doAssert flushChecks > 0 and settleChecks > 0
  echo "verified live flushes: ", flushChecks, " bypasses: ", bypassChecks,
    " DSP pairs: ", publishedPairs, " full/flags/key-only: ",
    fullFlushes, "/", partialFlushes, "/", keyFlushes
  echo "verified live settle boundaries: ", settleChecks, " equal: ", settleEqual,
    " increments: ", settleIncrement, " pending flush/settle at trace end: ",
    flushPending, "/", settlePending
  var addresses: seq[int]
  for pc in sites.keys:
    addresses.add pc
  addresses.sort()
  for pc in addresses:
    let site = sites[pc]
    echo "APU $", pc.toHex(4), " indirect reads=", site.count,
      " first=$", site.first.toHex(4), " last=$", site.last.toHex(4)
  var commandIds: seq[int]
  for command in commands.keys:
    commandIds.add command
  commandIds.sort()
  for command in commandIds:
    let
      entry = 0x0B23 + ((command * 2) and 255)
      handler = machine.spc.ram[entry].int or (machine.spc.ram[entry + 1].int shl 8)
    echo "command=$", command.toHex(2), " count=", commands[command], " handler=$", handler.toHex(4)
  echo "dispatch X offsets: ", voices
  doAssert pitchChecks > 0
  echo "verified pitch multiplications: ", pitchChecks
  doAssert phaseChecks > 0
  echo "verified timer/tempo phase routes: ", phaseChecks
  doAssert gainChecks > 0
  echo "verified staged channel gains: ", gainChecks
  doAssert callChecks > 0
  echo "verified sequence call frames: ", callChecks
  doAssert eventChecks > 0
  echo "verified accepted-event pitch states: ", eventChecks
  doAssert conversionChecks > 0 and not conversionPending
  echo "verified pitch-table conversions: ", conversionChecks
  doAssert lookAheadChecks > 0
  echo "verified lookahead live-state preservation: ", lookAheadChecks

when isMainModule:
  main()
