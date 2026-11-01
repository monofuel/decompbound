import
  std/[tables, strutils, algorithm],
  ../decompbound/[apu, dsp, music_player, rom_pipeline, spc700]

const
  SongId = 3
  SampleRate = 32000

type ReadSite = object
  count, first, last: int

proc main() =
  ## Trace unknown event consumers and verify known pitch/phase paths without payload dumps.
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
  for sample in 0 ..< SampleRate * 2:
    let start = machine.spc.cycles
    while machine.spc.cycles - start < CyclesPerSample:
      doAssert not machine.spc.stopped
      let
        pc = machine.spc.pc.int
        opcode = machine.spc.ram[pc]
      if pc == 0x05CD:
        let
          timerCount = machine.spc.ram[0x100 + ((machine.spc.sp.int + 1) and 255)].int
          product = timerCount * machine.spc.ram[0x53].int
        phaseSum = machine.spc.ram[0x51].int + (product and 255)
        phaseHigh = product shr 8
        phasePending = true
      if phasePending and pc in [0x05D8, 0x05E0]:
        doAssert pc == (if phaseSum > 255: 0x05D8 else: 0x05E0)
        doAssert machine.spc.ram[0x51].int == (phaseSum and 255)
        doAssert machine.spc.a.int == (phaseSum and 255) and machine.spc.y.int == phaseHigh
        phasePending = false
        inc phaseChecks
      if pc == 0x070E:
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

when isMainModule:
  main()
