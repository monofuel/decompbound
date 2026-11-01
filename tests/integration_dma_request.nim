import
  std/strformat,
  decompbound/[asm_parse, cpu, snesbus],
  ./engine/[original_cpu, rebuilt_rom]

type
  Request = tuple[size, source, destination, profile: int]

const
  SourceBank = 0x7F
  SourceBase = 0x4000
  Destination = 0x6000
  OldDestination = 0x7000
  Sentinel = 0x5A5A'u16
  StepLimit = 20000
  QueueBase = 0x400
  QueueBytes = 256
  RecordBytes = 8
  FrameBudget = 0x1200

proc sourceByte(offset: int): uint8 =
  ## Generate test bytes independently of DMA registers and cartridge assets.
  ((offset * 37 + 11) and 255).uint8

proc putRequest(snes: SnesBus, index: int, request: Request) =
  ## Encode one authored eight-byte pending ring record.
  let address = QueueBase + index
  snes.bus.write8(Wram + address.uint32, request.profile.uint8)
  snes.putWord(address + 1, request.size)
  snes.putWord(address + 3, request.source)
  snes.bus.write8(Wram + (address + 5).uint32, SourceBank.uint8)
  snes.putWord(address + 6, request.destination)

proc applyRequest(expected: var array[0x8000, uint16], request: Request) =
  ## Place source bytes into destination words, preserving an odd transfer's last high byte.
  for index in 0 ..< request.size:
    let
      source = request.source - SourceBase + (if request.profile == 3: 0 else: index)
      value = sourceByte(source).uint16
      address = request.destination + index div 2
    if index mod 2 == 0:
      expected[address] = (expected[address] and 0xFF00) or value
    else:
      expected[address] = (expected[address] and 0xFF) or (value shl 8)

proc servicePending(snes: SnesBus) =
  ## Execute the original ring consumer and its actual NMI budget-reset instructions.
  snes.fragment(0x8238, 0x8278)
  snes.fragment(0x834E, 0x8352)
  doAssert snes.bus.read8(Wram) == snes.bus.read8(Wram + 1)
  doAssert snes.word(0x99) == 0

