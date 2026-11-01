## Execute real phase routing, channel previews and the nonreturning IPL handoff.
import
  std/strformat,
  decompbound/[apu, spc700],
  ./engine/rebuilt_rom

type
  PortWrite = tuple[address: uint16, value: uint8]
  Trace = object
    writes: seq[PortWrite]
    channels, calls: seq[int]
    reads: int

const
  DriverMap = 0x25FB42
  DriverStart = 0x500
  DriverLength = 16779
  Guard = 0xA5'u8
  FlushEntry = 0x546'u16
  IplEntry = 0xFFC0'u16

proc putWord(spc: var Spc, address, value: int) =
  ## Store authored little-endian state.
  spc.ram[address] = (value and 255).uint8
  spc.ram[address + 1] = ((value shr 8) and 255).uint8

proc loadDriver(image: seq[uint8]): Spc =
  ## Load only the supplied image's resident driver with IPL initially unmapped.
  result = newSpc()
  for address in DriverStart ..< DriverStart + DriverLength:
    result.ram[address] = image[DriverMap + address]
  result.iplEnabled = false

proc prepare(spc: var Spc, activity, mask: int, blocked: bool) =
  ## Enable gain preview for all voices so only cursor-high gating selects calls.
  for address in 0 .. 0xEF: spc.ram[address] = 0
  for address in 0x100 .. 0x40F: spc.ram[address] = Guard
  spc.ram[4] = activity.uint8
  spc.ram[0x1A] = (if blocked: 255 else: 0)
  spc.ram[0x5E] = 0x6A
  spc.ram[0x13] = 0x35
  spc.ram[0x47] = 0x39
  spc.putWord(0x58, 0xFF7F)
  for voice in 0 .. 7:
    let channel = voice * 2
    spc.putWord(0x30 + channel, (if (mask and (1 shl voice)) != 0: 0x4800 else: 0x00FF))
    spc.ram[0xC0 + channel] = 0
    spc.ram[0xC1 + channel] = 1
    spc.ram[0x2D0 + channel] = 0
    spc.ram[0x2D1 + channel] = 0
    spc.ram[0x2E0 + channel] = 0
    spc.ram[0x210 + channel] = 255
    spc.putWord(0x300 + channel, 0xFF7F)
    spc.ram[0x321 + channel] = 0xA6
    spc.putWord(0x330 + channel, 10 * 256)
    spc.ram[0x351 + channel] = 0
    spc.ram[0x90 + channel] = 0
    spc.ram[0x91 + channel] = 0
    spc.ram[0xB1 + channel] = 0
    spc.putWord(0x360 + channel, 0xB47D)
  for index in 0 .. 21:
    spc.ram[0xE73 + index] = (index * index div 2).uint8
  spc.putWord(0x1F0, 0x1E00)
  spc.sp = 0xEF
  spc.a = 0x37
  spc.x = 0xA6
  spc.y = 0xC3

proc execute(spc: var Spc, entry, stop: uint16, input = -1): Trace =
  ## Capture untouched code's calls and ports without synthesizing or playing audio.
  var trace: Trace
  spc.readHook = proc(address: uint16): int =
    doAssert address == 0xF4 and input >= 0
    inc trace.reads
    input
  spc.writeHook = proc(address: uint16, value: uint8): bool =
    trace.writes.add (address, value)
    false
  spc.pc = entry
  var instructions = 0
  while spc.pc != stop:
    doAssert instructions < 1500, &"routing ${entry:04X} at ${spc.pc:04X}"
    doAssert spc.sp in 0xE8'u8 .. 0xEF'u8
    if spc.pc == 0xDD0:
      trace.channels.add spc.x.int
      doAssert spc.ram[0x47].int == (1 shl (spc.x.int div 2))
    if spc.ram[spc.pc] == 0x3F:
      trace.calls.add spc.ram[spc.pc + 1].int + 256 * spc.ram[spc.pc + 2].int
    spc.step()
    inc instructions
  doAssert spc.sp == 0xEF and not spc.stopped
  doAssert spc.ram[0x1F0] == 0 and spc.ram[0x1F1] == 0x1E
  spc.readHook = nil
  spc.writeHook = nil
  result = trace

