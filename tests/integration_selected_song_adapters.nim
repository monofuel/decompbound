## Distinct load-existing and resolve-then-load adapters, through real lookup/loader helpers.
## Authored unused-package rows bound execution to finite no-upload paths; they
## establish no original song/record validity. Existing 69F7 coverage is separate.
import
  decompbound/cpu,
  ./engine/rebuilt_rom

proc putWord(bus: Bus, address, value: int) =
  ## Author one structural little-endian word.
  bus.mem[address] = (value and 255).uint8
  bus.mem[address + 1] = (value shr 8).uint8

proc word(bus: Bus, address: int): int =
  ## Observe a complete state word.
  bus.mem[address].int or (bus.mem[address + 1].int shl 8)

proc checkImage(image: seq[uint8]): int =
  ## Keep lookup-produced selection and notification phase intact through the real loader.
  let bus = newBus()
  for bank in [0, 4]:
    for offset in 0 ..< 65536:
      bus.mem[(0xC0 + bank) * 65536 + offset] = image[bank * 65536 + offset]
  const MapIndex = (0x4321 shr 8) + 32 * (0x8765 div 128)
  bus.mem[0xDCD637 + MapIndex] = 17
  bus.putWord(0xCF58EF + 34, 0x6000)
  bus.putWord(0xCF6000, 0) # Authored unconditional four-byte record.
  for song in [3, 160]:
    for index in 0 .. 2: bus.mem[0xC4F70A + (song - 1) * 3 + index] = 255
  var writes: seq[tuple[address: uint32, value: uint8]]
  var lookupCalls, loaderCalls, recordCommandsRead, expectedCandidate, expectedCurrent: int
  bus.readHook = proc(address: uint32): int =
    if address < 0x2000: return bus.mem[0x7E0000 + address.int].int
    if address in [0x2140'u32, 0x2141'u32]: return 0 # Synthetic idle input, no device.
    if address == 0xC068F4: inc lookupCalls
    if address in [0xCF6003'u32, 0x7F6003'u32]: inc recordCommandsRead
    if address == 0xC4FBBD:
      inc loaderCalls
      doAssert bus.word(0x7E5DD6) == expectedCandidate
      doAssert bus.word(0x7E5DD4) == expectedCurrent
    -1
  bus.writeHook = proc(address: uint32, value: uint8): bool =
    if address < 0x2000:
      bus.mem[0x7E0000 + address.int] = value
      return true
    if address in [0x2140'u32, 0x2141'u32, 0x2143'u32]:
      writes.add (address, value)
      return true
    false
  for entry in [0x69ED, 0x6A07]:
    for index, value in [0x22'u8, (entry and 255).uint8, (entry shr 8).uint8, 0xC0]:
      bus.mem[0xC04000 + index] = value
    for oldCandidate in [3, 160]:
      for newCandidate in [3, 160]:
        for gate in [0, 1, 256, 65535]:
          for suppress in [0, 1, 65535]:
            for current in [3, 160, 7]:
              for alreadyLoaded in [false, true]:
                for phase in [0, 128, 0x35, 0xB5]:
                  let
                    resolves = entry == 0x6A07
                    publishes = resolves and gate == 0
                    candidate = if publishes: newCandidate else: oldCandidate
                    notification = publishes and suppress == 0 and candidate != current
                  expectedCandidate = candidate
                  expectedCurrent = current
                  bus.putWord(0x7E9877, 0x4321)
                  bus.putWord(0x7E987B, 0x8765)
                  bus.putWord(0x7E5DD8, gate)
                  bus.putWord(0x7E5DDA, suppress)
                  bus.putWord(0x7E5DD6, oldCandidate)
                  bus.putWord(0x7E5DD4, current)
                  bus.putWord(0x7E5E38, 0x6000)
                  bus.putWord(0x7E5E3A, 0x7F)
                  bus.mem[0xCF6002] = newCandidate.uint8
                  bus.mem[0xCF6003] = 255
                  bus.mem[0x7F6003] = 255
                  bus.putWord(0x7EB53B, if alreadyLoaded: candidate else: 65535)
                  bus.putWord(0x7EB4B6, 0)
                  for address in [0x7EB53D, 0x7EB53F, 0x7EB541, 0x7EB543]:
                    bus.putWord(address, 0x1234)
                  bus.mem[0x7E1ACB] = phase.uint8
                  writes.setLen(0)
                  lookupCalls = 0
                  loaderCalls = 0
                  recordCommandsRead = 0
                  var host = Cpu(pc: 0x4000, pbr: 0xC0, dbr: 0x7E, d: 0x1F00,
                    s: 0x1FFF, a: 0xABCD, x: 0x67, y: 0xAB,
                    p: FlagI or FlagV or FlagM or FlagX or FlagC or FlagN or FlagZ)
                  var steps = 0
                  while host.pc != 0x4004:
                    doAssert steps < 450
                    doAssert not (host.pbr == 0xC0 and host.pc == 0xAB06)
                    if host.pbr == 0xC4 and host.pc == 0xFBBD:
                      doAssert host.a.int == candidate
                    host.step(bus)
                    inc steps
                  var expected: seq[tuple[address: uint32, value: uint8]]
                  var outputPhase = phase
                  if notification:
                    expected.add (0x2141'u32, (2 or outputPhase).uint8)
                    outputPhase = outputPhase xor 128
                  if not alreadyLoaded:
                    expected.add (0x2143'u32, 0x57'u8)
                    if candidate == 3:
                      expected.add (0x2141'u32, (1 or outputPhase).uint8)
                      outputPhase = outputPhase xor 128
                      expected.add (0x2140'u32, 0'u8)
                    expected.add (0x2140'u32, candidate.uint8)
                  doAssert writes == expected
                  doAssert lookupCalls == resolves.int and loaderCalls == 1
                  doAssert recordCommandsRead == 0
                  doAssert bus.word(0x7E5DD4) == current
                  doAssert bus.word(0x7E5DD6) == candidate
                  doAssert bus.word(0x7E5DD8) == gate and bus.word(0x7E5DDA) == suppress
                  doAssert bus.word(0x7E5E38) == 0x6000
                  doAssert bus.word(0x7E5E3A) == (if publishes: 0xCF else: 0x7F)
                  doAssert bus.mem[0x7E1ACB].int == outputPhase
                  doAssert bus.word(0x7EB53B) == candidate
                  for address in [0x7EB53D, 0x7EB53F, 0x7EB541, 0x7EB543]:
                    doAssert bus.word(address) == 0x1234
                  doAssert host.d == 0x1F00 and host.dbr == 0x7E and host.s == 0x1FFF
                  doAssert host.p == (FlagI or FlagC)
                  doAssert bus.mem[0x7E1FFF] == 0xC0 and bus.word(0x7E1FFD) == 0x4003
                  inc result

proc main() =
  ## Require original and independently byte-identical rebuilt images.
  var contexts = 0
  for image in engineImages("bin/selected_song_adapters_extract"):
    let count = checkImage(image)
    doAssert count == 2304
    contexts += count
  echo "Selected-song load adapters passed: ", contexts,
    " original/rebuilt finite contexts; no uploads or record-command consumption."

when isMainModule:
  main()
