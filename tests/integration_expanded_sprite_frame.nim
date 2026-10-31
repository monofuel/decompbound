import
  std/strformat,
  decompbound/[asm_parse, cpu, expanded_sprite_frame, rom_pipeline, snesbus]

const
  InitCaller = 0x0200'u32
  EnqueueCaller = 0x0210'u32
  PublishCaller = 0x0220'u32
  StackTop = 0x1FFF'u16
  Wram = 0x7E0000'u32
  Definitions = 0x3000
  AltBank = 0x7F
  QueueBases = [0x2404, 0x2506, 0x2608, 0x270A]
  Sentinel = 0x5A'u8
  HiddenY = 0xE0'u8
  StepLimit = 100000
  NativeYMin = -32
  NativeYMax = 223
  NativeXMin = -256
  NativeXMax = 255
  MaxAccepted = 128

type
  AuthoredElement = object
    dx, dy: int
    tile: uint8
    attributes: uint8
    large, last: bool

  MachineCopy = object
    wram: seq[uint8]
    oam: array[544, uint8]
    ppuRegs: array[0x100, uint8]
    bgScroll: array[8, uint16]

proc putWord(snes: SnesBus, address, value: int) =
  ## Install a synthetic WRAM word.
  snes.bus.write8(Wram + address.uint32, (value and 255).uint8)
  snes.bus.write8(Wram + address.uint32 + 1, ((value shr 8) and 255).uint8)

proc signed8(value: int): int =
  ## Sign-extend an authored 8-bit displacement.
  let bits = value and 0xFF
  if bits >= 0x80: bits - 0x100 else: bits

proc signed16(value: int): int =
  ## Wrap a coordinate into signed 16-bit space.
  let bits = value and 0xFFFF
  if bits >= 0x8000: bits - 0x10000 else: bits

proc nativeAccepted(x, y: int): bool =
  ## Reproduce the original emitter's coarse X/Y acceptance independently.
  let nativeY = signed16(y - 1)
  result = nativeY >= NativeYMin and nativeY <= NativeYMax and
    x >= NativeXMin and x <= NativeXMax

proc lsrCarry(value: var int): int =
  ## One 8-bit LSR, returning the outgoing carry.
  result = value and 1
  value = value shr 1

proc packedBytes(elements: seq[ExpandedSpriteElement]): seq[uint8] =
  ## Independently pack accepted X-high/size bits the way publication finalizes them.
  var
    acc = 0x80
    pending = 0
  for element in elements:
    acc = ((if element.x < 0: 1 else: 0) shl 7) or (acc shr 1)
    acc = ((if element.large: 1 else: 0) shl 7) or (acc shr 1)
    inc pending
    if pending == 4:
      result.add acc.uint8
      acc = 0x80
      pending = 0
  if pending == 0:
    if result.len < 32:
      result.add 0x80
  else:
    var bits = acc
    while true:
      discard lsrCarry(bits)
      if lsrCarry(bits) != 0:
        result.add bits.uint8
        break

proc captureMachine(snes: SnesBus): MachineCopy =
  ## Copy WRAM and PPU shadows so decoder reads can be proven side-effect free.
  MachineCopy(wram: snes.bus.mem[Wram.int ..< 0x800000], oam: snes.oam,
    ppuRegs: snes.ppuRegs, bgScroll: snes.bgScroll)

proc checkFrozen(snes: SnesBus, before: MachineCopy, label: string) =
  ## Fail if snapshotPublishedSprites wrote memory or PPU state.
  doAssert snes.bus.mem[Wram.int ..< 0x800000] == before.wram, label & " WRAM"
  doAssert snes.oam == before.oam, label & " OAM"
  doAssert snes.ppuRegs == before.ppuRegs, label & " PPU"
  doAssert snes.bgScroll == before.bgScroll, label & " scroll"

proc run(snes: SnesBus, caller: uint32, a = 0, x = 0, y = 0) =
  ## Execute an original ROM routine through a synthetic long-call trampoline.
  var
    cpu = Cpu(pc: caller.uint16, s: StackTop, dbr: 0x7E,
      a: a.uint16, x: x.uint16, y: y.uint16)
    steps = 0
  while cpu.pbr != 0 or cpu.pc != (caller + 4).uint16:
    doAssert steps < StepLimit, "original routine failed to return"
    cpu.step(snes.bus)
    inc steps
  doAssert cpu.s == StackTop and cpu.d == 0 and cpu.dbr == 0x7E
  doAssert (cpu.p and (FlagM or FlagX)) == 0

