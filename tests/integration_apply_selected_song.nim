## Candidate application through the real loader/port helpers, with authored unused package slots.
## This checks finite no-upload paths, not transfer completion or lookup/record-table validity.
import
  decompbound/cpu,
  ./engine/rebuilt_rom

const
  Consumer = 0xC069AF
  RecordPointers = [0x7F6000, 0x7FFFFE]

proc putWord(bus: Bus, address, value: int) =
  ## Author a little-endian control word.
  bus.mem[address] = (value and 255).uint8
  bus.mem[address + 1] = (value shr 8).uint8

proc word(bus: Bus, address: int): int =
  ## Observe a produced or authored word.
  bus.mem[address].int or (bus.mem[address + 1].int shl 8)

proc checkImage(image: seq[uint8]): tuple[contexts, producerChains: int] =
  ## Execute genuine framed calls and retain produced selection/caches through original callees.
  let bus = newBus()
  for bank in [0, 4]:
    for offset in 0 ..< 65536:
      bus.mem[(0xC0 + bank) * 65536 + offset] = image[bank * 65536 + offset]
  for index, value in [0x22'u8, 0xAF, 0x69, 0xC0]: bus.mem[0xC04000 + index] = value
  var writes: seq[tuple[address: uint32, value: uint8]]
  var recordReads, loaderEntries, selectionAtLoader: int
  var expectedRecord: uint32
  bus.readHook = proc(address: uint32): int =
    if address == expectedRecord: inc recordReads
    if address < 0x2000: return bus.mem[0x7E0000 + address.int].int
    if address in [0x2140'u32, 0x2141'u32]: return 0 # Authored idle input, no device.
    if address == 0xC4FBBD:
      inc loaderEntries
      selectionAtLoader = bus.word(0x7E5DD4)
    -1
  bus.writeHook = proc(address: uint32, value: uint8): bool =
    if address < 0x2000:
      bus.mem[0x7E0000 + address.int] = value
      return true
    if address in [0x2140'u32, 0x2141'u32, 0x2143'u32]:
      writes.add (address, value)
      return true
    false
  for scenario in 0 .. 2:
    let song = if scenario == 1: 160 else: 3
    let row = 0xC4F70A + (song - 1) * 3
    for index in 0 .. 2: bus.mem[row + index] = 255
    for pointer in RecordPointers:
      expectedRecord = (pointer + 3).uint32
      for command in 0 .. 255:
        for phase in [0, 128, 0x35, 0xB5]:
          for gate in [0, 1, 65535]:
            for equal in [false, true]:
              let active = gate == 0 and not equal
              bus.putWord(0x7E5DD8, gate)
              bus.putWord(0x7E5DD6, song)
              bus.putWord(0x7E5DD4, if equal: song else: song + 1)
              bus.putWord(0x7E5E38, pointer and 65535)
              bus.putWord(0x7E5E3A, 0xA500 or (pointer shr 16))
              bus.mem[pointer + 3] = command.uint8
              bus.mem[0x7E1ACB] = phase.uint8
              bus.putWord(0x7EB53B, if scenario == 0: song else: 65535)
              for address in [0x7EB53D, 0x7EB53F, 0x7EB541, 0x7EB543]:
                bus.putWord(address, 0x1234)
              bus.putWord(0x7EB4B6, 0) # Real warm poke on changed loader paths.
              writes.setLen(0)
              recordReads = 0
              loaderEntries = 0
              selectionAtLoader = -1
              var host = Cpu(pc: 0x4000, pbr: 0xC0, dbr: 0x7E, d: 0x1F00,
                s: 0x1FFF, x: 0x4567, y: 0x89AB)
              var steps = 0
              while host.pc != 0x4004:
                doAssert steps < 350
                doAssert not (host.pbr == 0xC0 and host.pc == 0xAB06)
                host.step(bus)
                inc steps
              var expected: seq[tuple[address: uint32, value: uint8]]
              var outputPhase = phase
              if active:
                if scenario != 0:
                  expected.add (0x2143'u32, 0x57'u8)
                  if scenario == 2:
                    expected.add (0x2141'u32, (1 or outputPhase).uint8)
                    outputPhase = outputPhase xor 128
                    expected.add (0x2140'u32, 0'u8)
                  expected.add (0x2140'u32, song.uint8)
                expected.add (0x2141'u32, (command or outputPhase).uint8)
                outputPhase = outputPhase xor 128
              doAssert writes == expected
              doAssert loaderEntries == active.int and recordReads == active.int
              if active: doAssert selectionAtLoader == song
              doAssert bus.word(0x7E5DD4) == (if active or equal: song else: song + 1)
              doAssert bus.word(0x7E5DD6) == song and bus.word(0x7E5DD8) == gate
              doAssert bus.word(0x7E5E38) == (pointer and 65535)
              doAssert bus.word(0x7E5E3A) == (0xA500 or (pointer shr 16))
              doAssert bus.mem[0x7E1ACB].int == outputPhase
              for address in [0x7EB53D, 0x7EB53F, 0x7EB541, 0x7EB543]:
                doAssert bus.word(address) == 0x1234
              doAssert host.d == 0x1F00 and host.dbr == 0x7E and host.s == 0x1FFF
              doAssert (host.p and (FlagM or FlagX or FlagN or FlagZ)) == 0
              if active:
                doAssert host.a.int == outputPhase and host.y == 3
                doAssert bus.word(0x7EB53B) == song
              else:
                doAssert host.x == 0x4567 and host.y == 0x89AB
              inc result.contexts
  # Real lookup publishes candidate/pointer consumed by the next actual JSL, unchanged.
  for index, value in [0x22'u8, 0xF4, 0x68, 0xC0, 0x22, 0xAF, 0x69, 0xC0]:
    bus.mem[0xC04000 + index] = value
  const MapIndex = (0x4321 shr 8) + 32 * (0x8765 div 128)
  bus.mem[0xDCD637 + MapIndex] = 17
  bus.putWord(0xCF58EF + 2 * 17, 0x6000)
  bus.putWord(0xCF6000, 0) # Authored unconditional record, no flag-evaluation callee.
  expectedRecord = 0xCF6003
  for song in [3, 160]:
    for alreadyLoaded in [false, true]:
      for command in [0, 1, 128, 255]:
        for phase in [0, 128]:
          bus.mem[0xCF6002] = song.uint8
          bus.mem[0xCF6003] = command.uint8
          bus.putWord(0x7E5DD8, 0)
          bus.putWord(0x7E5DDA, 1) # Actual wrapper suppresses lookup's separate notification.
          bus.putWord(0x7E5DD4, song + 1)
          bus.putWord(0x7EB53B, if alreadyLoaded: song else: 65535)
          bus.mem[0x7E1ACB] = phase.uint8
          writes.setLen(0)
          loaderEntries = 0
          recordReads = 0
          var host = Cpu(pc: 0x4000, pbr: 0xC0, dbr: 0x7E, d: 0x1F00,
            s: 0x1FFF, a: 0x4321, x: 0x8765)
          var steps = 0
          while host.pc != 0x4008:
            doAssert steps < 450
            if host.pc == 0x4004:
              doAssert bus.word(0x7E5DD6) == song
              doAssert bus.word(0x7E5E38) == 0x6000 and bus.word(0x7E5E3A) == 0xCF
              doAssert bus.word(0x7E5DD4) == song + 1
            doAssert not (host.pbr == 0xC0 and host.pc == 0xAB06)
            host.step(bus)
            inc steps
          var expected: seq[tuple[address: uint32, value: uint8]]
          var outputPhase = phase
          if not alreadyLoaded:
            expected.add (0x2143'u32, 0x57'u8)
            if song == 3:
              expected.add (0x2141'u32, (1 or outputPhase).uint8)
              outputPhase = outputPhase xor 128
              expected.add (0x2140'u32, 0'u8)
            expected.add (0x2140'u32, song.uint8)
          expected.add (0x2141'u32, (command or outputPhase).uint8)
          outputPhase = outputPhase xor 128
          doAssert writes == expected and loaderEntries == 1 and recordReads == 1
          doAssert bus.word(0x7E5DD4) == song and bus.word(0x7E5DD6) == song
          doAssert bus.word(0x7E5E38) == 0x6000 and bus.word(0x7E5E3A) == 0xCF
          doAssert bus.mem[0x7E1ACB].int == outputPhase
          doAssert host.d == 0x1F00 and host.s == 0x1FFF and host.dbr == 0x7E
          inc result.producerChains

proc main() =
  ## Require original and independently byte-identical rebuilt images.
  var contexts, producerChains = 0
  for image in engineImages("bin/apply_selected_song_extract"):
    let count = checkImage(image)
    doAssert count.contexts == 36864 and count.producerChains == 32
    contexts += count.contexts
    producerChains += count.producerChains
  echo "Apply selected song passed: ", contexts, " original/rebuilt finite no-upload contexts."
  echo "Actual lookup-to-consumer chains=", producerChains, "; synchronization routine excluded."

when isMainModule:
  main()
