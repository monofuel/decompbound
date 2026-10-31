import
  std/algorithm,
  ./[expanded_sprite_frame, expanded_sprite_texture, snesbus]

type
  DisplayedSpriteFrame* = ref object
    ## Own the world bodies and private textures associated with one displayed OAM generation.
    published*: PublishedSpriteFrame
    elements*: seq[ExpandedSpriteElement]
    textures*: seq[SpriteTexturePatch]
  TextureKey = array[10, int]
  ExpandedSpriteTracker* = ref object
    ## Observe native publication without changing entity simulation or hardware memory.
    pending: array[2, DisplayedSpriteFrame]
    active: DisplayedSpriteFrame
    serial: uint64
    reason: string
    phase: array[30, int]
    textureKeys: array[30, TextureKey]
    textures: array[30, SpriteTexturePatch]
  Actor = object
    entity, x, y, worldY, rawGroup, queue: int
    definition: uint32
    elements: seq[ExpandedSpriteElement]

const
  WramBase = 0x7E0000
  PublicationAddress = 0x002C'u16
  GraphicsPhase = 0x2892'u16
  CurrentEntity = 0x1A42
  EntityHead = 0x0A50
  EntityNext = 0x0A9E
  EntityCount = 30
    ## C09282 initializes thirty slots; links are word-array byte offsets.
  EntityWorldX = 0x0B8E
  EntityWorldY = 0x0BCA
  EntityScreenX = 0x0B16
  EntityScreenY = 0x0B52
  EntityHeight = 0x0C06
  EntityGroup = 0x103E
  EntityFrame = 0x10F2
  EntityDefinition = 0x112E
  EntityDefinitionBank = 0x116A
  EntityPositionCallback = 0x11A6
  EntityDrawCallback = 0x11E2
  EntityVariantOffset = 0x2916
  EntityResource = 0x2CD6
  EntityGraphicsEntry = 0x341A
  WorldPosition = 0xA023
  ElevatedWorldPosition = 0xA03A
  WorldDraw = 0xA3A4
  WorldRender = 0xDB0F
    ## C0DB0F dispatches drawing within X=-64..319 and Y=-64..255.
  DrawMin = -64
  DrawMaxX = 320
  DrawMaxY = 256
  OamBytes = 544
  OamBuffers = [0x0500, 0x0800]
  QueueBases = [0x2404, 0x2506, 0x2608, 0x270A]
  DmaModeMask = 0x9F'u8
  TextureFields = [0x2ABA, 0x2A7E, 0x298E, 0x29CA, 0x2A06,
    0x2A42, 0x2AF6, 0x2BAA, 0x341A]
    ## Inputs of C0A4C4/A56E, plus retained entry for all-fill frames.

proc word(snes: SnesBus, offset: int): int =
  ## Read WRAM without invoking MMIO or advancing emulation.
  snes.bus.mem[WramBase + offset].int or (snes.bus.mem[WramBase + offset + 1].int shl 8)

proc signedWord(value: int): int =
  ## Wrap native coordinate arithmetic before widening to presentation space.
  cast[int16]((value and 0xFFFF).uint16).int

proc privateTexture(tracker: ExpandedSpriteTracker, snes: SnesBus,
    entity: int): SpriteTexturePatch =
  ## Cache a reconstruction only after an observed native animation request.
  let slot = entity div 2
  if tracker.phase[slot] < 0: return nil
  var key: TextureKey
  for index, field in TextureFields: key[index] = snes.word(field + entity)
  key[^1] = tracker.phase[slot]
  let immutableSource = key[4] in 0xC0 .. 0xFF and key[5] in 0xC0 .. 0xFF
  if not immutableSource or tracker.textures[slot] == nil or tracker.textureKeys[slot] != key:
    tracker.textures[slot] = prepareSpriteTexture(snes, entity, tracker.phase[slot])
    tracker.textureKeys[slot] = key
  tracker.textures[slot]

proc resolvedQueue(snes: SnesBus, entity: int): int =
  ## Resolve C0A0E3's optional group indirection without its native field writes.
  var group = snes.word(EntityGroup + entity)
  if (group and 0x8000) != 0:
    let target = group and 0x3F
    if target >= EntityCount: return -1
    group = snes.word(EntityGroup + target * 2)
  if group in 0 .. 3: group else: -1

proc bodyDefinition(snes: SnesBus, entity, entry: int): uint32 =
  ## Select the existing runtime definition variant using the graphics entry flag.
  let variant = if (entry and 1) != 0: snes.word(EntityVariantOffset + entity) else: 0
  ((snes.word(EntityDefinitionBank + entity) and 255).uint32 shl 16) or
    ((snes.word(EntityDefinition + entity) + variant) and 0xFFFF).uint32

