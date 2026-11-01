import
  std/strutils,
  decompbound/cpu,
  ./engine/rebuilt_rom

const
  ReturnPc = 0x4000'u16
  CacheBank = 0x7E0000

proc putWord(memory: Bus, address, value: int) =
  ## Author a word directly in the harness without altering original code.
  memory.mem[address] = (value and 255).uint8
  memory.mem[address + 1] = ((value shr 8) and 255).uint8

proc ramWord(memory: Bus, address: int): int =
  ## Read a canonical harness word without hardware side effects.
  memory.mem[address].int + 256 * memory.mem[address + 1].int

proc baseBus(rom: seq[uint8]): Bus =
  ## Map the user's original HiROM code/data into the flat CPU test bus.
  result = newBus()
  for index, value in rom: result.mem[0xC00000 + index] = value

proc attach(memory: Bus) =
  ## Map real low-WRAM aliases and reject accidental hardware execution in focused contracts.
  memory.readHook = proc(address: uint32): int =
    let
      bank = address shr 16
      offset = address and 65535
    if offset < 0x2000 and (bank <= 0x3F or bank in 0x80'u32 .. 0xBF'u32 or
        bank == 0x7E):
      return memory.mem[offset.int].int
    doAssert address notin 0x2140'u32 .. 0x2143'u32
    -1
  memory.writeHook = proc(address: uint32, value: uint8): bool =
    let
      bank = address shr 16
      offset = address and 65535
    if offset < 0x2000 and (bank <= 0x3F or bank in 0x80'u32 .. 0xBF'u32 or
        bank == 0x7E):
      memory.mem[offset.int] = value
      return true
    doAssert address notin 0x2140'u32 .. 0x2143'u32 and address != 0x4200
    false

proc nearFrame(memory: Bus) =
  ## Install an original RTS caller destination and neighboring native-stack guards.
  memory.putWord(0x1FF1, ReturnPc.int - 1)
  memory.mem[0x1FEC] = 0xA7
  memory.mem[0x1FF3] = 0x5A

proc farFrame(memory: Bus) =
  ## Install a real RTL caller frame in low WRAM.
  memory.putWord(0x1FFD, ReturnPc.int - 1)
  memory.mem[0x1FFF] = 0xC0

proc checkHelper(rom: seq[uint8]) =
  ## Sweep every A word and valid width states while proving preservation and DBR-selected mask storage.
  let memory = baseBus(rom)
  memory.attach()
  for value in 0 .. 65535:
    let
      direct = if (value and 255) == 0: 2 else: 0x100 + (value shr 12) * 0x40
      status = (value and 255) and not FlagD.int
      x = if (status and FlagX.int) != 0: 0x56 else: 0x1256
      y = if (status and FlagX.int) != 0: 0x78 else: 0x3478
    memory.nearFrame()
    memory.putWord(CacheBank + 0xB547, value xor 0xA5A5)
    memory.mem[(direct - 3) and 65535] = 0x6B
    memory.mem[direct] = 0xB6
    var host = Cpu(a: value.uint16, x: x.uint16, y: y.uint16,
      d: direct.uint16, dbr: 0x7E, pbr: 0xC4, pc: 0xFB42, s: 0x1FF0,
      p: status.uint8)
    var steps = 0
    while host.pc != ReturnPc:
      doAssert steps < 20 and host.pbr == 0xC4
      host.step(memory)
      inc steps
    doAssert host.a.int == value and host.x.int == x and host.y.int == y
    doAssert host.d.int == direct and host.dbr == 0x7E and host.s == 0x1FF2
    doAssert memory.ramWord(CacheBank + 0xB547) == 65535
    doAssert memory.ramWord((direct - 2) and 65535) == value
    doAssert memory.mem[(direct - 3) and 65535] == 0x6B and memory.mem[
        direct] == 0xB6
    doAssert memory.mem[0x1FEC] == 0xA7 and memory.mem[0x1FF3] == 0x5A
    let flags = (status and not (FlagM or FlagX or FlagC or FlagV or FlagN or
        FlagZ).int) or
      (if direct >= 16: FlagC.int else: 0)
    doAssert host.p.int == flags
  echo "helper full-word preservation contexts=65536; valid writable scratch and native frames"

proc seedCaches(memory: Bus, seed: int) =
  ## Distinguish all persistent words whose preservation or initialization is observed.
  for address in countup(0xB53B, 0xB549, 2):
    memory.putWord(CacheBank + address, (seed * 97 + address) and 65535)
  memory.putWord(CacheBank + 0xB4B6, 0xACE0)

proc checkPrefix(rom: seq[uint8]) =
  ## Verify every raw package-index byte through the real bank helper, stopping before upload execution.
  let memory = baseBus(rom)
  memory.attach()
  var contexts = 0
  for index in 0 .. 255:
    for direct in [0x80, 0x1000, 0x1800]:
      for status in [0'u8, FlagM or FlagX or FlagC or FlagV or FlagN or FlagZ or FlagI]:
        memory.seedCaches(index)
        memory.farFrame()
        memory.mem[0xC4F70C] = index.uint8 # Authored structural song-table package byte, not code.
        let
          pointer = 0xC4F947 + 3 * index
          bank = memory.mem[pointer].int
          address = memory.mem[pointer + 1].int + 256 * memory.mem[pointer + 2].int
          current = memory.ramWord(CacheBank + 0xB53B)
          completion = memory.ramWord(CacheBank + 0xB549)
        var host = Cpu(a: 0xA55A, x: 0x56, y: 0x78, d: direct.uint16,
          dbr: 0x7E, pbr: 0xC4, pc: 0xFB58, s: 0x1FFC, p: status)
        var steps, helperCalls = 0
        while host.pc != 0xFBB1:
          doAssert steps < 100 and host.pbr == 0xC4
          if host.pc == 0xFB42: inc helperCalls
          host.step(memory)
          inc steps
        doAssert helperCalls == 1 and host.a.int == address and host.x.int == bank
        doAssert host.y.int == 3 * index and host.d.int == direct - 18
        doAssert host.s == 0x1FFA and host.dbr == 0x7E
        doAssert memory.ramWord(CacheBank + 0xB53D) == 65535
        doAssert memory.ramWord(CacheBank + 0xB541) == 65535
        doAssert memory.ramWord(CacheBank + 0xB53F) == index
        doAssert memory.ramWord(CacheBank + 0xB543) == index
        doAssert memory.ramWord(CacheBank + 0xB547) == 65535
        doAssert memory.ramWord(CacheBank + 0xB53B) == current
        doAssert memory.ramWord(CacheBank + 0xB549) == completion
        doAssert memory.ramWord(CacheBank + 0xB4B6) == 0xACE0
        doAssert memory.ramWord(direct - 18 + 0x10) == index
        doAssert memory.ramWord(direct - 18 + 0x0E) == 3 * index
        let flags = (status and FlagI).int or (address and 0x8000) shr 8 or
          (if address == 0: FlagZ.int else: 0)
        doAssert host.p.int == flags
        inc contexts
  echo "initializer raw-index/width/DP prefix contexts=", contexts,
    "; indices169..255 stop before uploader, with no out-of-layout code patched"

proc main() =
  ## Require original and byte-identical rebuilt code; complete upload/return remains in the coldboot gate.
  for index, image in engineImages("bin/apu_resident_init_extract"):
    echo "image=", (if index == 0: "original" else: "fresh rebuild")
    checkHelper(image)
    checkPrefix(image)
  echo "APU resident initializer contracts passed across both images."

when isMainModule:
  main()
