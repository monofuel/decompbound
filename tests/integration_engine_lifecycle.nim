import
  std/[os, strformat],
  decompbound/[asm_parse, cpu, manifest, memmap, rom_pipeline, snesbus],
  ./engine/[original_cpu, sprite_effect_fixture]

type
  Sprite = object
    entity, state, slot, definition, stride, resource, destination: int
    variants: array[2, seq[array[5, uint8]]]

const
  ExtractRoot = "bin/engine_lifecycle_extract"
  Owners = [0, 5]
  ResourceIds = [0, 437]
  ReturnCallback = 0x1D00
  TableBase = 0x6000
  ScriptBase = 0x7F4000'u32
  ScriptSpacing = 0x100'u32
  SetGraphicsOpcode = 0x1C'u8
  SetCallbackOpcode = 0x22'u8
  FrameWaitTwo = 0x82'u8
  NativeCallOpcode = 0x42'u8
  CleanupTarget = 0xC020F1'u32
  RemoveOpcode = 0x00'u8
  WaitOpcode = 0x06'u8
  RenderCallback = 0xA0FA
  ResourcePointers = 0x2F133F
  DirectionOffsets = 0x00A60B
  FrameBufferBytes = 544
  OamCapacity = 128
  RecordBytes = 5

proc romWord(image: seq[uint8], offset: int): int =
  ## Read metadata from the user's rebuilt cartridge image.
  image[offset].int or (image[offset + 1].int shl 8)

proc resourceOffset(image: seq[uint8], resource: int): int =
  ## Resolve a four-byte resource-table entry's original three-byte pointer.
  let offset = ResourcePointers + resource * 4
  snesToFile(image[offset].uint32 or (image[offset + 1].uint32 shl 8) or
    (image[offset + 2].uint32 shl 16))

proc spawn(snes: SnesBus, resource, index: int): Sprite =
  ## Construct a real resource and snapshot its definitions as downstream rendering inputs.
  let owner = Owners[index]
  snes.putWord(DirectPage.int + 0x0E, 64 + index * 96)
  snes.putWord(DirectPage.int + 0x10, 96)
  let state = snes.call("JSL $C01E49", a = resource, x = 0, y = owner)
  doAssert state.a.int == owner
  result.entity = owner
  result.resource = resource
  result.state = snes.word(0x0ADA + owner * 2)
  result.slot = snes.word(0x2952 + owner * 2)
  result.definition = snes.word(0x112E + owner * 2)
  result.stride = snes.word(0x2916 + owner * 2)
  result.destination = snes.word(0x298E + owner * 2)
  doAssert snes.word(0x116A + owner * 2) == 0x7E
  doAssert result.stride > 0 and result.stride mod RecordBytes == 0
  for variant in 0 .. 1:
    for record in 0 ..< result.stride div RecordBytes:
      var bytes: array[RecordBytes, uint8]
      for component in 0 ..< RecordBytes:
        bytes[component] = snes.bus.read8(Wram +
          (result.definition + variant * result.stride + record * RecordBytes + component).uint32)
      result.variants[variant].add bytes