proc decodeBody(snes: SnesBus, actor: Actor, definition: uint32): seq[ExpandedSpriteElement] =
  ## Reproduce A3A4's two priority groups on copied records, leaving WRAM intact.
  let decoded = decodeSpriteDefinition(snes, definition, actor.x, actor.y, actor.queue)
  if not decoded.valid: return
  let
    counts = snes.word(0x2BE6 + actor.entity)
    first = counts shr 8
    total = first + (counts and 255)
    flags = snes.word(0x2BAA + actor.entity)
  if total != decoded.elements.len: return
  result = decoded.elements
  for index, element in result.mpairs:
    let bit = if index < first: 2 else: 1
    let priority = if (flags and bit) != 0: 0x20 else: 0x30
    element.attributes = ((element.attributes.int and 0xCF) or priority).uint8

proc outsideOriginal(elements: seq[ExpandedSpriteElement], snes: SnesBus): bool =
  ## Keep native textures for any body touching the unchanged original frame.
  const
    Small = [8, 8, 8, 16, 16, 32, 16, 16]
    Large = [16, 32, 64, 32, 64, 64, 32, 32]
  let group = (snes.ppuRegs[1].int shr 5) and 7
  for element in elements:
    let size = if element.large: Large[group] else: Small[group]
    if element.x < 256 and element.y < 224 and element.x + size > 0 and element.y + size > 0:
      return false
  true

proc classify(tracker: ExpandedSpriteTracker, snes: SnesBus,
    frame: PublishedSpriteFrame): DisplayedSpriteFrame =
  ## Extend active ordinary bodies while preserving native queue and actor precedence.
  result = DisplayedSpriteFrame(published: frame)
  if not frame.valid: return
  var
    actors: seq[Actor]
    visited = 0'u32
    entity = snes.word(EntityHead)
  let worldDrawing = snes.word(0x0A5E) == WorldRender and (snes.word(0x0067) and 0x2000) == 0
  while entity != 0xFFFF:
    if entity >= EntityCount * 2 or (entity and 1) != 0:
      frame.valid = false
      frame.reason = "entity-list-range"
      return
    let bit = 1'u32 shl (entity div 2)
    if (visited and bit) != 0:
      frame.valid = false
      frame.reason = "entity-list-cycle"
      return
    visited = visited or bit
    let
      position = snes.word(EntityPositionCallback + entity)
      drawable = snes.word(EntityDefinitionBank + entity) < 0x8000 and
        snes.word(EntityFrame + entity) < 0x8000 and
        snes.word(EntityResource + entity) != 0xFFFF and
        snes.word(EntityDrawCallback + entity) == WorldDraw and
        position in [WorldPosition, ElevatedWorldPosition]
    if drawable:
      var actor = Actor(entity: entity,
        x: signedWord(snes.word(EntityScreenX + entity)),
        y: signedWord(snes.word(EntityScreenY + entity)),
        worldY: snes.word(EntityWorldY + entity),
        rawGroup: snes.word(EntityGroup + entity), queue: snes.resolvedQueue(entity))
      let
        height = if position == ElevatedWorldPosition: snes.word(EntityHeight + entity) else: 0
        expectedX = signedWord(snes.word(EntityWorldX + entity) - frame.camera[0].int)
        expectedY = signedWord(actor.worldY - frame.camera[1].int - height)
      actor.definition = snes.bodyDefinition(entity, snes.word(EntityGraphicsEntry + entity))
      if actor.x == expectedX and actor.y == expectedY:
        for element in frame.elements:
          if element.definition == actor.definition:
            let base = QueueBases[element.queue] + element.entry * 2
            if signedWord(snes.word(base + 0x40)) == actor.x and
                signedWord(snes.word(base + 0x80)) == actor.y:
              actor.elements.add(element)
              actor.queue = element.queue
        let clipped = actor.x < DrawMin or actor.x >= DrawMaxX or
          actor.y < DrawMin or actor.y >= DrawMaxY
        if actor.elements.len == 0 and actor.queue >= 0 and clipped and worldDrawing:
          actor.elements = snes.decodeBody(actor, actor.definition)
        if actor.elements.len > 0:
          if actor.elements.outsideOriginal(snes):
            let texture = tracker.privateTexture(snes, entity)
            if texture != nil:
              let definition = snes.bodyDefinition(entity, texture.entry.int)
              let desired = snes.decodeBody(actor, definition)
              if desired.len > 0 and desired.outsideOriginal(snes):
                actor.elements = desired
                result.textures.add(texture)
                for element in actor.elements.mitems: element.texture = result.textures.len
          actors.add(actor)
    entity = snes.word(EntityNext + entity)
  # C0DB0F draws non-group-one actors first, then stable descending unsigned Y.
  actors.sort(proc(a, b: Actor): int =
    ## Preserve active-list ties and resolve final OAM queue precedence.
    result = cmp(a.queue, b.queue)
    if result == 0:
      result = cmp(ord(a.rawGroup == 1), ord(b.rawGroup == 1))
      if result == 0 and a.rawGroup == 1: result = cmp(b.worldY, a.worldY))
  for actor in actors: result.elements.add(actor.elements)

proc invalidate*(tracker: ExpandedSpriteTracker) =
  ## Retire publication, animation provenance and texture caches after state restoration.
  tracker.pending = default(array[2, DisplayedSpriteFrame])
  tracker.active = nil
  tracker.serial = 0
  tracker.reason = "awaiting-publication"
  for slot in 0 ..< EntityCount:
    tracker.phase[slot] = -1
    tracker.textures[slot] = nil

