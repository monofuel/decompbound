import
  std/[unittest],
  decompbound/[battle_bg_catalog, common]

const
  GroupBase = 0x10C60D
  ListsBase = 0x10D52D
  ListsEnd = 0x10DFB4
  PairBase = 0x0BD89A

proc putWord(bytes: var seq[uint8], offset, value: int) =
  ## Write an authored little-endian fixture word.
  bytes[offset] = uint8(value and 255)
  bytes[offset + 1] = uint8(value shr 8)

proc fixture(): seq[uint8] =
  ## Make a synthetic ROM with terminated, initially empty group lists.
  result = newSeq[uint8](EarthboundRomSize)
  result[ListsBase] = 255
  for group in 0 ..< BattleGroupCount:
    putWord(result, GroupBase + group * 8, ListsBase and 65535)
    result[GroupBase + group * 8 + 2] = 0xD0

proc members(bytes: var seq[uint8], group, offset: int,
             entries: openArray[tuple[count, enemy: int]], a = 1, b = 2, letterbox = 0) =
  ## Assign independently authored members and encounter metadata to a group.
  putWord(bytes, GroupBase + group * 8, offset and 65535)
  bytes[GroupBase + group * 8 + 7] = uint8(letterbox)
  putWord(bytes, PairBase + group * 4, a)
  putWord(bytes, PairBase + group * 4 + 2, b)
  for i, entry in entries:
    bytes[offset + i * 3] = uint8(entry.count)
    putWord(bytes, offset + i * 3 + 1, entry.enemy)
  bytes[offset + entries.len * 3] = 255

suite "Enemy background catalog":
  test "spawned members, ordered pairs and encounter context determine variants":
    var bytes = fixture()
    bytes.members(2, ListsBase + 1, [(0, 1), (1, 2), (2, 2)])
    bytes.members(3, ListsBase + 12, [(1, 2)], letterbox = 4)
    bytes.members(4, ListsBase + 16, [(1, 2)], a = 2, b = 1)
    bytes.members(5, ListsBase + 20, [(1, 2)], letterbox = 1)
    bytes.members(6, ListsBase + 24, [(1, 3)], a = 0, b = 0)
    let catalog = newBackgroundCatalog(bytes)
    check catalog.enemies.len == 230
    check catalog.enemyIndex(1) == 0
    check catalog.enemyIndex(230) == 229
    check catalog.enemyIndex(231) == -1
    check catalog.enemies[0].variants.len == 0
    check catalog.enemies[1].variants.len == 3
    check catalog.enemies[1].variants[0].groupIds == @[2, 3]
    check catalog.enemies[1].variants[1].layerA == 2
    check catalog.enemies[1].variants[1].layerB == 1
    check catalog.enemies[1].variants[2].letterbox == 1
    check catalog.enemies[2].variants[0].layerA == 0
    check catalog.enemies[2].variants[0].layerB == 0
    check newBackgroundCatalog(newSeq[uint8](512) & bytes).enemies[1].variants.len == 3

  test "corrupt pointers, unterminated lists, ids and layers fail loudly":
    var bytes = fixture()
    bytes[GroupBase + 2] = 0
    expect ValueError: discard newBackgroundCatalog(bytes)
    bytes = fixture()
    bytes.members(0, ListsEnd - 4, [(1, 1)])
    bytes[ListsEnd - 1] = 1
    expect ValueError: discard newBackgroundCatalog(bytes)
    bytes = fixture()
    bytes.members(0, ListsBase + 1, [(1, 231)])
    expect ValueError: discard newBackgroundCatalog(bytes)
    bytes = fixture()
    bytes.members(0, ListsBase + 1, [(1, 1)], a = BackgroundLayerCount)
    expect ValueError: discard newBackgroundCatalog(bytes)
    expect ValueError: discard newBackgroundCatalog([1'u8, 2, 3])