proc checkPreview(spc: var Spc, activity, mask: int, blocked, throughPhase: bool) =
  ## Specify all selected channels and actual stereo values from an authored pan curve.
  spc.prepare(activity, mask, blocked)
  spc.psw = PswI or PswB or PswH or PswV
  if throughPhase:
    spc.sp = 0xEE
    spc.ram[0x1EF] = 1
    spc.ram[0x53] = 1
  let before = spc.ram[0x200 .. 0x40F]
  let observed = spc.execute((if throughPhase: 0x5CD'u16 else: 0x5E0'u16), FlushEntry)
  var
    expectedChannels: seq[int]
    expectedWrites: seq[PortWrite]
  if activity != 0:
    for voice in 0 .. 7:
      if (mask and (1 shl voice)) != 0:
        expectedChannels.add voice * 2
        if not blocked:
          # Truncated factor chain 255->254->253->252, then square/256=248.
          # Both authored pan coefficients at position 10 are 50; 248*50/256=48.
          for side in 0 .. 1:
            expectedWrites.add (0xF2'u16, (voice * 16 + side).uint8)
            expectedWrites.add (0xF3'u16, 48'u8)
  doAssert observed.channels == expectedChannels and observed.writes == expectedWrites
  doAssert observed.reads == 0
  doAssert spc.x.int == (if activity != 0: 16 else: 0xA6)
  doAssert spc.ram[0x47].int == (if activity != 0: 0 else: 0x39)
  doAssert (spc.psw and (PswN or PswZ or PswC)) ==
    (PswZ or (if activity != 0: PswC else: 0'u8))
  doAssert (spc.psw and (PswP or PswI or PswB)) == (PswI or PswB)
  doAssert spc.ram[0x5E] == 0x6A and spc.ram[4].int == activity
  doAssert spc.ram[0x51].int == (if throughPhase: 1 else: 0)
  for address in 0x200 .. 0x40F:
    var expected = before[address - 0x200]
    for channel in expectedChannels:
      if address == 0x321 + channel: expected = 248
    doAssert spc.ram[address] == expected

proc checkUpdate(spc: var Spc, input: int, throughPhase: bool) =
  ## Connect the real inactive update and host exchange, including an actual phase carry.
  spc.prepare(0, 255, false)
  spc.psw = PswI or PswB or PswV
  if throughPhase:
    spc.sp = 0xEE
    spc.ram[0x1EF] = 1
    spc.ram[0x53] = 1
    spc.ram[0x51] = 255
  let observed = spc.execute((if throughPhase: 0x5CD'u16 else: 0x5D8'u16), FlushEntry, input)
  doAssert observed.calls == @[0x7F9, 0x625] and observed.channels.len == 0
  doAssert observed.reads == 2 and observed.writes == @[(0xF4'u16, 0'u8)]
  doAssert spc.ram[0].int == input and spc.ram[8] == 0 and spc.a.int == input
  doAssert spc.x == 0xA6 and spc.y == 0
  doAssert spc.ram[0x51] == 0 and spc.ram[0x47] == 0x39
  doAssert (spc.psw and (PswN or PswZ or PswC)) == (PswZ or PswC)

proc resetWrites(): seq[PortWrite] =
  ## Specify the hardware handoff in semantic register order, independent of source bytes.
  for pair in [(0x2C, 0), (0x3C, 0), (0x5C, 255), (0x4D, 0), (0x6C, 32)]:
    result.add (0xF2'u16, pair[0].uint8)
    result.add (0xF3'u16, pair[1].uint8)
  result.add (0xF1'u16, 0x80'u8)

proc checkReset(spc: var Spc, status: uint8) =
  ## Verify the DP-independent nonreturning fragment and unchanged buffered state.
  spc.prepare(255, 255, false)
  spc.psw = status
  let before = spc.ram[0 .. 0xEF]
  let observed = spc.execute(0x5FC, IplEntry)
  doAssert observed.reads == 0 and observed.writes == resetWrites()
  doAssert observed.calls == @[0x749, 0x749, 0x749, 0x749, 0x749]
  doAssert spc.a == 0x80 and spc.x == 0xA6 and spc.y == 0x6C
  doAssert spc.psw == ((status and not (PswN or PswZ)) or PswN)
  doAssert spc.ram[0 .. 0xEF] == before

proc checkApuReset(image: seq[uint8]) =
  ## Prove real CONTROL side effects at handoff without executing IPL or mixing samples.
  let machine = newApu()
  for address in DriverStart ..< DriverStart + DriverLength:
    machine.spc.ram[address] = image[DriverMap + address]
  discard machine.spc.writeHook(0xF1, 7)
  machine.spc.iplEnabled = false
  machine.portsIn = [1'u8, 2, 3, 4]
  machine.portsOut = [5'u8, 6, 7, 8]
  machine.spc.sp = 0xEF
  machine.spc.pc = 0x5FC
  var instructions = 0
  while machine.spc.pc != IplEntry:
    doAssert instructions < 40
    machine.spc.step()
    inc instructions
  doAssert machine.spc.iplEnabled and machine.spc.sp == 0xEF
  for timer in 0 .. 2: doAssert not machine.getTimerSnapshot(timer).enabled
  doAssert machine.portsIn == [1'u8, 2, 3, 4] and machine.portsOut == [5'u8, 6, 7, 8]
  for pair in [(0x2C, 0), (0x3C, 0), (0x5C, 255), (0x4D, 0), (0x6C, 32)]:
    doAssert machine.dsp.regs[pair[0]].int == pair[1]

proc main() =
  ## Require original/rebuilt images and report actual routing/handoff contexts.
  var previews, updates, resets, apuResets: int
  for image in engineImages("bin/spc_phase_routing_extract"):
    var spc = loadDriver(image)
    for activity in [0, 1, 127, 128, 255]:
      for mask in 0 .. 255:
        for blocked in [false, true]:
          spc.checkPreview(activity, mask, blocked, false)
          inc previews
    for mask in [0, 1, 128, 255]:
      spc.checkPreview(1, mask, false, true)
      inc previews
    for input in 0 .. 255:
      for throughPhase in [false, true]:
        spc.checkUpdate(input, throughPhase)
        inc updates
    for status in 0 .. 255:
      spc.checkReset(status.uint8)
      inc resets
    checkApuReset(image)
    inc apuResets
  echo &"SPC phase routing passed: {previews} previews, {updates} real update/exchange chains, " &
    &"{resets} IPL-handoff entries and {apuResets} real APU handoffs."

when isMainModule:
  main()