proc newExpandedSpriteTracker*(): ExpandedSpriteTracker =
  ## Allocate presentation tracking without retaining the live machine.
  result = ExpandedSpriteTracker()
  result.invalidate()

proc publication(tracker: ExpandedSpriteTracker, snes: SnesBus, selector: uint8) =
  ## Freeze definitions before reuse; ignore the NMI's zero acknowledgment.
  if selector notin [1'u8, 2'u8]: return
  tracker.pending[selector.int - 1] = tracker.classify(snes, snapshotPublishedSprites(snes, selector.int))

proc observeWrite(tracker: ExpandedSpriteTracker, snes: SnesBus, address: uint16, value: uint8) =
  ## Observe publication and exact native animation requests before the byte is stored.
  if address == PublicationAddress:
    tracker.publication(snes, value)
  elif address == GraphicsPhase:
    let
      slot = snes.word(CurrentEntity)
      pc = snes.bus.storeInstructionAddress
    if pc == 0xC0A49F:
      # The explicit updater accepts another ID without requiring a scheduler context.
      for phase in tracker.phase.mitems: phase = -1
    elif slot < EntityCount:
      if pc == 0xC0A4A8 or pc == 0xC0A4B5:
        tracker.phase[slot] = value.int
      else:
        tracker.phase[slot] = -1
  else:
    let slot = (address.int - EntityResource) div 2
    tracker.phase[slot] = -1
    tracker.textures[slot] = nil

proc consume(tracker: ExpandedSpriteTracker, snes: SnesBus, event: OamDmaEvent) =
  ## Accept metadata only for the source buffer actually transferred to OAM.
  tracker.active = nil
  tracker.reason = "unsupported-oam-transfer"
  let
    bank = event.source shr 16
    offset = (event.source and 0xFFFF).int
    lowWram = bank == 0x7E or bank <= 0x3F or bank in 0x80'u32 .. 0xBF'u32
  if not event.executed or not lowWram or event.length != OamBytes or
      event.firstAddress != 0 or (event.mode and DmaModeMask) != 0: return
  let lane = if offset == OamBuffers[0]: 0 elif offset == OamBuffers[1]: 1 else: -1
  if lane < 0: return
  let frame = tracker.pending[lane]
  if frame == nil:
    tracker.reason = "awaiting-publication"
    return
  if not frame.published.valid:
    tracker.reason = frame.published.reason
    return
  if frame.published.native != snes.oam:
    tracker.reason = "oam-publication-mismatch"
    return
  tracker.active = frame
  tracker.serial = snes.oamWriteSerial
  tracker.reason = "matched"

proc attach*(tracker: ExpandedSpriteTracker, snes: SnesBus) =
  ## Install observers whose closures retain the tracker, never the live machine.
  if snes.wramWriteObserver != nil or snes.oamDmaObserver != nil or snes.resetObserver != nil:
    raise newException(ValueError, "Presentation observers already have an owner")
  snes.observedWramBytes = {PublicationAddress, GraphicsPhase}
  for address in EntityResource ..< EntityResource + EntityCount * 2:
    snes.observedWramBytes.incl(address.uint16)
  snes.bus.observeStoreInstructions = true
  snes.wramWriteObserver = proc(machine: SnesBus, address: uint16, value: uint8) =
    ## Observe original writes without changing their values or ordering.
    tracker.observeWrite(machine, address, value)
  snes.oamDmaObserver = proc(machine: SnesBus, event: OamDmaEvent) =
    ## Retain the generation consumed by actual OAM DMA.
    tracker.consume(machine, event)
  snes.resetObserver = proc(machine: SnesBus) =
    ## Drop metadata belonging to the pre-reset machine.
    tracker.invalidate()

proc detach*(tracker: ExpandedSpriteTracker, snes: SnesBus) =
  ## Remove observers before switching presentation modes or machines.
  snes.wramWriteObserver = nil
  snes.oamDmaObserver = nil
  snes.resetObserver = nil
  snes.observedWramBytes = {}
  snes.bus.observeStoreInstructions = false
  snes.bus.storeInstructionAddress = 0
  tracker.invalidate()

proc displayed*(tracker: ExpandedSpriteTracker, snes: SnesBus,
    cameraX, cameraY: int): DisplayedSpriteFrame =
  ## Return immutable metadata only while OAM and the displayed camera still match.
  if tracker.active == nil: return nil
  if tracker.serial != snes.oamWriteSerial or tracker.active.published.native != snes.oam:
    tracker.reason = "oam-changed-after-transfer"
    return nil
  let frame = tracker.active
  if frame.published.camera[0] != (cameraX and 0xFFFF).uint16 or
      frame.published.camera[1] != (cameraY and 0xFFFF).uint16:
    tracker.reason = "sprite-camera-mismatch"
    return nil
  tracker.reason = "matched"
  frame

proc status*(tracker: ExpandedSpriteTracker): string =
  ## Explain why a sprite generation is or is not available.
  tracker.reason
