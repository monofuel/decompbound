## Original-CPU reference for the bestiary portrait integration tests.
##
## Independently executes the gold ROM's decompressor, dimension classifiers,
## palette staging/CGRAM consumer, and 32x32 OAM painter with synthetic WRAM
## (no save-state). Parent tests import `verifyEnemyGraphics` or the decoded
## tile/OAM record procs. Product decoder modules are not imported.
##
## Invoked by tests/integration_bestiary.nim with the user's ROM.

import
  std/[strformat, strutils],
  ../../src/decompbound/[asm_parse, cpu, gfx_lz, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x0200'u32
  StackTop = 0x1FFF'u16
  DirectPage = 0x1A00'u16
  DecompressDp = 0x0000'u16
  DecompressLimit = 1_000_000
  OamLimit = 200_000
  ShortLimit = 20_000
  GfxWindow = 0x10000
  BytesPerTile = 32
  BlockTiles = 4
  SpriteRecordBytes = 5
  MaxOamBlocks = 16

  BattleSpriteTableFile* = 0x0E62EE
  BattleSpriteEntrySize* = 5
  BattleSpriteCount* = 110
  BattlePaletteFile* = 0x0E6514
  BattlePaletteSize* = 32
  BattlePaletteColors* = 16
  BattlePaletteRows* = 32
  EnemyTableFile* = 0x159589
  EnemyRecordSize* = 0x5E
  EnemyIdMax* = 230
  EnemySpriteOff* = 0x1C
  EnemyPaletteOff* = 0x35
  EnemyHpOff* = 0x21
  EnemyPpOff* = 0x23
  EnemyExpOff* = 0x25
  EnemyMoneyOff* = 0x29
  EnemyDropFreqOff* = 0x57
  EnemyDropItemOff* = 0x58
  StarmanSuperId* = 68

  DecompressEntry = 0xC41A9E'u32
  WidthClassifier = 0xEFFD'u16
  HeightClassifier = 0xF04E'u16
  OamPainter = 0xEAEA'u16
  OamBeforeDecompress = 0xEE48'u16
  FarCopy = 0xC08ED2'u32
  HardwareMul = 0xC08FF7'u32
  CgramDmaStart = 0x81C8'u16
  CgramDmaEnd = 0x81F7'u16
  PaletteStage = 0x0300
  OamWork = 0xAAD6
  TileBaseWord = 0xAAB2
  PalSlotWord = 0xAAB4
  ObjDmaRequest = 16
  DestBank7F = 0x7F
  DestOff8000 = 0x8000
  SynthPalSlot = 1

  ## Width/height in 8x8 tiles from $C2EFFD / $C2F04E CMP chains (dim 1..6).
  DimWidthTiles*: array[1..6, int] = [4, 8, 4, 8, 16, 16]
  DimHeightTiles*: array[1..6, int] = [4, 4, 8, 8, 8, 16]

  WidthOp = [0xC2'u8, 0x31, 0x0B, 0x48, 0x7B, 0x69, 0xF2, 0xFF, 0x5B, 0x68,
    0x3A, 0x85, 0x04, 0x0A, 0x0A, 0x65, 0x04, 0xAA, 0xE8, 0xE8, 0xE8, 0xE8,
    0xBF, 0xEE, 0x62, 0xCE]
  PalIndexOp = [0x69'u8, 0x35, 0x00]
  SpriteIndexOp = [0x69'u8, 0x1C, 0x00]
  HpCopyOp = [0xA0'u8, 0x21, 0x00, 0xB7, 0x06]
  PpCopyOp = [0xA0'u8, 0x23, 0x00, 0xB7, 0x06]
  ExpAddOp = [0x69'u8, 0x25, 0x00]
  MoneyAddOp = [0x69'u8, 0x29, 0x00]
  DropItemOp = [0x69'u8, 0x58, 0x00]
  DropFreqOp = [0x69'u8, 0x57, 0x00]
  DecompressOp = [0xA5'u8, 0x0E, 0x8D, 0xCC, 0x00]
  Dest7FOp = [0xA9'u8, 0x00, 0x80, 0x85, 0x06, 0xA9, 0x7F, 0x00, 0x85, 0x08]

type
  OriginalDecodedTiles* = object
    ## Tiles produced by original $C41A9E into $7F8000.
    spriteIndex*: int
    dim*: int
    widthTiles*: int
    heightTiles*: int
    tiles*: seq[uint8]

  OriginalOamEntry* = object
    ## One Y/tile/attributes/X/flags record from $7EAAD6 ($C08CD5 consumer).
    x*: uint8
    tile*: uint8
    attr*: uint8
    y*: uint8
    flags*: uint8

  OriginalOamList* = object
    ## OAM painter output for one dimension representative.
    spriteIndex*: int
    dim*: int
    palSlot*: int
    liveCount*: int
    entries*: seq[OriginalOamEntry]
    uploadedTiles*: seq[uint8]

  EnemyGraphicsCoverage* = object
    ## Non-zero coverage actually executed, not catalog size guesses.
    spritesDecompressed*: int
    palettesStaged*: int
    oamDims*: int
    classifiers*: int
    noSpriteEnemies*: int
    standardSpriteEnemies*: int

proc put8(snes: SnesBus, address: uint32, value: int) =
  ## Write one WRAM byte.
  snes.bus.write8(Wram + address, uint8(value and 0xFF))

proc put16(snes: SnesBus, address: uint32, value: int) =
  ## Write one little-endian WRAM word.
  snes.put8(address, value)
  snes.put8(address + 1, value shr 8)

proc get8(snes: SnesBus, address: uint32): uint8 =
  ## Read one WRAM byte.
  snes.bus.read8(Wram + address)

proc get16(snes: SnesBus, address: uint32): int =
  ## Read one little-endian WRAM word.
  snes.get8(address).int or (snes.get8(address + 1).int shl 8)

proc romU16(rom: openArray[uint8], off: int): int =
  ## Little-endian ROM word.
  rom[off].int or (rom[off + 1].int shl 8)

proc romU24(rom: openArray[uint8], off: int): int =
  ## Little-endian ROM far pointer (low 24 bits).
  rom[off].int or (rom[off + 1].int shl 8) or (rom[off + 2].int shl 16)

proc expectBytes(rom: openArray[uint8], off: int, bytes: openArray[uint8], what: string) =
  ## Require a named opcode sequence at a file offset.
  for i, b in bytes:
    doAssert rom[off + i] == b,
      &"{what} at 0x{off:06X}+{i}: got {rom[off + i]:02X} want {b:02X}"

proc battleSpriteRecord*(rom: openArray[uint8], spriteIndex: int):
    tuple[snes: int, dim: int, fileOff: int] =
  ## Read pointer-table entry `spriteIndex` (0-based): far gfx pointer + dim.
  doAssert spriteIndex >= 0 and spriteIndex < BattleSpriteCount
  let e = BattleSpriteTableFile + spriteIndex * BattleSpriteEntrySize
  let snes = rom.romU24(e)
  let dim = rom[e + 4].int
  result = (snes, dim, snes and 0x3FFFFF)

proc expectedTilesForDim(dim: int): int =
  ## Tile count implied by the original width/height classifiers.
  DimWidthTiles[dim] * DimHeightTiles[dim]

proc expectedBytesForDim(dim: int): int =
  ## Decompressed 4bpp size implied by the classifiers.
  expectedTilesForDim(dim) * BytesPerTile

proc decodeGfxLz(rom: openArray[uint8], fileOff: int): tuple[data: seq[uint8], consumed: int, clean: bool] =
  ## Strict gfx_lz decode of one compressed sprite stream.
  let hi = min(fileOff + GfxWindow, rom.len)
  decodeWithConsumed(rom.toOpenArray(fileOff, hi - 1))

proc runUntil(snes: SnesBus, machine: var Cpu, bank: uint8, pc: uint16, limit: int, what: string) =
  ## Step original code to a named PBR:PC bound.
  var steps = 0
  while machine.pbr != bank or machine.pc != pc:
    doAssert steps < limit, &"{what} did not reach {bank:02X}:{pc:04X} at {machine.pbr:02X}:{machine.pc:04X}"
    machine.step(snes.bus)
    inc steps

proc plant(snes: SnesBus, source: string): uint16 =
  ## Assemble a trampoline at Caller and return the resume PC.
  let code = assembleAsm(source, Caller)
  for i, b in code:
    snes.bus.write8(Caller + i.uint32, b)
  (Caller + code.len.uint32).uint16

proc jsl(snes: SnesBus, target: uint32, a = 0, x = 0, y = 0,
    d = DirectPage, dbr = 0x7E'u8, p = 0'u8, limit = ShortLimit): Cpu {.discardable.} =
  ## Call an original JSL routine and require RTL back to the trampoline.
  let resume = snes.plant(".a16\n.i16\nJSL $" & toHex(target, 6) & "\n")
  result = Cpu(pc: Caller.uint16, s: StackTop, d: d, dbr: dbr, p: p,
    a: a.uint16, x: x.uint16, y: y.uint16)
  snes.runUntil(result, 0, resume, limit, &"JSL ${target:06X}")
  doAssert result.s == StackTop

proc jsrC2(snes: SnesBus, target: uint16, a = 0, x = 0, y = 0,
    d = DirectPage, dbr = 0x7E'u8, limit = ShortLimit): Cpu {.discardable.} =
  ## Call a bank-$C2 RTS routine from PBR $02 (HiROM mirror of $C2).
  let resume = snes.plant(".a16\n.i16\nJSR $" & toHex(target, 4) & "\n")
  result = Cpu(pc: Caller.uint16, s: StackTop, d: d, dbr: dbr, pbr: 0x02,
    a: a.uint16, x: x.uint16, y: y.uint16)
  snes.runUntil(result, 0x02, resume, limit, &"JSR $C2{target:04X}")
  doAssert result.s == StackTop

proc decompressOn(snes: SnesBus, rom: seq[uint8], spriteIndex: int): OriginalDecodedTiles =
  ## Execute $C41A9E on an existing bus for one pointer-table entry.
  let (snesAddr, dim, _) = rom.battleSpriteRecord(spriteIndex)
  doAssert dim >= 1 and dim <= 6, &"sprite {spriteIndex} dim {dim} not in 1..6"
  snes.put16(0x0E, snesAddr and 0xFFFF)
  snes.put16(0x10, snesAddr shr 16)
  snes.put16(0x12, DestOff8000)
  snes.put16(0x14, DestBank7F)
  let want = expectedBytesForDim(dim)
  for i in 0 ..< want + 16:
    snes.bus.write8(0x7F8000'u32 + i.uint32, 0xA5)
  snes.jsl(DecompressEntry, d = DecompressDp, dbr = 0x7E, limit = DecompressLimit)
  result.spriteIndex = spriteIndex
  result.dim = dim
  result.widthTiles = DimWidthTiles[dim]
  result.heightTiles = DimHeightTiles[dim]
  result.tiles = newSeq[uint8](want)
  for i in 0 ..< want:
    result.tiles[i] = snes.bus.read8(0x7F8000'u32 + i.uint32)
  doAssert result.tiles.len == want

proc originalDecompressSprite*(rom: seq[uint8], spriteIndex: int): OriginalDecodedTiles =
  ## Execute $C41A9E for one pointer-table entry into $7F8000.
  decompressOn(newSnesBus(rom), rom, spriteIndex)

proc originalComposeOam*(rom: seq[uint8], spriteIndex, palSlot: int,
                         finishUpload = false): OriginalOamList =
  ## Execute $C2EAEA through the pre-decompress bound and read $7EAAD6 records.
  let (_, dim, _) = rom.battleSpriteRecord(spriteIndex)
  let snes = newSnesBus(rom)
  snes.put16(TileBaseWord, 0)
  snes.put16(PalSlotWord, palSlot)
  for i in 0 ..< MaxOamBlocks * SpriteRecordBytes:
    snes.put8(uint32(OamWork + i), 0)
  discard snes.plant(".a16\n.i16\nJSR $" & toHex(OamPainter, 4) & "\n")
  var machine = Cpu(pc: Caller.uint16, s: StackTop, d: DirectPage, dbr: 0x7E,
    pbr: 0x02, a: uint16(spriteIndex + 1))
  snes.runUntil(machine, 0x02, OamBeforeDecompress, OamLimit, "OAM painter")
  result.spriteIndex = spriteIndex
  result.dim = dim
  result.palSlot = palSlot
  result.entries = newSeq[OriginalOamEntry](MaxOamBlocks)
  let live = (DimWidthTiles[dim] div BlockTiles) * (DimHeightTiles[dim] div BlockTiles)
  result.liveCount = live
  let base = OamWork + palSlot * MaxOamBlocks * SpriteRecordBytes
  for i in 0 ..< MaxOamBlocks:
    let o = base + i * SpriteRecordBytes
    result.entries[i] = OriginalOamEntry(
      x: snes.get8(uint32(o + 3)),
      tile: snes.get8(uint32(o + 1)),
      attr: snes.get8(uint32(o + 2)),
      y: snes.get8(o.uint32),
      flags: snes.get8(uint32(o + 4)))
  if finishUpload:
    snes.runUntil(machine, 0x02, (Caller + 3).uint16, DecompressLimit * 2,
      "OAM painter and tile shuffle")
    doAssert machine.s == StackTop
    result.uploadedTiles = newSeq[uint8](0x2000)
    for i in 0 ..< result.uploadedTiles.len:
      result.uploadedTiles[i] = snes.bus.read8(0x7F0000'u32 + i.uint32)

proc oamPaletteIndex(attr: uint8): int =
  ## OBJ palette field `ppp` from OAM attribute `vhoopppc`.
  (attr.int shr 1) and 7

proc independentBlockGrid(dim: int): seq[tuple[bx, by: int]] =
  ## Row-major 32x32 block coordinates for a dimension code.
  let cols = DimWidthTiles[dim] div BlockTiles
  let rows = DimHeightTiles[dim] div BlockTiles
  for by in 0 ..< rows:
    for bx in 0 ..< cols:
      result.add (bx, by)

proc verifyClassifiers(rom: seq[uint8], snes: SnesBus): int =
  ## JSR the original width/height classifiers for every 1-based sprite id.
  for spriteIndex in 0 ..< BattleSpriteCount:
    let id = spriteIndex + 1
    let (_, dim, _) = rom.battleSpriteRecord(spriteIndex)
    let w = snes.jsrC2(WidthClassifier, a = id)
    doAssert w.a.int == DimWidthTiles[dim],
      &"width id {id} dim {dim}: original {w.a} want {DimWidthTiles[dim]}"
    let h = snes.jsrC2(HeightClassifier, a = id)
    doAssert h.a.int == DimHeightTiles[dim],
      &"height id {id} dim {dim}: original {h.a} want {DimHeightTiles[dim]}"
    inc result
  doAssert result == BattleSpriteCount

proc verifyDecompressors(rom: seq[uint8]): int =
  ## Run original $C41A9E over all 110 assets and match gfx_lz length/bytes/dim.
  var dimHits: array[7, int]
  let snes = newSnesBus(rom)
  for spriteIndex in 0 ..< BattleSpriteCount:
    let (snesAddr, dim, fileOff) = rom.battleSpriteRecord(spriteIndex)
    doAssert snesAddr != 0, &"sprite {spriteIndex} null far pointer"
    doAssert dim >= 1 and dim <= 6, &"sprite {spriteIndex} dim {dim}"
    let lz = rom.decodeGfxLz(fileOff)
    doAssert lz.clean, &"gfx_lz did not terminate for sprite {spriteIndex} @0x{fileOff:06X}"
    doAssert lz.data.len == expectedBytesForDim(dim),
      &"gfx_lz len sprite {spriteIndex} dim {dim}: {lz.data.len} want {expectedBytesForDim(dim)}"
    let orig = decompressOn(snes, rom, spriteIndex)
    doAssert orig.tiles.len == lz.data.len
    doAssert orig.tiles == lz.data,
      &"original $C41A9E != gfx_lz for sprite {spriteIndex} dim {dim} src ${snesAddr:06X}"
    inc dimHits[dim]
    inc result
  doAssert result == BattleSpriteCount
  for dim in 1..6:
    doAssert dimHits[dim] > 0, &"no sprite with dim {dim}"
  doAssert dimHits[6] == 1, &"dim 6 (128x128) count {dimHits[6]} want 1"

proc verifyPalettes(rom: seq[uint8]): int =
  ## Stage every referenced palette row through $C08ED2 and OBJ CGRAM DMA.
  var referenced: array[BattlePaletteRows, int]
  for id in 1 .. EnemyIdMax:
    let pal = rom[EnemyTableFile + id * EnemyRecordSize + EnemyPaletteOff].int
    if pal >= 0 and pal < BattlePaletteRows:
      inc referenced[pal]
  for row in 0 ..< BattlePaletteRows:
    doAssert referenced[row] > 0, &"palette row {row} is never referenced"
    let snes = newSnesBus(rom)
    let src = BattlePaletteFile + row * BattlePaletteSize
    let snesSrc = 0xC00000 + src
    snes.put16(0x0E, snesSrc and 0xFFFF)
    snes.put16(0x10, snesSrc shr 16)
    for i in 0 ..< 256:
      snes.put16(0x0200 + uint32(i * 2), 0x1234)
    snes.jsl(FarCopy, a = PaletteStage + SynthPalSlot * BattlePaletteSize,
      x = BattlePaletteSize, d = DecompressDp, dbr = 0x7E, limit = ShortLimit)
    for i in 0 ..< BattlePaletteColors:
      let got = snes.get16(uint32(PaletteStage + SynthPalSlot * BattlePaletteSize + i * 2))
      let want = rom.romU16(src + i * 2)
      doAssert got == want, &"staged pal row {row} color {i}: {got:04X} != {want:04X}"
    let resume = snes.plant(".a16\n.i16\nJSL $C0856B\n")
    var caller = Cpu(pc: Caller.uint16, s: StackTop,
      a: uint16(0xAB00 or ObjDmaRequest), p: FlagM)
    snes.runUntil(caller, 0, resume, ShortLimit, "CGRAM request")
    doAssert snes.get8(0x30) == ObjDmaRequest.uint8
    for i in 0 ..< 256:
      snes.cgram[i] = 0x5A5A
    var interrupt = Cpu(pbr: 0xC0, pc: CgramDmaStart, s: StackTop, p: FlagX)
    snes.runUntil(interrupt, 0xC0, CgramDmaEnd, ShortLimit, "CGRAM DMA")
    let cgramBase = 128 + SynthPalSlot * BattlePaletteColors
    for i in 0 ..< BattlePaletteColors:
      let got = snes.cgram[cgramBase + i].int
      let want = rom.romU16(src + i * 2)
      doAssert got == want,
        &"CGRAM pal row {row} slot {SynthPalSlot} color {i}: {got:04X} != {want:04X}"
    inc result
  doAssert result == BattlePaletteRows

proc verifyOam(rom: seq[uint8]): int =
  ## Paint one sprite per dimension code, including the unique 128x128.
  var chosen: array[7, int]
  for i in 0 .. chosen.high:
    chosen[i] = -1
  for spriteIndex in 0 ..< BattleSpriteCount:
    let dim = rom.battleSpriteRecord(spriteIndex).dim
    if chosen[dim] < 0:
      chosen[dim] = spriteIndex
  for dim in 1..6:
    doAssert chosen[dim] >= 0, &"missing representative for dim {dim}"
    let list = originalComposeOam(rom, chosen[dim], SynthPalSlot)
    doAssert list.dim == dim
    doAssert list.liveCount == independentBlockGrid(dim).len
    doAssert list.liveCount > 0
    let term = list.entries[list.liveCount - 1]
    doAssert term.flags == 0x81'u8,
      &"dim {dim} sprite {chosen[dim]} terminator flags {term.flags:02X} want 81"
    var xs, ys: seq[uint8]
    for i in 0 ..< list.liveCount:
      let e = list.entries[i]
      doAssert oamPaletteIndex(e.attr) == SynthPalSlot,
        &"dim {dim} block {i} OAM pal {oamPaletteIndex(e.attr)} want {SynthPalSlot} attr={e.attr:02X}"
      doAssert (e.attr and 0x20) != 0, &"dim {dim} block {i} missing priority bit"
      doAssert (e.x and 0x0F) == 0 and (e.y and 0x0F) == 0,
        &"dim {dim} block {i} pos {e.x},{e.y} not 16-pixel aligned"
      if e.x notin xs: xs.add e.x
      if e.y notin ys: ys.add e.y
    if dim == 6:
      doAssert list.liveCount == 16
      doAssert xs.len == 4 and ys.len == 4
      doAssert DimWidthTiles[6] * 8 == 128 and DimHeightTiles[6] * 8 == 128
    inc result
  doAssert result == 6

proc verifyFields(rom: seq[uint8]) =
  ## Confirm named HP/PP/reward/drop/sprite consumers without touching probe_drop_table.
  expectBytes(rom, 0x02EF49, SpriteIndexOp, "sprite index ADC #$001C")
  expectBytes(rom, 0x02EF59, PalIndexOp, "palette ADC #$0035")
  expectBytes(rom, 0x02F007, [0x3A'u8, 0x85, 0x04, 0x0A, 0x0A, 0x65, 0x04],
    "DEC spriteId *5")
  expectBytes(rom, 0x02EFFD, WidthOp, "width classifier head")
  expectBytes(rom, 0x041A9E, DecompressOp, "$C41A9E source pointer install")
  expectBytes(rom, 0x02EDF9, Dest7FOp, "decompress dest $7F8000")
  expectBytes(rom, 0x02B778, HpCopyOp, "battle-init HP LDA [$06],Y +$21")
  expectBytes(rom, 0x02B78C, PpCopyOp, "battle-init PP LDA [$06],Y +$23")
  expectBytes(rom, 0x026345, ExpAddOp, "reward EXP ADC #$0025")
  expectBytes(rom, 0x026260, MoneyAddOp, "reward money ADC #$0029")
  expectBytes(rom, 0x024D92, DropItemOp, "drop item ADC #$0058")
  expectBytes(rom, 0x024DAD, DropFreqOp, "drop freq ADC #$0057")
  let snes = newSnesBus(rom)
  let mul = snes.jsl(HardwareMul, a = StarmanSuperId, y = EnemyRecordSize,
    d = DirectPage, dbr = 0x7E)
  let rec = mul.a.int
  doAssert rec == StarmanSuperId * EnemyRecordSize
  for id in 1 .. EnemyIdMax:
    let source = 0xC00000 + EnemyTableFile + id * EnemyRecordSize
    const Battler = 0x3000
    snes.put16(DirectPage.uint32 + 2, Battler)
    snes.put16(DirectPage.uint32 + 6, source and 65535)
    snes.put16(DirectPage.uint32 + 8, source shr 16)
    var machine = Cpu(pbr: 0xC2, pc: 0xB778, s: StackTop, d: DirectPage, dbr: 0x7E)
    snes.runUntil(machine, 0xC2, 0xB7A0, ShortLimit, "HP/PP initialization copies")
    let
      hp = rom.romU16(EnemyTableFile + id * EnemyRecordSize + EnemyHpOff)
      pp = rom.romU16(EnemyTableFile + id * EnemyRecordSize + EnemyPpOff)
    for offset in [0x11, 0x13, 0x15]:
      doAssert snes.get16(uint32(Battler + offset)) == hp
    for offset in [0x17, 0x19, 0x1B]:
      doAssert snes.get16(uint32(Battler + offset)) == pp

proc countEnemySprites(rom: openArray[uint8]): tuple[standard, none: int] =
  ## Count 1-based sprite ids in enemy records 1..230.
  var used: array[BattleSpriteCount, bool]
  for id in 1 .. EnemyIdMax:
    let off = EnemyTableFile + id * EnemyRecordSize + EnemySpriteOff
    let spriteId = rom.romU16(off)
    if spriteId == 0:
      inc result.none
    else:
      doAssert spriteId >= 1 and spriteId <= BattleSpriteCount,
        &"enemy {id} sprite id {spriteId} out of 1..{BattleSpriteCount}"
      used[spriteId - 1] = true
      inc result.standard
  for i, seen in used:
    doAssert seen, &"pointer-table index {i} is never referenced"
  doAssert result.standard + result.none == EnemyIdMax

proc verifyEnemyGraphics*(rom: seq[uint8]) =
  ## Run the original-CPU enemy-graphics checks; raise if any coverage is zero.
  doAssert rom.len >= EnemyTableFile + (EnemyIdMax + 1) * EnemyRecordSize
  expectBytes(rom, 0x02EFFD, WidthOp, "width classifier present")
  let counts = countEnemySprites(rom)
  verifyFields(rom)
  let snes = newSnesBus(rom)
  var coverage = EnemyGraphicsCoverage(
    noSpriteEnemies: counts.none,
    standardSpriteEnemies: counts.standard)
  coverage.classifiers = verifyClassifiers(rom, snes)
  coverage.spritesDecompressed = verifyDecompressors(rom)
  coverage.palettesStaged = verifyPalettes(rom)
  coverage.oamDims = verifyOam(rom)
  doAssert coverage.spritesDecompressed == BattleSpriteCount
  doAssert coverage.palettesStaged == BattlePaletteRows
  doAssert coverage.oamDims == 6
  doAssert coverage.classifiers == BattleSpriteCount
  doAssert coverage.standardSpriteEnemies == 213
  doAssert coverage.noSpriteEnemies == 17
  echo "Original bestiary code coverage:"
  echo &"  decompress {coverage.spritesDecompressed}/{BattleSpriteCount} via $C41A9E vs gfx_lz"
  echo &"  classifiers {coverage.classifiers}/{BattleSpriteCount} $C2EFFD/$C2F04E"
  echo &"  palettes {coverage.palettesStaged}/{BattlePaletteRows} $C08ED2 + CGRAM request 16"
  echo &"  OAM dims {coverage.oamDims}/6 via $C2EAEA (incl unique 128x128)"
  echo &"  enemies 1..{EnemyIdMax}: {coverage.standardSpriteEnemies} sprites, {coverage.noSpriteEnemies} none"
  echo "  fields: 230 HP/PP initialization copies $C2B778/$C2B78C, EXP $C26345, money $C26260, drop $C24D92/$C24DAD"
