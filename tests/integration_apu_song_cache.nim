## Original song-loader cache branching, not package transfer or song validity.
## Authored row bytes cover the full byte domain, including values outside the
## nominal package table. Execution stops before upload or song-command calls.
import
  decompbound/cpu,
  ./engine/rebuilt_rom

const
  SongId = 160
  SongRow = 0xC4F70A + (SongId - 1) * 3
  Caller = 0xC04000
  UploadBoundary = 0xC4FCAF
  CommandBoundary = 0xC4FD0E
  CacheBase = 0x7EB53B

proc putWord(bus: Bus, address, value: int) =
  ## Author a structural word without passing through hardware hooks.
  bus.mem[address] = (value and 255).uint8
  bus.mem[address + 1] = (value shr 8).uint8

proc word(bus: Bus, address: int): int =
  ## Read an authored or produced little-endian word.
  bus.mem[address].int or (bus.mem[address + 1].int shl 8)

proc mirroredBus(): Bus =
  ## Map low bank-zero WRAM coherently, leaving all hardware as inert flat memory.
  result = newBus()
  let bus = result
  bus.readHook = proc(address: uint32): int =
    if address < 0x2000: return bus.mem[0x7E0000 + address.int].int
    -1
  bus.writeHook = proc(address: uint32, value: uint8): bool =
    if address < 0x2000:
      bus.mem[0x7E0000 + address.int] = value
      return true
    false

proc checkCacheMatrix(image: seq[uint8]): int =
  ## Execute a genuine JSL and original loader/helper instructions to exact external boundaries.
  let bus = mirroredBus()
  for offset in 0 ..< 65536:
    bus.mem[0xC40000 + offset] = image[0x40000 + offset]
  # Authored caller supplies the original JSL frame; no original instruction is patched.
  for index, value in [0x22'u8, 0xBD, 0xFB, 0xC4]:
    bus.mem[Caller + index] = value
  for requested in 0 .. 255:
    for alternate in [7, 255, 65535]:
      for mutable in [5, 7, 65535]:
        bus.mem[SongRow] = 255
        bus.mem[SongRow + 1] = requested.uint8
        bus.mem[SongRow + 2] = 255
        bus.putWord(CacheBase, 65535)
        bus.putWord(0x7EB4B6, 1) # Bypass the unrelated warm-path port-three command.
        bus.putWord(0x7EB53D, 0x1357)
        bus.putWord(0x7EB53F, mutable)
        bus.putWord(0x7EB541, 0x2468)
        bus.putWord(0x7EB543, alternate)
        bus.putWord(0x7EB547, 0xA55A)
        var host = Cpu(a: SongId, pc: 0x4000, pbr: 0xC0, dbr: 0x7E,
          d: 0x1F00, s: 0x1FFF)
        host.step(bus)
        doAssert host.pbr == 0xC4 and host.pc == 0xFBBD and host.s == 0x1FFC
        doAssert bus.mem[0x7E1FFF] == 0xC0 and bus.word(0x7E1FFD) == 0x4003
        var steps, helperEntries = 0
        while ((host.pbr.uint32 shl 16) or host.pc.uint32) notin
            [UploadBoundary.uint32, CommandBoundary.uint32]:
          doAssert host.pbr == 0xC4 and steps < 200
          if host.pc == 0xFB42: inc helperEntries
          host.step(bus)
          inc steps
        let skipped = requested == 255 or requested == mutable or requested == alternate
        doAssert (host.pc == 0xFD0E) == skipped
        doAssert helperEntries == (if skipped: 0 else: 1)
        doAssert bus.word(0x7EB53F) == (if skipped: mutable else: requested)
        doAssert bus.word(0x7EB543) == alternate
        doAssert bus.word(CacheBase) == SongId
        doAssert bus.word(0x7EB53D) == 0x1357 and bus.word(0x7EB541) == 0x2468
        doAssert bus.word(0x7EB547) == (if skipped: 0xA55A else: 65535)
        doAssert host.s == 0x1FFA and host.d == 0x1EEC and host.dbr == 0x7E
        doAssert bus.mem[0x7E1FFF] == 0xC0 and bus.word(0x7E1FFD) == 0x4003
        inc result

proc checkReset(image: seq[uint8]) =
  ## Run original reset through both forward fills, with coherent low-WRAM aliases and no device.
  let bus = mirroredBus()
  for offset in 0x8000 .. 0x8111: bus.mem[0xC00000 + offset] = image[offset]
  for address in 0x7E0000 .. 0x7EFFFF: bus.mem[address] = 0xA5
  bus.putWord(0x7EB543, 0x1234)
  bus.putWord(0x7FB543, 0x5678)
  var host = Cpu(pc: 0x8000, pbr: 0xC0, p: FlagM or FlagX)
  var steps = 0
  while host.pc != 0x8112:
    doAssert steps < 150 and host.pbr == 0xC0
    host.step(bus)
    inc steps
  doAssert host.s == 0x1FFF and host.d == 0x1F00 and host.dbr == 0x7E
  doAssert host.x == 0xFFFF and host.y == 0 and host.a == 0xFFFF
  doAssert bus.word(0x7EB543) == 0 and bus.word(0x7FB543) == 0x5678
  # The hardware-initialization prefix writes its $80 display shadow after the low fill.
  for address in 0x7E0000 .. 0x7EFFFF:
    doAssert bus.mem[address] == (if address == 0x7E000D: 0x80'u8 else: 0'u8)

proc main() =
  ## Require both original and independently byte-identical rebuilt images.
  var contexts, resets = 0
  for image in engineImages("bin/apu_song_cache_extract"):
    let count = checkCacheMatrix(image)
    doAssert count == 2304
    contexts += count
    checkReset(image)
    inc resets
  echo "APU song cache passed: ", contexts, " branching contexts and ", resets,
    " original reset-fill contexts across original/rebuilt images; transfers not executed."

when isMainModule:
  main()