proc flagsByte(element: AuthoredElement): uint8 =
  ## Pack size and last-element bits, leaving bits 1-6 unused.
  result = (if element.large: 1'u8 else: 0'u8) or
    (if element.last: 0x80'u8 else: 0'u8) or 0x2C'u8

proc writeDefinition(snes: SnesBus, bank, pointer: int, records: openArray[AuthoredElement]) =
  ## Store a tiny authored definition in WRAM, never ROM graphics.
  for i, record in records:
    let address = ((bank shl 16) or ((pointer + i * 5) and 0xFFFF)).uint32
    snes.bus.write8(address, record.dy.uint8)
    snes.bus.write8(address + 1, record.tile)
    snes.bus.write8(address + 2, record.attributes)
    snes.bus.write8(address + 3, record.dx.uint8)
    snes.bus.write8(address + 4, record.flagsByte)

proc writeRedirect(snes: SnesBus, bank, pointer, target: int) =
  ## Store a same-bank $80 redirect to another 16-bit address.
  let address = ((bank shl 16) or (pointer and 0xFFFF)).uint32
  snes.bus.write8(address, 0x80)
  snes.bus.write8(address + 1, (target and 255).uint8)
  snes.bus.write8(address + 2, ((target shr 8) and 255).uint8)

proc prepareBuffers(snes: SnesBus, selector: int) =
  ## Fill both OAM buffers and scroll lanes with sentinels before original init.
  for address in 0x500 ..< 0xB00:
    snes.bus.write8(Wram + address.uint32, Sentinel)
  for address in 0x41 ..< 0x61:
    snes.bus.write8(Wram + address.uint32, Sentinel)
  for i in 0 ..< 8:
    snes.putWord(0x31 + i * 2, 0xB000 + i)
  snes.putWord(0x2E, selector)
  snes.putWord(0x2C, 0xA500)

proc initialize(snes: SnesBus, selector: int) =
  ## Run original initializeOamBuild for one published buffer.
  snes.prepareBuffers(selector)
  snes.run(InitCaller)
  snes.bus.write8(Wram + 9, (if selector == 1: 0'u8 else: 0x7E'u8))

proc enqueue(snes: SnesBus, queue, pointer, originX, originY, bank: int) =
  ## Run original enqueue with an authored definition pointer.
  snes.putWord(0x2400, queue)
  snes.putWord(0x0B, bank)
  snes.run(EnqueueCaller, pointer, originX, originY)

proc publish(snes: SnesBus) =
  ## Run original publishOamBuild.
  snes.run(PublishCaller)

proc snapshot(snes: SnesBus, selector: int, label: string): PublishedSpriteFrame =
  ## Decode after publication and prove the decoder did not write.
  let before = snes.captureMachine()
  result = snapshotPublishedSprites(snes, selector)
  snes.checkFrozen(before, label)

proc checkNative(frame: PublishedSpriteFrame) =
  ## Compare decoder-accepted elements against published native OAM independently.
  doAssert frame.valid, frame.reason
  var accepted: seq[ExpandedSpriteElement]
  for element in frame.elements:
    if nativeAccepted(element.x, element.y):
      accepted.add element
      if accepted.len == MaxAccepted:
        break
  let packed = packedBytes(accepted)
  for slot in 0 ..< 128:
    let base = slot * 4
    if slot < accepted.len:
      let element = accepted[slot]
      doAssert frame.native[base] == (element.x and 255).uint8
      doAssert frame.native[base + 1] == ((element.y - 1) and 255).uint8
      doAssert frame.native[base + 2] == element.tile.uint8
      doAssert frame.native[base + 3] == element.attributes
    else:
      doAssert frame.native[base + 1] == HiddenY
  for i, value in packed:
    if i < 32:
      doAssert frame.native[512 + i] == value, &"high {i} {frame.native[512 + i]:02X} != {value:02X}"