proc installScript(snes: SnesBus, sprite: Sprite, index: int) =
  ## Configure two frames and waits through synthetic VM operands, then remove only the first entity.
  let
    table = TableBase + index * 16
    stream = ScriptBase + index.uint32 * ScriptSpacing
  snes.putWord(table, sprite.definition)
  snes.putWord(table + 2, sprite.definition + sprite.stride)
  var script = @[SetGraphicsOpcode, (table and 255).uint8, (table shr 8).uint8,
    0x7E'u8, SetCallbackOpcode, (RenderCallback and 255).uint8,
    (RenderCallback shr 8).uint8, FrameWaitTwo, 0'u8, FrameWaitTwo, 1'u8]
  if index == 0:
    script.add [SetGraphicsOpcode, (sprite.definition and 255).uint8,
      (sprite.definition shr 8).uint8, 0x7E'u8]
    script.add [NativeCallOpcode, (CleanupTarget and 255).uint8,
      ((CleanupTarget shr 8) and 255).uint8, (CleanupTarget shr 16).uint8, RemoveOpcode]
  else:
    script.add [WaitOpcode, 255'u8]
  snes.putBytes(stream, script)
  snes.putWord(0x13FE + sprite.state, (stream and 0xFFFF).int)
  snes.putWord(0x148A + sprite.state, (stream shr 16).int)
  snes.putWord(0x1372 + sprite.state, 0)
  snes.putWord(0x103E + sprite.entity * 2, 1 - index)

proc expectUpload(image: seq[uint8], expected: var array[0x8000, uint16],
    sprite: Sprite, phase: int): int =
  ## Independently place complete source chunks using the documented transfer dimensions and gaps.
  let
    resource = image.resourceOffset(sprite.resource)
    entryAddress = resource + 9 + image.romWord(DirectionOffsets) * 4 + phase * 2
    entry = image.romWord(entryAddress)
    source = snesToFile((image[resource + 8].uint32 shl 16) or
      (entry and 0xFFF0).uint32)
    count = image[resource].int
    size = image[resource + 1].int * 2
  var destination = sprite.destination
  for chunk in 0 ..< count:
    let firstWords = min(size div 2, 0x100 - (destination and 255))
    for word in 0 ..< size div 2:
      let target = destination + word + (if word >= firstWords: 0x100 else: 0)
      expected[target] = image.romWord(source + chunk * size + word * 2).uint16
    if (destination and 0x100) == 0:
      destination += 0x100
    else:
      destination += ((size + 32) div 64) * 32
      if (destination and 0x100) != 0:
        destination -= 0x100
  entry

proc checkOam(snes: SnesBus, sprites: array[2, Sprite], phase, alive, selector: int) =
  ## Compare queue-ordered publication and hardware OAM with independent signed-coordinate packing.
  var
    expected: seq[array[4, uint8]]
    high: seq[int]
  for index in countdown(sprites.high, 2 - alive):
    for record in sprites[index].variants[phase]:
      let
        x = 64 + index * 96 + cast[int8](record[3]).int
        y = 96 + cast[int8](record[0]).int - 1
      doAssert x in 0 .. 255 and y in -32 .. 223
      expected.add [x.uint8, (y and 255).uint8, record[1], record[2]]
      high.add ((x shr 8) and 1) or ((record[4].int and 1) shl 1)
  let low = if selector == 1: 0x500 else: 0x800
  doAssert snes.word(3) == low + expected.len * 4,
    &"OAM cursor {snes.word(3):04X}, expected {low + expected.len * 4:04X}; " &
    &"phase {phase}, alive {alive}, queues {snes.word(0x2504)}/{snes.word(0x2606)}"
  for index, record in expected:
    for component, value in record:
      doAssert snes.bus.read8(Wram + (low + index * 4 + component).uint32) == value
  for index in expected.len ..< OamCapacity:
    doAssert snes.bus.read8(Wram + (low + index * 4 + 1).uint32) == 0xE0
  for index in 0 ..< (expected.len + 3) div 4:
    var packed = 0
    for pair in 0 ..< 4:
      if index * 4 + pair < high.len:
        packed = packed or (high[index * 4 + pair] shl (pair * 2))
    doAssert snes.bus.read8(Wram + (low + 0x200 + index).uint32) == packed.uint8
  snes.fragment(0x8196, 0x81C8, FlagX)
  for index in 0 ..< FrameBufferBytes:
    doAssert snes.oam[index] == snes.bus.read8(Wram + (low + index).uint32)
  snes.fragment(0x8278, 0x8338, FlagX)
  doAssert snes.word(0x2C) == 0 and snes.word(0x2E) == (selector xor 3)

proc checkLifecycle(image: seq[uint8], resource, firstSelector: int, immediate: bool) =
  ## Follow two real resources through synthetic script timing, publication, removal, and pool reuse.
  let snes = newSnesBus(image)
  snes.call("JSL $C09282")
  snes.call("JSL $C01A86")
  snes.call("JSL $C01C11", a = 0x8000)
  snes.putBytes(ReturnCallback.uint32, assembleAsm("RTS\n", ReturnCallback.uint32))
  snes.putWord(0x0A5E, ReturnCallback)
  snes.bus.write8(Wram + 0x0D, 0x80)
  var sprites: array[2, Sprite]
  for index in 0 .. 1:
    sprites[index] = snes.spawn(resource, index)
    snes.installScript(sprites[index], index)
  doAssert sprites[0].state == 0 and sprites[1].state == 2
  doAssert sprites[0].slot == 0 and sprites[1].slot > 0
  snes.putWord(0x2E, firstSelector)
  var expectedVram = snes.vram
  for tick in 0 ..< 5:
    let
      phase = min(tick div 2, 1)
      alive = if tick == 4: 1 else: 2
      selector = snes.word(0x2E)
      previousVram = snes.vram
      transfers = snes.dmaTransfers
    snes.initHdma()
    snes.call("JSL $C088B1")
    snes.call("JSL $C09466", directPage = 0x300)
    doAssert snes.word(0x0A60) == 0
    if tick == 4:
      doAssert snes.word(0x0A50) == Owners[1] * 2
      doAssert snes.word(0x0A52) == Owners[0] * 2 and snes.word(0x0A54) == 0
      doAssert snes.word(0x0A62) == 0xFFFF and snes.word(0x2CD6) == 0xFFFF
      doAssert snes.vram == previousVram and snes.dmaTransfers == transfers
    else:
      for sprite in sprites:
        doAssert snes.word(0x10F2 + sprite.entity * 2) == phase
        doAssert snes.word(0x1372 + sprite.state) == 1 - tick mod 2
    snes.bus.write8(Wram + 0x0D, (if immediate: 0x80'u8 else: 0'u8))
    for index in 2 - alive .. 1:
      snes.putWord(DirectPage.int + 0x88, sprites[index].entity * 2)
      snes.call("JSR $A0E3", x = sprites[index].entity * 2)
      snes.putWord(0x2892, phase)
      snes.call("JSL $C0A4C4", y = sprites[index].entity * 2)
      let entry = image.expectUpload(expectedVram, sprites[index], phase)
      doAssert snes.word(0x341A + sprites[index].entity * 2) == entry
    if not immediate:
      snes.fragment(0x8238, 0x8278)
      doAssert snes.bus.read8(Wram) == snes.bus.read8(Wram + 1)
    doAssert snes.vram == expectedVram, &"Resource {resource}, tick {tick}, immediate {immediate}"
    snes.call("JSL $C08B26")
    snes.checkOam(sprites, phase, alive, selector)
  let survivor = snes.word(0x112E + Owners[1] * 2)
  snes.bus.write8(Wram + 0x0D, 0x80)
  let replacement = snes.spawn(resource, 0)
  doAssert replacement.state == sprites[0].state and replacement.slot == sprites[0].slot
  doAssert replacement.definition == sprites[0].definition
  doAssert snes.word(0x0A50) == Owners[1] * 2
  doAssert snes.word(0x0A9E + Owners[1] * 2) == Owners[0] * 2
  doAssert snes.word(0x112E + Owners[1] * 2) == survivor
  doAssert snes.bus.read8(Wram + (0x4A00 + sprites[1].slot).uint32) == (Owners[1] or 0x80).uint8

proc checkDefaultLifecycle(image: seq[uint8], firstSelector: int) =
  ## Follow default motion, projection and effects through the native draw loop and publication.
  const
    Actors = [5, 23]
    Flags = [10, 5]
    Heights = [3, 7]
    Velocities = [[0x00018000'u32, 0xFFFF8000'u32],
      [0xFFFFC000'u32, 0x00014000'u32]]
    BodyBase = 0x5000
    BodyBank = 0x7F
    BodySpacing = 0x20
    CameraX = 32
    CameraY = 40
    ExpectedQueueEntries = 5
  let snes = newSnesBus(syntheticEffectsImage(image))
  snes.call("JSL $C09282")
  var coordinates: array[2, array[2, uint64]]
  for index, actor in Actors:
    let
      offset = actor * 2
      worldX = 100 + index * 50
      worldY = 120 + index * 30
      pointer = BodyBase + index * BodySpacing
    snes.putWord(0x0A4C, actor)
    snes.putWord(0x0A4E, actor + 1)
    snes.putWord(0x0A48, Heights[index])
    snes.call("JSL $C09321", a = 0, x = worldX, y = worldY)
    let state = snes.word(0x0ADA + offset)
    snes.putWord(0x1372 + state, 250)
    snes.putWord(0x10B6 + offset, 0x8000)
    snes.putWord(0x10F2 + offset, 0)
    snes.putWord(0x112E + offset, pointer)
    snes.putWord(0x116A + offset, BodyBank)
    snes.putWord(0x11A6 + offset, if index == 0: 0xA023 else: 0xA03A)
    snes.putWord(0x2BE6 + offset, 0x0101)
    snes.putWord(0x2BAA + offset, Flags[index])
    snes.putWord(0x2E7A + offset, if index == 0: 0 else: 0xC000)
    snes.putWord(0x2A7E + offset, 0x40)
    snes.putWord(0x103E + offset, if index == 0: 0 else: 0xC000 or Actors[0])
    snes.seedEffects(actor)
    coordinates[index] = [(worldX.uint64 shl 16) or 0x8000,
      (worldY.uint64 shl 16) or 0x8000]
    for axis in 0 .. 1:
      snes.putWord([0x0CF6, 0x0D32][axis] + offset, (Velocities[index][axis] shr 16).int)
      snes.putWord([0x0DAA, 0x0DE6][axis] + offset, (Velocities[index][axis] and 0xFFFF).int)
    for record in 0 .. 1:
      let bytes = [0'u8, (0x20 + index * 2 + record).uint8,
        (if record == 0: 0xA5'u8 else: 0x4B'u8), (record * 8).uint8,
        (if record == 1: 0x80'u8 else: 0'u8)]
      snes.putBytes((BodyBank shl 16 or (pointer + record * RecordBytes)).uint32, bytes)
  snes.putWord(0x0A5E, 0xDB0F)
  snes.putWord(0x67, 0)
  snes.putWord(0x31, CameraX)
  snes.putWord(0x33, CameraY)
  snes.putWord(0x2E, firstSelector)
  for tick in 0 .. 6:
    let selector = snes.word(0x2E)
    snes.call("JSL $C088B1")
    snes.call("JSL $C09466", directPage = 0x300)
    doAssert snes.word(0x0A60) == 0
    var expected: seq[array[4, uint8]]
    for index, actor in Actors:
      let
        offset = actor * 2
        phase = if tick mod 5 < 3: 0 else: 1
      for axis in 0 .. 1:
        coordinates[index][axis] = (coordinates[index][axis] +
          Velocities[index][axis].uint64) and 0xFFFFFFFF'u64
        doAssert snes.word([0x0B8E, 0x0BCA][axis] + offset) ==
          (coordinates[index][axis] shr 16).int
      let
        x = (coordinates[index][0] shr 16).int - CameraX
        y = (coordinates[index][1] shr 16).int - CameraY -
          (if index == 1: Heights[index] else: 0)
      doAssert snes.word(0x0B16 + offset) == x
      doAssert snes.word(0x0B52 + offset) == y
      for lane in selectedEffects(actor, Flags[index], if index == 0: 0 else: 0xC000, 0x40):
        let variant = Flags[index] and 1
        expected.add [x.uint8, (y - 1).uint8,
          (0x40 + lane * 8 + phase * 3 + variant).uint8, 0xA5'u8]
      for record in 0 .. 1:
        let
          groupBit = if record == 0: 2 else: 1
          priority = if (Flags[index] and groupBit) != 0: 0x20 else: 0x30
          attribute = if record == 0: 0xA5 else: 0x4B
        expected.add [(x + record * 8).uint8, (y - 1).uint8,
          (0x20 + index * 2 + record).uint8, ((attribute and 0xCF) or priority).uint8]
      doAssert snes.word(0x1372 + snes.word(0x0ADA + offset)) == 249 - tick
    doAssert snes.word(0x2504) == ExpectedQueueEntries * 2
    doAssert snes.word(0x103E + Actors[1] * 2) == (0xC000 or Actors[0])
    snes.call("JSL $C08B26")
    let low = if selector == 1: 0x500 else: 0x800
    doAssert snes.word(3) == low + expected.len * 4
    for index, record in expected:
      for component, value in record:
        doAssert snes.bus.read8(Wram + (low + index * 4 + component).uint32) == value,
          &"default lifecycle tick {tick}, entry {index}, component {component}"
    for index in expected.len ..< OamCapacity:
      doAssert snes.bus.read8(Wram + (low + index * 4 + 1).uint32) == 0xE0
    snes.fragment(0x8196, 0x81C8, FlagX)
    for index in 0 ..< FrameBufferBytes:
      doAssert snes.oam[index] == snes.bus.read8(Wram + (low + index).uint32)
    snes.fragment(0x8278, 0x8338, FlagX)

proc main() =
  ## Execute the integrated scenarios from freshly assembled source and local extraction.
  let
    gold = readGoldBaserom()
    layout = parseManifestFile("manifest.json")
  createDir(ExtractRoot)
  discard extractRegions(layout, gold, ExtractRoot)
  let rebuilt = rebuildRom(layout, ExtractRoot)
  doAssert romsEqual(rebuilt, gold)
  for resource in ResourceIds:
    for selector in 1 .. 2:
      for immediate in [false, true]:
        rebuilt.checkLifecycle(resource, selector, immediate)
  for image in [gold, rebuilt]:
    for selector in 1 .. 2:
      image.checkDefaultLifecycle(selector)
  echo "engine lifecycle: 8 resource scenarios and 4 seven-tick default callback scenarios passed"

when isMainModule:
  main()
