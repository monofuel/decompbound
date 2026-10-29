import
  std/strformat

const
  FirstWorldMapStoryFlag* = 1
  LastWorldMapStoryFlag* = 0x7FFF
  StoryFlagByteCount = 0x1000
  BitsPerByte = 8

type
  WorldMapStoryState* = object
    ## Own numbered event bits by value, leaving the original wrapped zero flag clear.
    bits: array[StoryFlagByteCount, uint8]
  WorldMapFlag* = object
    ## Describe one ROM-referenced map condition without shipping its asset data.
    id*: int
    label*, description*: string

proc requireFlag(id: int) =
  ## Reject non-numbered conditions before indexing the fixed event-bit store.
  if id notin FirstWorldMapStoryFlag .. LastWorldMapStoryFlag:
    raise newException(ValueError, "Map story flag must be inside 1..0x7FFF.")

proc flagEnabled*(state: WorldMapStoryState, id: int): bool =
  ## Read one numbered flag using the original getter's one-based bit numbering.
  requireFlag(id)
  let index = id - FirstWorldMapStoryFlag
  (state.bits[index div BitsPerByte] and (1'u8 shl (index mod BitsPerByte))) != 0

proc setStoryFlag*(state: var WorldMapStoryState, id: int, enabled: bool) =
  ## Set or clear one event bit without sharing mutable storage between state values.
  requireFlag(id)
  let
    index = id - FirstWorldMapStoryFlag
    byteIndex = index div BitsPerByte
    mask = 1'u8 shl (index mod BitsPerByte)
  if enabled:
    state.bits[byteIndex] = state.bits[byteIndex] or mask
  else:
    state.bits[byteIndex] = state.bits[byteIndex] and not mask

proc enabledFlags*(state: WorldMapStoryState): seq[int] =
  ## Enumerate enabled numbered flags in stable ascending order.
  for id in FirstWorldMapStoryFlag .. LastWorldMapStoryFlag:
    if state.flagEnabled(id): result.add(id)

proc storyFlagMetadata*(id: int): WorldMapFlag =
  ## Label verified identities while leaving unresolved conditions explicitly numeric.
  requireFlag(id)
  result = WorldMapFlag(id: id, label: &"Flag ${id:04X}",
    description: "Original map palette or arrangement condition; story meaning is unresolved.")
  case id
  of 0x000D:
    result.label = "Happy Happy Village"
    result.description = "Changes the village palette after defeating Carpainter."
  of 0x00AE:
    result.label = "Dusty Dunes mines"
    result.description = "Changes the mine arrangements in Dusty Dunes Desert."
  of 0x0174:
    result.label = "Flashback house colors"
    result.description = "Off: gray. On: lighting via $0205."
  of 0x0205:
    result.label = "House interior lighting"
    result.description = "On: lit. Off: dark. Flashback needs $0174."
  of 0x022B:
    result.label = "Fourside store blackout"
    result.description = "Department store blackout after Paula is kidnapped."
  of 0x01A6:
    result.label = "Onett daylight"
    result.description = "Set for the original daytime Onett palette; clear for its night palette."
  of 0x011F:
    result.label = "Winters lighting"
    result.description = "On: bright snow palette. Off: dark Winters palette."
  of 0x0044:
    result.label = "Peaceful Rest Valley bridge"
    result.description = "On: repaired bridge. Also changes related interior arrangements."
  of 0x0047:
    result.label = "Threed / Saturn ladder"
    result.description = "On: daytime Threed and the completed Saturn Valley ladder."
  of 0x0120:
    result.label = "Deep Darkness revealed"
    result.description = "On: revealed swamp. Off: the original shrouded palette."
  else: discard
