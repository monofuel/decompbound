## Read-only decoder of prepared EarthBound sprite queues at publication.
## Walks queued five-byte definitions without native OAM clipping or machine writes.

import
  std/sets,
  ./[memmap, snesbus]

type
  ExpandedSpriteElement* = object
    ## One queued sprite record in native origin space, including clipped extras.
    x*, y*, tile*, queue*, entry*, texture*: int
    attributes*: uint8
    large*: bool
    definition*: uint32

  PublishedSpriteFrame* = ref object
    ## Snapshot of published queues, native OAM bytes, and scroll lanes.
    valid*: bool
    reason*: string
    selector*: int
    elements*: seq[ExpandedSpriteElement]
    native*: array[544, uint8]
    camera*: array[8, uint16]

const
  QueueBases = [0x2404, 0x2506, 0x2608, 0x270A]
    ## Drain $C08B8E; enqueue $C08C54. Count at base+$100 is a byte index.
  QueueOriginX = 0x40
  QueueOriginY = 0x80
  QueueBank = 0xC0
  QueueCount = 0x100
  MaxQueueBytes = 64
  NativeLow = [0x0500, 0x0800]
    ## Selector 1 uses $0500/$0700; selector 2 uses $0800/$0A00.
  NativeHigh = [0x0700, 0x0A00]
  NativeLowSize = 512
  NativeHighSize = 32
  CameraBase = 0x0041
  CameraStride = 4
  CameraLanes = 8
  RedirectY = 0x80
  LastElementBit = 0x80
  LargeBit = 0x01
  WramBase = 0x7E0000
  LowRamSize = 0x2000
  SystemBankMax = 0x3F
  SystemBankHiMin = 0x80
  SystemBankHiMax = 0xBF
  MaxDefinitionSteps = 65536
  ReasonSelector = "unsupported selector"
  ReasonCount = "malformed queue count"
  ReasonAddress = "unsupported definition address"
  ReasonCycle = "definition cycle"

proc wramByte(snes: SnesBus, offset: int): uint8 =
  ## Read one WRAM byte at $7E0000+offset without the MMIO bus hook.
  snes.bus.mem[WramBase + offset]

proc wramWord(snes: SnesBus, offset: int): int =
  ## Read one little-endian WRAM word at $7E0000+offset.
  snes.wramByte(offset).int or (snes.wramByte(offset + 1).int shl 8)

proc signed8(value: int): int =
  ## Sign-extend an 8-bit displacement.
  let bits = value and 0xFF
  if bits >= 0x80: bits - 0x100 else: bits

proc signed16(value: int): int =
  ## Wrap a sum into signed 16-bit native coordinate space.
  let bits = value and 0xFFFF
  if bits >= 0x8000: bits - 0x10000 else: bits

proc captureNative(snes: SnesBus, frame: PublishedSpriteFrame) =
  ## Copy the selected 544-byte published OAM table and eight scroll lanes.
  let
    index = frame.selector - 1
    low = NativeLow[index]
    high = NativeHigh[index]
    lane = index * 2
  for i in 0 ..< NativeLowSize:
    frame.native[i] = snes.wramByte(low + i)
  for i in 0 ..< NativeHighSize:
    frame.native[NativeLowSize + i] = snes.wramByte(high + i)
  for i in 0 ..< CameraLanes:
    frame.camera[i] = snes.wramWord(CameraBase + i * CameraStride + lane).uint16

proc peekDefinitionByte(snes: SnesBus, bank, offset: int): int =
  ## Read one definition byte from WRAM or ROM. Returns -1 for MMIO and other unsafe addresses.
  if offset < 0 or offset > 0xFFFF: return -1
  let
    defBank = bank and 0xFF
    defOffset = offset and 0xFFFF
    address = (defBank shl 16) or defOffset
  if defBank == 0x7E or defBank == 0x7F:
    return snes.bus.mem[address].int
  if (defBank <= SystemBankMax or
      (defBank >= SystemBankHiMin and defBank <= SystemBankHiMax)) and
      defOffset < LowRamSize:
    return snes.bus.mem[WramBase or defOffset].int
  let fileOffset = snesToFile(address.uint32)
  if fileOffset >= 0 and fileOffset < snes.rom.len:
    return snes.bus.mem[address].int
  result = -1

proc fail(frame: PublishedSpriteFrame, reason: string) =
  ## Mark the snapshot invalid while keeping captured native bytes.
  frame.valid = false
  frame.reason = reason

