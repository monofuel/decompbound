## Presentation-only reconstruction of a skipped ordinary NPC frame upload.
## Mirrors original $C0A4C4 / $C0A53F / $C0A56E using live WRAM metadata and ROM.

import
  ./[memmap, snesbus]

type
  SpriteTexturePatch* = ref object
    ## Sparse VRAM words original $C0A4C4 would write, plus the retained entry.
    firstWord*: int
    words*: seq[uint16]
    present*: seq[bool]
    entry*: uint16

const
  WramBase = 0x7E0000
  EntityCount = 30
    ## C09282 initializes thirty entity slots; Y is a word-array byte offset.
  EntityDestVram = 0x298E
  EntityEntryList = 0x29CA
  EntityEntryBank = 0x2A06
  EntityGraphicsBank = 0x2A42
  EntityBytesPerChunk = 0x2A7E
  EntityDirection = 0x2AF6
  EntityChunkCount = 0x2ABA
  EntityEffectFlags = 0x2BAA
  EntityGraphicsEntry = 0x341A
  DirectionTable = 0xC0A60B'u32
  FillSource = 0xC40BE8'u32
  MinChunks = 2
  MaxChunks = 10
  MinChunkBytes = 64
  MaxChunkBytes = 256
  PageWords = 0x100
  MaxPatchWords = 0x2000
  VramMask = 0x7FFF
  LowRamSize = 0x2000
  SystemBankMax = 0x3F
  SystemBankHiMin = 0x80
  SystemBankHiMax = 0xBF

proc wramWord(snes: SnesBus, offset: int): int =
  ## Read one little-endian WRAM word without MMIO hooks.
  snes.bus.mem[WramBase + offset].int or (snes.bus.mem[WramBase + offset + 1].int shl 8)

proc peekByte(snes: SnesBus, bank, offset: int): int =
  ## Read one byte from raw WRAM or the supplied ROM. Returns -1 for MMIO and gaps.
  let
    srcBank = bank and 0xFF
    srcOffset = offset and 0xFFFF
    address = (srcBank shl 16) or srcOffset
  if srcBank == 0x7E or srcBank == 0x7F:
    return snes.bus.mem[address].int
  if (srcBank <= SystemBankMax or
      (srcBank >= SystemBankHiMin and srcBank <= SystemBankHiMax)) and
      srcOffset < LowRamSize:
    return snes.bus.mem[WramBase or srcOffset].int
  let fileOffset = snesToFile(address.uint32)
  if fileOffset >= 0 and fileOffset < snes.rom.len:
    return snes.rom[fileOffset].int
  result = -1

proc peekWord(snes: SnesBus, bank, offset: int): int =
  ## Read one little-endian word, wrapping the offset inside its bank.
  let
    lo = snes.peekByte(bank, offset)
    hi = snes.peekByte(bank, (offset + 1) and 0xFFFF)
  if lo < 0 or hi < 0: return -1
  lo or (hi shl 8)

proc advanceDestination(dest, chunkBytes: int): int =
  ## Advance $0097 the way $C0A56E does after one placed chunk.
  if (dest and PageWords) == 0:
    return (dest + PageWords) and 0xFFFF
  let
    delta = ((chunkBytes + 0x20) and 0xFFC0) shr 1
    next = (dest + delta) and 0xFFFF
  if ((next xor dest) and PageWords) == 0:
    return (next - PageWords) and 0xFFFF
  next