proc expectedElement(queue, entry, originX, originY: int, record: AuthoredElement,
    definition: uint32): ExpandedSpriteElement =
  ## Build the signed expanded coordinate the decoder must preserve.
  ExpandedSpriteElement(
    x: signed16(originX + signed8(record.dx)),
    y: signed16(originY + signed8(record.dy)),
    tile: record.tile.int,
    queue: queue,
    entry: entry,
    attributes: record.attributes,
    large: record.large,
    definition: definition)

proc checkElement(actual, expected: ExpandedSpriteElement) =
  ## Require every expanded field, including clipped extras, to match the authored record.
  doAssert actual.x == expected.x
  doAssert actual.y == expected.y
  doAssert actual.tile == expected.tile
  doAssert actual.queue == expected.queue
  doAssert actual.entry == expected.entry
  doAssert actual.attributes == expected.attributes
  doAssert actual.large == expected.large
  doAssert actual.definition == expected.definition

proc installTrampolines(snes: SnesBus) =
  ## Plant original-ROM long calls in bank-zero scratch.
  for entry in [(InitCaller, "C088B1"), (EnqueueCaller, "C08C54"),
      (PublishCaller, "C08B26")]:
    let code = assembleAsm(".a16\n.i16\nJSL $" & entry[1] & "\n", entry[0])
    for i, value in code:
      snes.bus.write8(entry[0] + i.uint32, value)

proc checkEmpty(snes: SnesBus) =
  ## An initialized empty publication is valid and parks every native Y.
  for selector in 1 .. 2:
    snes.initialize(selector)
    snes.publish()
    let frame = snes.snapshot(selector, "empty")
    doAssert frame.valid
    doAssert frame.elements.len == 0
    doAssert frame.selector == selector
    for i in 0 ..< 8:
      doAssert frame.camera[i] == (0xB000 + i).uint16
    frame.checkNative()

