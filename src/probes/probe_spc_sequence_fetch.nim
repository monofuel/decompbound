import
  std/[tables, strutils, algorithm],
  ../decompbound/[apu, dsp, rom_pipeline, spc700]

const
  SongId = 3
  SongTable = 0x4F70A
  PackTable = 0x4F947
  SampleRate = 32000

type ReadSite = object
  count, first, last: int

proc loadPack(apu: Apu, rom: seq[uint8], index: int) =
  ## Populate local APU RAM from the user's package blocks, stopping at zero length.
  let entry = PackTable + index * 3
  var offset = ((rom[entry].int and 63) shl 16) or rom[entry + 1].int or (rom[entry + 2].int shl 8)
  while true:
    doAssert offset + 2 <= rom.len
    let size = rom[offset].int or (rom[offset + 1].int shl 8)
    offset += 2
    if size == 0:
      break
    doAssert offset + 2 + size <= rom.len
    let destination = rom[offset].int or (rom[offset + 1].int shl 8)
    offset += 2
    doAssert destination + size <= 65536
    for index in 0 ..< size:
      apu.spc.ram[destination + index] = rom[offset + index]
    offset += size

proc main() =
  ## Locate indirect read sites during real driver execution without exporting payload bytes.
  let
    rom = readGoldBaserom()
    machine = newApu()
  machine.loadPack(rom, 1)
  for slot in 0 .. 2:
    let pack = rom[SongTable + (SongId - 1) * 3 + slot].int
    if pack != 255:
      machine.loadPack(rom, pack)
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
  for sample in 0 ..< SampleRate * 2:
    let start = machine.spc.cycles
    while machine.spc.cycles - start < CyclesPerSample:
      doAssert not machine.spc.stopped
      let
        pc = machine.spc.pc.int
        opcode = machine.spc.ram[pc]
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

when isMainModule:
  main()