proc prepareSpriteTexture*(snes: SnesBus, entityOffset: int, phase: int): SpriteTexturePatch =
  ## Reconstruct the VRAM words original $C0A4C4 would upload for this entity.
  ##
  ## `phase` is the observed request (the value original would read from $2892),
  ## supplied by the caller rather than guessed from $10F2. Returns nil when live
  ## metadata is unsupported or malformed. Reads raw WRAM and the supplied ROM
  ## only; the machine is left unchanged.
  if entityOffset < 0 or entityOffset >= EntityCount * 2 or (entityOffset and 1) != 0:
    return nil
  let
    chunkCount = snes.wramWord(EntityChunkCount + entityOffset)
    chunkBytes = snes.wramWord(EntityBytesPerChunk + entityOffset)
    dest = snes.wramWord(EntityDestVram + entityOffset)
    listOffset = snes.wramWord(EntityEntryList + entityOffset)
    listBank = snes.wramWord(EntityEntryBank + entityOffset) and 0xFF
    graphicsBank = snes.wramWord(EntityGraphicsBank + entityOffset) and 0xFF
    direction = snes.wramWord(EntityDirection + entityOffset)
    effectFlags = snes.wramWord(EntityEffectFlags + entityOffset)
    retained = snes.wramWord(EntityGraphicsEntry + entityOffset).uint16
  if direction > 7:
    return nil
  if chunkCount < MinChunks or chunkCount > MaxChunks:
    return nil
  if chunkBytes < MinChunkBytes or chunkBytes > MaxChunkBytes or (chunkBytes and 1) != 0:
    return nil
  let directionGroup = snes.peekWord(0xC0, (DirectionTable and 0xFFFF).int + direction * 2)
  if directionGroup < 0:
    return nil
  var entryPtr = listOffset and 0xFFFF
  for _ in 0 ..< directionGroup:
    entryPtr = (entryPtr + 4) and 0xFFFF
  if phase != 0:
    entryPtr = (entryPtr + 2) and 0xFFFF
  let entry = snes.peekWord(listBank, entryPtr)
  if entry < 0:
    return nil
  var fillerChunks = 0
  if (entry and 2) == 0 and (effectFlags and 8) != 0:
    fillerChunks = 1
    if (effectFlags and 4) != 0:
      fillerChunks = min(2, chunkCount)
  if fillerChunks > chunkCount:
    fillerChunks = chunkCount
  var fillWord = 0'u16
  if fillerChunks > 0:
    let fillByte = snes.peekByte(0xC4, FillSource.int and 0xFFFF)
    if fillByte < 0:
      return nil
    fillWord = fillByte.uint16 * 0x0101'u16
  let
    sourceOffset = entry and 0xFFF0
    graphicsChunks = chunkCount - fillerChunks
    chunkWords = chunkBytes shr 1
  for chunk in 0 ..< graphicsChunks:
    let base = (sourceOffset + chunk * chunkBytes) and 0xFFFF
    for index in 0 ..< chunkBytes:
      if snes.peekByte(graphicsBank, (base + index) and 0xFFFF) < 0:
        return nil
  var
    written: seq[tuple[address: int, value: uint16]]
    target = dest and 0xFFFF
  written.setLen(chunkCount * chunkWords)
  var writeIndex = 0
  for segment in 0 ..< chunkCount:
    let
      fill = segment < fillerChunks
      graphicsBase = (sourceOffset + (segment - fillerChunks) * chunkBytes) and 0xFFFF
      firstWords = min(chunkWords, PageWords - (target and 0xFF))
    for wordIndex in 0 ..< chunkWords:
      let address = (target + wordIndex + (if wordIndex >= firstWords: PageWords else: 0)) and
        VramMask
      var value = fillWord
      if not fill:
        let word = snes.peekWord(graphicsBank, (graphicsBase + wordIndex * 2) and 0xFFFF)
        if word < 0:
          return nil
        value = word.uint16
      written[writeIndex] = (address, value)
      inc writeIndex
    target = advanceDestination(target, chunkBytes)
  var
    minAddr = written[0].address
    maxAddr = written[0].address
  for item in written:
    if item.address < minAddr: minAddr = item.address
    if item.address > maxAddr: maxAddr = item.address
  let span = maxAddr - minAddr + 1
  if span <= 0 or span > MaxPatchWords:
    return nil
  result = SpriteTexturePatch(
    firstWord: minAddr,
    words: newSeq[uint16](span),
    present: newSeq[bool](span),
    entry: if fillerChunks == chunkCount: retained else: entry.uint16)
  for item in written:
    let index = item.address - minAddr
    result.words[index] = item.value
    result.present[index] = true
