import
  std/strformat,
  decompbound/[apu, cpu, spc700],
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  UploadFile = 0xAB06
  UploadAddress = 0xC0AB06
  UploadLength = 183
  CpuReturn = 0x4000'u16

type UploadBlock = tuple[destination: int, payload: seq[uint8]]

proc appendWord(data: var seq[uint8], word: int) =
  ## Append an authored package word.
  data.add (word and 255).uint8
  data.add ((word shr 8) and 255).uint8

proc runCase(image: seq[uint8], lengths: openArray[int], streamAddress,
    cpuBatch, spcBatch: int, initialBank = 0, initialDirect = 0x3456): int =
  ## Run both original processors through a real resident reset and package transfer.
  let
    machine = newApu()
    memory = newBus()
  for address in DriverStart ..< DriverStart + DriverLength:
    machine.spc.ram[address] = image[DriverMap + address]
  machine.spc.pc = DriverStart.uint16
  var bootInstructions = 0
  while machine.spc.pc != 0x546:
    doAssert bootInstructions < 40000
    let before = machine.spc.cycles
    machine.spc.step()
    machine.tickTimers(machine.spc.cycles - before)
    inc bootInstructions
  for index in 0 ..< UploadLength:
    memory.mem[UploadAddress + index] = image[UploadFile + index]
  var
    blocks: seq[UploadBlock]
    stream: seq[uint8]
  for index, length in lengths:
    let destination = 0x5000 + index * 0x1000 + 0xFF
    var payload = newSeq[uint8](length)
    for byteIndex in 0 ..< length:
      payload[byteIndex] = ((byteIndex * 37 + index * 71 + 3) and 255).uint8
    blocks.add (destination, payload)
    stream.appendWord(length)
    stream.appendWord(destination)
    stream.add payload
  stream.appendWord(0)
  # The indexed long read can cross a source bank while Y itself remains 16-bit.
  let source = 0x7E0000 + streamAddress
  for index, value in stream: memory.mem[source + index] = value
  memory.mem[0x1E] = 0x35
  memory.mem[0x1FD] = 0xFF
  memory.mem[0x1FE] = 0x3F
  memory.mem[0x1FF] = 0xC0
  var
    host = Cpu(a: streamAddress.uint16, x: 0x7E, s: 0x1FC,
      d: initialDirect.uint16, dbr: initialBank.uint8, pbr: 0xC0, pc: 0xAB06, p: FlagI)
    nmiWrites: seq[uint8]
    hostPortWrites = 0
    observedReset, observedReceiver, observedReceiverReturn: int
    cpuInstructions, spcInstructions: int
  memory.readHook = proc(address: uint32): int =
    let
      bank = address shr 16
      offset = address and 65535
    # Wire only the low-WRAM aliases needed by this flat-CPU protocol fixture.
    if offset < 0x2000 and (bank <= 0x3F or bank in 0x80'u32 .. 0xBF'u32 or bank == 0x7E):
      return memory.mem[offset.int].int
    if address in 0x2140'u32 .. 0x2143'u32:
      return machine.portsOut[(address - 0x2140).int].int
    -1
  memory.writeHook = proc(address: uint32, value: uint8): bool =
    let
      bank = address shr 16
      offset = address and 65535
    if offset < 0x2000 and (bank <= 0x3F or bank in 0x80'u32 .. 0xBF'u32 or bank == 0x7E):
      memory.mem[offset.int] = value
      return true
    if address in 0x2140'u32 .. 0x2143'u32:
      machine.portsIn[(address - 0x2140).int] = value
      inc hostPortWrites
      return true
    if address == 0x4200:
      nmiWrites.add value
      return true
    false
  while not (host.pbr == 0xC0 and host.pc == CpuReturn):
    doAssert result < 2_000_000, &"upload stalled host={host.pbr:02X}:{host.pc:04X} " &
      &"SPC={machine.spc.pc:04X} in={machine.portsIn} out={machine.portsOut}"
    for instruction in 0 ..< cpuBatch:
      if host.pbr == 0xC0 and host.pc == CpuReturn: break
      doAssert not host.stopped
      host.step(memory)
      inc cpuInstructions
    for instruction in 0 ..< spcBatch:
      if machine.spc.pc == 0x75E: inc observedReset
      if machine.spc.pc == 0xEE1: inc observedReceiver
      if machine.spc.pc == 0x76E and observedReceiver > 0: inc observedReceiverReturn
      doAssert not machine.spc.stopped
      let before = machine.spc.cycles
      machine.spc.step()
      machine.tickTimers(machine.spc.cycles - before)
      inc spcInstructions
    inc result
  doAssert observedReset == 1 and observedReceiver == 1 and observedReceiverReturn == 1
  doAssert host.s == 0x1FF and host.d.int == initialDirect and host.dbr.int == initialBank
  doAssert (host.p and (FlagM or FlagX or FlagD)) == 0
  doAssert memory.mem[0x1E] == 0xB5 and nmiWrites == @[0x35'u8, 0xB5]
  doAssert host.y.int == stream.len - 2 and host.x == 0
  for index, value in stream: doAssert memory.mem[source + index] == value
  for chunk in blocks:
    for index, value in chunk.payload:
      doAssert machine.spc.ram[chunk.destination + index] == value,
        &"target={chunk.destination + index:04X} actual={machine.spc.ram[chunk.destination + index]:02X} expected={value:02X} " &
        &"CPUY={host.y:04X} CPUX={host.x:04X} SPC={machine.spc.pc:04X} pointer={machine.spc.ram[0x15]:02X}{machine.spc.ram[0x14]:02X}"
    doAssert machine.spc.ram[chunk.destination - 1] == 0
    doAssert machine.spc.ram[chunk.destination + chunk.payload.len] == 0
  echo &"blocks={lengths} source={source:06X} batches={cpuBatch}/{spcBatch} " &
    &"CPU={cpuInstructions} SPC={spcInstructions} hostWrites={hostPortWrites} complete"

proc checkInitialStores(image: seq[uint8]): int =
  ## Prove the initial absolute pointer stores use DBR and ignore incoming direct page.
  let memory = newBus()
  for index in 0 ..< UploadLength:
    memory.mem[UploadAddress + index] = image[UploadFile + index]
  var writes: seq[tuple[address: uint32, value: uint8]]
  memory.writeHook = proc(address: uint32, value: uint8): bool =
    writes.add (address, value)
    true
  for bank in [0, 0x7E, 0x7F, 0xC0]:
    for directPage in [0, 0x3456, 0xFFFF]:
      writes.setLen(0)
      var host = Cpu(a: 0xFFF9, x: 0x7E, s: 0x1FC,
        d: directPage.uint16, dbr: bank.uint8, pbr: 0xC0, pc: 0xAB06, p: FlagI)
      for instruction in 0 ..< 3: host.step(memory)
      doAssert host.pc == 0xAB0E and host.s == 0x1FC
      doAssert host.d.int == directPage and host.dbr.int == bank
      doAssert writes.len == 4
      for index, value in [0xF9'u8, 0xFF, 0x7E, 0]:
        doAssert writes[index] == (((bank shl 16) + 0xC6 + index).uint32, value)
      inc result

proc main() =
  ## Require both images; instruction interleavings test protocol, not physical timing.
  var transfers, pointerContexts: int
  for image in engineImages("bin/apu_resident_upload_extract"):
    pointerContexts += checkInitialStores(image)
    for batches in [(1, 1), (3, 1), (1, 7)]:
      for lengths in [newSeq[int](), @[1], @[255], @[256], @[257], @[1, 257, 511]]:
        discard runCase(image, lengths, 0xFFF9, batches[0], batches[1])
        inc transfers
    for (bank, directPage) in [(0x7E, 0xFFFF), (0x80, 0), (0xBF, 0x3456)]:
      discard runCase(image, [257], 0xFFF9, 1, 3, bank, directPage)
      inc transfers
  echo &"APU resident upload passed: {transfers} complete original/rebuilt two-processor transfers, " &
    &"{pointerContexts} incoming-bank/direct-page store contexts; no audio device."

when isMainModule:
  main()