proc checkAcceptedAndOffscreen(snes: SnesBus) =
  ## Keep clipped extras while matching native on the accepted prefix.
  let
    visible = AuthoredElement(dx: 4, dy: 8, tile: 0x21, attributes: 0x13, last: false)
    clipped = AuthoredElement(dx: 0, dy: 0x81, tile: 0x22, attributes: 0x31,
      large: true, last: true)
  snes.initialize(1)
  snes.writeDefinition(0x7E, Definitions, [visible, clipped])
  snes.enqueue(2, Definitions, 40, 60, 0x7E)
  snes.publish()
  let frame = snes.snapshot(1, "offscreen")
  doAssert frame.elements.len == 2
  frame.elements[0].checkElement(expectedElement(2, 0, 40, 60, visible, 0x7E3000'u32))
  frame.elements[1].checkElement(expectedElement(2, 0, 40, 60, clipped, 0x7E3000'u32))
  doAssert nativeAccepted(frame.elements[0].x, frame.elements[0].y)
  doAssert not nativeAccepted(frame.elements[1].x, frame.elements[1].y)
  frame.checkNative()

proc checkRedirect(snes: SnesBus) =
  ## Follow a same-bank redirect and keep the originating queued pointer.
  let body = AuthoredElement(dx: 1, dy: 2, tile: 0x44, attributes: 0x80, last: true)
  snes.initialize(1)
  snes.writeRedirect(0x7E, Definitions, Definitions + 8)
  snes.writeDefinition(0x7E, Definitions + 8, [body])
  snes.enqueue(0, Definitions, 16, 24, 0x7E)
  snes.publish()
  let frame = snes.snapshot(1, "redirect")
  doAssert frame.elements.len == 1
  frame.elements[0].checkElement(expectedElement(0, 0, 16, 24, body, 0x7E3000'u32))
  frame.checkNative()

proc checkNegativeWrap(snes: SnesBus) =
  ## Preserve signed origins, 16-bit wrap, and native X-high packing.
  let
    left = AuthoredElement(dx: 0, dy: 0, tile: 0x10, attributes: 0x01, last: true)
    wrap = AuthoredElement(dx: 0x20, dy: 0, tile: 0x11, attributes: 0x02, last: true)
    signedDisp = AuthoredElement(dx: 0xFF, dy: 0xFF, tile: 0x12, attributes: 0x03,
      last: true)
  snes.initialize(2)
  snes.writeDefinition(0x7E, Definitions, [left])
  snes.writeDefinition(0x7E, Definitions + 5, [wrap])
  snes.writeDefinition(0x7E, Definitions + 10, [signedDisp])
  snes.enqueue(0, Definitions, 0xFFF0, 0xFFF0, 0x7E)
  snes.enqueue(1, Definitions + 5, 0x00F0, 40, 0x7E)
  snes.enqueue(1, Definitions + 10, 0, 0, 0x7E)
  snes.publish()
  let frame = snes.snapshot(2, "wrap")
  doAssert frame.elements.len == 3
  frame.elements[0].checkElement(expectedElement(0, 0, 0xFFF0, 0xFFF0, left, 0x7E3000'u32))
  frame.elements[1].checkElement(expectedElement(1, 0, 0x00F0, 40, wrap, 0x7E3005'u32))
  frame.elements[2].checkElement(expectedElement(1, 1, 0, 0, signedDisp, 0x7E300A'u32))
  doAssert frame.elements[0].x == -16 and frame.elements[0].y == -16
  doAssert frame.elements[1].x == 272
  doAssert not nativeAccepted(frame.elements[1].x, frame.elements[1].y)
  doAssert frame.elements[2].x == -1 and frame.elements[2].y == -1
  frame.checkNative()

proc checkQueueOrder(snes: SnesBus) =
  ## Drain queues 0-3 regardless of interleaved enqueue order.
  snes.initialize(1)
  for i in 0 ..< 4:
    let record = AuthoredElement(dx: i, dy: 0, tile: (0x30 + i).uint8,
      attributes: 0x20, last: true)
    snes.writeDefinition(0x7E, Definitions + i * 5, [record])
    snes.enqueue(3 - i, Definitions + i * 5, i * 8, 32, 0x7E)
  snes.publish()
  let frame = snes.snapshot(1, "order")
  doAssert frame.elements.len == 4
  for queue in 0 ..< 4:
    let i = 3 - queue
    frame.elements[queue].checkElement(expectedElement(queue, 0, i * 8, 32,
      AuthoredElement(dx: i, dy: 0, tile: (0x30 + i).uint8, attributes: 0x20,
        last: true), (0x7E3000 + i * 5).uint32))
  frame.checkNative()

proc checkCapacity(snes: SnesBus) =
  ## Keep definitions past the native 128-sprite ceiling.
  var records: array[2, AuthoredElement]
  records[0] = AuthoredElement(dx: 0, dy: 0, tile: 0x40, attributes: 0x05, last: false)
  records[1] = AuthoredElement(dx: 8, dy: 0, tile: 0x41, attributes: 0x05,
    large: true, last: true)
  snes.initialize(1)
  var next = Definitions
  for queue in 0 ..< 4:
    for entry in 0 ..< 32:
      snes.writeDefinition(0x7E, next, records)
      snes.enqueue(queue, next, (entry mod 8) * 8, 16 + queue, 0x7E)
      next += 10
  snes.publish()
  let frame = snes.snapshot(1, "capacity")
  doAssert frame.elements.len == 256
  doAssert nativeAccepted(frame.elements[127].x, frame.elements[127].y)
  doAssert nativeAccepted(frame.elements[128].x, frame.elements[128].y)
  frame.checkNative()
  var accepted = 0
  for element in frame.elements:
    if nativeAccepted(element.x, element.y):
      inc accepted
  doAssert accepted == 256

proc writeBankByte(snes: SnesBus, bank, offset: int, value: uint8) =
  ## Store one authored definition byte with 16-bit wrap inside a WRAM bank.
  snes.bus.write8(((bank shl 16) or (offset and 0xFFFF)).uint32, value)

proc writeWrappedDefinition(snes: SnesBus, bank, pointer: int,
    records: openArray[AuthoredElement]) =
  ## Store records whose 16-bit pointer may wrap, matching INY-within-bank.
  for i, record in records:
    let base = (pointer + i * 5) and 0xFFFF
    snes.writeBankByte(bank, base, record.dy.uint8)
    snes.writeBankByte(bank, base + 1, record.tile)
    snes.writeBankByte(bank, base + 2, record.attributes)
    snes.writeBankByte(bank, base + 3, record.dx.uint8)
    snes.writeBankByte(bank, base + 4, record.flagsByte)

proc checkPointerWrap(snes: SnesBus) =
  ## Follow a two-record definition whose second record wraps to $0000 in bank $7F.
  let
    first = AuthoredElement(dx: 3, dy: 5, tile: 0x55, attributes: 0x11, last: false)
    second = AuthoredElement(dx: 6, dy: 7, tile: 0x56, attributes: 0x12, last: true)
  snes.initialize(1)
  snes.writeWrappedDefinition(AltBank, 0xFFFB, [first, second])
  snes.enqueue(0, 0xFFFB, 8, 9, AltBank)
  snes.publish()
  let frame = snes.snapshot(1, "pointer-wrap")
  doAssert frame.elements.len == 2
  frame.elements[0].checkElement(expectedElement(0, 0, 8, 9, first, 0x7FFFFB'u32))
  frame.elements[1].checkElement(expectedElement(0, 0, 8, 9, second, 0x7FFFFB'u32))
  frame.checkNative()

proc checkMalformedCount(snes: SnesBus) =
  ## Odd and oversize byte counts are invalid and must not execute definitions.
  snes.initialize(1)
  snes.putWord(QueueBases[0] + 0x100, 3)
  var frame = snes.snapshot(1, "odd-count")
  doAssert not frame.valid
  doAssert frame.reason == "malformed queue count"
  snes.putWord(QueueBases[0] + 0x100, 0)
  snes.putWord(QueueBases[2] + 0x100, 66)
  frame = snes.snapshot(1, "huge-count")
  doAssert not frame.valid
  doAssert frame.reason == "malformed queue count"

proc checkCycle(snes: SnesBus) =
  ## A self-redirect is cycle-safe and does not run the original emitter.
  snes.initialize(1)
  snes.writeRedirect(0x7E, Definitions, Definitions)
  snes.putWord(QueueBases[0], Definitions)
  snes.putWord(QueueBases[0] + 0x40, 0)
  snes.putWord(QueueBases[0] + 0x80, 0)
  snes.putWord(QueueBases[0] + 0xC0, 0x7E)
  snes.putWord(QueueBases[0] + 0x100, 2)
  let frame = snes.snapshot(1, "cycle")
  doAssert not frame.valid
  doAssert frame.reason == "definition cycle"

proc checkUnsupportedAddress(snes: SnesBus) =
  ## MMIO definition pointers are rejected without peeking hardware ports.
  snes.initialize(1)
  snes.putWord(QueueBases[1], 0x2104)
  snes.putWord(QueueBases[1] + 0x40, 0)
  snes.putWord(QueueBases[1] + 0x80, 0)
  snes.putWord(QueueBases[1] + 0xC0, 0)
  snes.putWord(QueueBases[1] + 0x100, 2)
  let before = snes.oam
  let frame = snes.snapshot(1, "mmio")
  doAssert not frame.valid
  doAssert frame.reason == "unsupported definition address"
  doAssert snes.oam == before

proc checkInvalidSelector(snes: SnesBus) =
  ## Only published selectors 1 and 2 are readable.
  snes.initialize(1)
  snes.publish()
  let before = snes.captureMachine()
  for selector in [0, 3, 255]:
    let frame = snapshotPublishedSprites(snes, selector)
    doAssert not frame.valid
    doAssert frame.reason == "unsupported selector"
    doAssert frame.selector == selector
    doAssert frame.elements.len == 0
  snes.checkFrozen(before, "selector")

proc main() =
  ## Cross-check the decoder against original initialize/enqueue/publish on authored defs.
  let snes = newSnesBus(readGoldBaserom())
  snes.installTrampolines()
  snes.checkEmpty()
  snes.checkAcceptedAndOffscreen()
  snes.checkRedirect()
  snes.checkNegativeWrap()
  snes.checkQueueOrder()
  snes.checkCapacity()
  snes.checkPointerWrap()
  snes.checkMalformedCount()
  snes.checkCycle()
  snes.checkUnsupportedAddress()
  snes.checkInvalidSelector()

when isMainModule:
  main()