proc parseDefinition(snes: SnesBus, frame: PublishedSpriteFrame, bank, pointer,
    originX, originY, queue, entry: int, definition: uint32) =
  ## Walk one queued definition, following same-bank redirects until the last flag.
  var
    cursor = pointer and 0xFFFF
    seen = initHashSet[int]()
    steps = 0
  while steps < MaxDefinitionSteps:
    inc steps
    if cursor in seen:
      frame.fail(ReasonCycle)
      return
    seen.incl cursor
    let yByte = snes.peekDefinitionByte(bank, cursor)
    if yByte < 0:
      frame.fail(ReasonAddress)
      return
    if yByte == RedirectY:
      let
        lo = snes.peekDefinitionByte(bank, cursor + 1)
        hi = snes.peekDefinitionByte(bank, cursor + 2)
      if lo < 0 or hi < 0:
        frame.fail(ReasonAddress)
        return
      cursor = lo or (hi shl 8)
      continue
    let
      tile = snes.peekDefinitionByte(bank, cursor + 1)
      attributes = snes.peekDefinitionByte(bank, cursor + 2)
      xByte = snes.peekDefinitionByte(bank, cursor + 3)
      flags = snes.peekDefinitionByte(bank, cursor + 4)
    if tile < 0 or attributes < 0 or xByte < 0 or flags < 0:
      frame.fail(ReasonAddress)
      return
    frame.elements.add ExpandedSpriteElement(
      x: signed16(originX + signed8(xByte)),
      y: signed16(originY + signed8(yByte)),
      tile: tile,
      queue: queue,
      entry: entry,
      attributes: attributes.uint8,
      large: (flags and LargeBit) != 0,
      definition: definition)
    if (flags and LastElementBit) != 0:
      return
    cursor = (cursor + 5) and 0xFFFF
  frame.fail(ReasonCycle)

proc parseQueues(snes: SnesBus, frame: PublishedSpriteFrame) =
  ## Drain all four queues in order, preserving insertion order within each queue.
  for queue, base in QueueBases:
    let count = snes.wramWord(base + QueueCount)
    if (count and 1) != 0 or count > MaxQueueBytes:
      frame.fail(ReasonCount)
      return
    let entries = count div 2
    for entry in 0 ..< entries:
      let
        pointer = snes.wramWord(base + entry * 2)
        originX = snes.wramWord(base + QueueOriginX + entry * 2)
        originY = snes.wramWord(base + QueueOriginY + entry * 2)
        bank = snes.wramWord(base + QueueBank + entry * 2) and 0xFF
        definition = ((bank shl 16) or (pointer and 0xFFFF)).uint32
      snes.parseDefinition(frame, bank, pointer, originX, originY,
        queue, entry, definition)
      if not frame.valid: return

proc validateNative(frame: PublishedSpriteFrame) =
  ## Require decoded native-accepted elements to reproduce the actual published OAM.
  var count = 0
  for element in frame.elements:
    let y = signed16(element.y - 1)
    if y < -32 or y > 223 or element.x < -256 or element.x > 255: continue
    if count == 128: break
    let
      base = count * 4
      packed = (frame.native[512 + count div 4].int shr ((count mod 4) * 2)) and 3
      expected = (if element.x < 0: 1 else: 0) or (if element.large: 2 else: 0)
    if frame.native[base].int != (element.x and 255) or
        frame.native[base + 1].int != (y and 255) or
        frame.native[base + 2].int != element.tile or
        frame.native[base + 3] != element.attributes or packed != expected:
      frame.fail("native-element-mismatch")
      return
    inc count
  for index in count ..< 128:
    if frame.native[index * 4 + 1] != 0xE0:
      frame.fail("native-unused-element-mismatch")
      return

proc snapshotPublishedSprites*(snes: SnesBus, selector: int): PublishedSpriteFrame =
  ## Decode queued sprite definitions at publication without modifying the machine.
  result = PublishedSpriteFrame(valid: true, selector: selector)
  if selector != 1 and selector != 2:
    result.fail(ReasonSelector)
    return
  snes.captureNative(result)
  snes.parseQueues(result)
  if result.valid: result.validateNative()

proc decodeSpriteDefinition*(snes: SnesBus, definition: uint32,
    x, y, queue: int): PublishedSpriteFrame =
  ## Decode an ordinary body privately, without native draw culling or OAM validation.
  result = PublishedSpriteFrame(valid: true)
  snes.parseDefinition(result, (definition shr 16).int,
    (definition and 0xFFFF).int, x, y, queue, -1, definition)