proc checkRequest(snes: SnesBus, head, size, profile, oldBudget: int,
    ringFull, immediate, fast: bool, status: uint8) =
  ## Verify complete producer calls, including deliberate waits resumed by real consumer code.
  let request: Request = (size, SourceBase, Destination, profile)
  var
    pending: seq[Request]
    tail = head
  if ringFull:
    tail = (head + RecordBytes) mod QueueBytes
    for index in 0 ..< 31:
      pending.add (2, SourceBase + index * 2, OldDestination + index, 0)
      snes.putRequest((tail + index * RecordBytes) mod QueueBytes, pending[^1])
  elif oldBudget > 0:
    tail = (head + QueueBytes - RecordBytes) mod QueueBytes
    pending.add (oldBudget, SourceBase, OldDestination, 0)
    snes.putRequest(tail, pending[0])
  let initialBudget = if ringFull: 62 else: oldBudget
  var expected: array[0x8000, uint16]
  for value in expected.mitems:
    value = Sentinel
  for value in snes.vram.mitems:
    value = Sentinel
  snes.initHdma()
  for index in 0 ..< FrameBudget + 2:
    snes.bus.write8(((SourceBank shl 16) + SourceBase + index).uint32, sourceByte(index))
  snes.bus.write8(Wram, head.uint8)
  snes.bus.write8(Wram + 1, tail.uint8)
  snes.bus.write8(Wram + 0x0D, if immediate: 0x80'u8 else: 0'u8)
  snes.bus.write8(Wram + 0x91, profile.uint8)
  snes.putWord(0x92, size)
  snes.putWord(0x94, SourceBase)
  snes.bus.write8(Wram + 0x96, SourceBank.uint8)
  snes.putWord(0x97, Destination)
  snes.putWord(0x99, initialBudget)
  snes.putWord(0xA1, 0x2000)
  snes.putWord(0xA3, 0x2200)
  snes.putWord(0x9E2B, 0xBEEF)
  snes.putBytes(Caller, assembleAsm("JSL $C0" & (if fast: "865B" else: "8643") & "\n", Caller))
  let
    originalD = if fast: 0'u16 else: 0x300'u16
    originalBank = if fast: 0'u8 else: 0x7F'u8
    originalY = if fast: 0x1234'u16 else: 0x89'u16
    transfers = snes.dmaTransfers
  var
    state = Cpu(pc: Caller.uint16, s: StackTop, d: originalD, dbr: originalBank,
      a: 0xA55A, x: 0x67, y: originalY, p: status)
    steps = 0
    visits = 0
    interrupted = false
  while state.pbr != 0 or state.pc != (Caller + 4).uint16:
    doAssert steps < StepLimit, "DMA request did not return after scheduled consumer progress"
    let waiting = state.pbr == 0xC0 and
      ((state.pc == 0x8671 and snes.word(0x99) != 0) or state.pc == 0x869D)
    if waiting:
      inc visits
      doAssert not immediate and snes.bus.read8(Wram) == head.uint8
      if state.pc == 0x869D:
        doAssert snes.word(QueueBase + head + 1) == size
      if visits == 3:
        snes.servicePending()
        for old in pending:
          expected.applyRequest(old)
        interrupted = true
    state.step(snes.bus)
    inc steps
  doAssert state.s == StackTop and state.d == originalD and state.dbr == originalBank
  doAssert state.p == status
  doAssert state.y == (if fast: originalY else: 0'u16)
  doAssert snes.word(0x92) == size and snes.word(0x94) == SourceBase
  doAssert snes.word(0x97) == Destination
  if immediate:
    doAssert not interrupted and snes.bus.read8(Wram) == head.uint8
    doAssert snes.word(0x99) == initialBudget
    doAssert snes.word(0xA1) == 0x2200 and snes.word(0x9E2B) == 0
  else:
    doAssert interrupted == (ringFull or (oldBudget > 0 and oldBudget + size > FrameBudget))
    doAssert snes.bus.read8(Wram) == ((head + RecordBytes) mod QueueBytes).uint8
    let expectedBudget = if ringFull: 0 elif interrupted: size else: initialBudget + size
    doAssert snes.word(0x99) == expectedBudget
    doAssert snes.word(0xA1) == 0x2000 and snes.word(0x9E2B) == 0xBEEF
    let address = QueueBase + head
    doAssert snes.bus.read8(Wram + address.uint32) == profile.uint8
    doAssert snes.word(address + 1) == size and snes.word(address + 3) == SourceBase
    doAssert snes.bus.read8(Wram + (address + 5).uint32) == SourceBank.uint8
    doAssert snes.word(address + 6) == Destination
    snes.servicePending()
    if not interrupted:
      for old in pending:
        expected.applyRequest(old)
  expected.applyRequest(request)
  doAssert snes.vram == expected, &"head {head}, size {size}, profile {profile}, immediate {immediate}"
  doAssert snes.dmaTransfers == transfers + pending.len + 1

proc main() =
  ## Check status widths, profiles, wrap, budget threshold and full-ring backpressure on both ROMs.
  var cases = 0
  for image in engineImages("bin/dma_request_extract"):
    let snes = newSnesBus(image)
    for status in 0 .. 255:
      if (status and FlagD.int) != 0:
        continue
      for profile in [0, 3]:
        for head in [0, 0xF8]:
          for immediate in [false, true]:
            snes.checkRequest(head, 32, profile, 0, false, immediate, false, status.uint8)
            inc cases
      if (status and (FlagM or FlagX).int) == 0:
        snes.checkRequest(0xF8, 32, 0, 0, false, false, true, status.uint8)
        inc cases
    for profile in [0, 3]:
      for head in [0, 0xF8]:
        for size in [32, FrameBudget, FrameBudget + 1]:
          for oldBudget in [0, FrameBudget - 32, FrameBudget]:
            snes.checkRequest(head, size, profile, oldBudget, false, false, false, 0)
            inc cases
        snes.checkRequest(head, 32, profile, 0, true, false, false, 0)
        inc cases
  echo &"DMA producer: {cases} original/rebuilt context, transfer and backpressure cases passed"

when isMainModule:
  main()
