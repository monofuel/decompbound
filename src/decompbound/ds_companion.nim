import
  pixie,
  ./[eb_ui_assets, eb_ui_font, eb_ui_frame, eb_ui_meters, item_table,
    party_sram, party_wram, ppu]

type
  DsItem* = object
    id*: int
    name*: string
    encodedName*: seq[uint8]
    equipped*: bool
  DsMember* = object
    id*: int
    name*: string
    encodedName*: seq[uint8]
    hp*, hpMax*, pp*, ppMax*: int
    hpFraction*, ppFraction*: uint16
    conditions*: array[CharConditionsLen, uint8]
    framePalette*: uint16
    inventory*: array[CharInventoryLen, DsItem]
  DsParty* = seq[DsMember]
  DsPointer* = object
    x*, y*: int16
    pressed*: bool
  DsCompanion* = ref object
    image*: Image
    assets: EbUiAssets
    names: array[256, string]
    encodedNames: array[256, seq[uint8]]
    colors: array[32, ColorRGBA]
    flavor: int
    tracking: int
    party: DsParty
    selectedId*: int
    lastTriggers: uint16
    pointerHeld: bool
    rendered: bool

const
  DsPanelWidth* = 256
  DsPanelHeight* = 224
  DsCombinedHeight* = DsPanelHeight * 2
  PreviousMember* = 1'u16 shl 12
  NextMember* = 1'u16 shl 13
  TileSize = 8
  StatusWidthTiles = 7
  StatusHeightTiles = 8
  StatusSelectedRow = 18
  StatusRestingRow = 19
  GoodsX = 32
  GoodsY = 8
  GoodsWidthTiles = 24
  GoodsHeightTiles = 16
  GoodsColumns = 2
  GoodsColumnWidth = 88
  GoodsTextInset = 16
  GoodsTextWidth = 80
  GoodsRowHeight = 16
  EquipmentTopTile = 0x2C42'u16
  EquipmentBottomTile = 0x2C52'u16
  NameTileFirst = 0x2A0
  NameTileEnd = 0x2C0
  EmptyNameTopTile = 7'u16
  TileIndexMask = 0x03FF'u16
  PaletteShift = 10
  HeaderTileFirst = 0x2E0
  HeaderTileEnd = 0x2F0
  NameFont = 2
  StatusNameInset = 2
  HeaderFont = 3
  GoodsFont = 0
  PointerMaximum = 32767
  EbStorageBias = 0x30
  BattlePartyPointer = 0x4DC8

proc word(wram: openArray[uint8], offset: int): int =
  ## Read a little-endian unsigned word from a validated party buffer.
  wram[offset].int or (wram[offset + 1].int shl 8)

proc partyBattleVisible*(wram: openArray[uint8], bgMode: int): bool =
  ## Recognize the existing mode-0 battle view with a playable battler pointer.
  if wram.len < BattlePartyPointer + 2:
    raise newException(ValueError, "WRAM buffer is too short for battler pointers")
  if bgMode != 0: return false
  let offset = word(wram, BattlePartyPointer) - PartyCharTableWram
  offset >= 0 and offset < PlayableCharCount * CharStride and offset mod CharStride == 0

proc readDsParty*(wram: openArray[uint8], names: array[256, string],
    battle = false): DsParty =
  ## Read initialized playable members in live roster order without writing WRAM.
  if wram.len < PartyCharTableWram + PlayableCharCount * CharStride:
    raise newException(ValueError, "WRAM buffer is too short for party records")
  for id in readActivePartyIds(wram):
    let base = PartyCharTableWram + (id - 1) * CharStride
    if wram[base + CharLevelOff] == 0: continue
    var member = DsMember(id: id)
    for index in 0 ..< CharNameMaxLen:
      let value = wram[base + CharNameOff + index].int
      if value == 0: break
      member.encodedName.add(value.uint8)
      if value >= ord(' ') + EbStorageBias and value <= ord('~') + EbStorageBias:
        member.name.add(char(value - EbStorageBias))
    if member.encodedName.len == 0: continue
    member.hp = word(wram, base + (if battle: CharHpDisplayOff else: CharHpCurOff))
    member.pp = word(wram, base + (if battle: CharPpDisplayOff else: CharPpCurOff))
    if battle:
      member.hpFraction = word(wram, base + CharHpFractionOff).uint16
      member.ppFraction = word(wram, base + CharPpFractionOff).uint16
    member.hpMax = word(wram, base + CharHpMaxOff)
    member.ppMax = word(wram, base + CharPpMaxOff)
    for index in 0 ..< CharConditionsLen:
      member.conditions[index] = wram[base + CharConditionsOff + index]
    member.framePalette = word(wram, base + CharUiPaletteOff).uint16
    for index in 0 ..< CharInventoryLen:
      let itemId = wram[base + CharInventoryOff + index].int
      member.inventory[index] = DsItem(id: itemId, name: names[itemId])
      for equipment in 0 ..< CharEquipLen:
        if itemId != 0 and wram[base + CharEquipOff + equipment].int == index + 1:
          member.inventory[index].equipped = true
    result.add(member)

proc newDsCompanion*(assets: EbUiAssets): DsCompanion =
  ## Allocate a companion using ROM-decoded or explicitly authored UI assets.
  if assets == nil: raise newException(ValueError, "EarthBound UI assets are required")
  DsCompanion(image: newImage(DsPanelWidth, DsPanelHeight), assets: assets,
    flavor: 1, tracking: 1, colors: assets.uiColors(1, false))

proc newDsCompanion*(rom: openArray[uint8]): DsCompanion =
  ## Allocate ROM-scoped native UI assets and lossless item labels.
  result = newDsCompanion(loadEbUiAssets(rom))
  for id in 1 ..< result.names.len:
    result.names[id] = decodeItemRecord(rom, id).name
    for index in 0 ..< ItemNameMaxLen:
      let value = rom[ItemTableBase + id * ItemRecordSize + index]
      if value == 0: break
      result.encodedNames[id].add(value)

proc statusBounds*(count, index: int, selected: bool): tuple[x, y, width, height: int] =
  ## Locate the original seven-by-eight status rectangle from $C20445.
  ((16 - count * StatusWidthTiles div 2 + index * StatusWidthTiles) * TileSize,
    (if selected: StatusSelectedRow else: StatusRestingRow) * TileSize,
    StatusWidthTiles * TileSize, StatusHeightTiles * TileSize)

proc cardAt*(party: DsParty, x, y: int, selectedId = 0): int =
  ## Return the identity under a native status panel, or zero outside panels.
  for index, member in party:
    let bounds = statusBounds(party.len, index, member.id == selectedId)
    if x >= bounds.x and x < bounds.x + bounds.width and
        y >= bounds.y and y < bounds.y + bounds.height: return member.id

proc encoded(text: string): seq[uint8] =
  ## Encode authored ASCII labels for synthetic callers without changing ROM text.
  for value in text: result.add(uint8(value.ord + EbStorageBias))

proc fillBox(view: DsCompanion, x, y, width, height: int, color: ColorRGBA) =
  ## Fill an integral rectangle without filtering or subpixel coverage.
  for py in max(0, y) ..< min(view.image.height, y + height):
    for px in max(0, x) ..< min(view.image.width, x + width):
      view.image[px, py] = color

proc textPalette(view: DsCompanion, index: int, transparent = false): array[4, ColorRGBA] =
  ## Map the original font's ink-one and background-three colors to its painter.
  [if transparent: ColorRGBA() else: view.colors[index * 4 + 3], view.colors[index * 4 + 1],
    view.colors[index * 4 + 2], view.colors[index * 4 + 3]]

proc goodsItemPosition*(index: int): tuple[x, y: int] =
  ## Match the row-major two-column layout assigned by original $C451FA.
  if index notin 0 ..< CharInventoryLen:
    raise newException(ValueError, "Invalid Goods display index: " & $index)
  (GoodsX + GoodsTextInset + (index mod GoodsColumns) * GoodsColumnWidth,
    GoodsY + TileSize + (index div GoodsColumns) * GoodsRowHeight)

proc tile(view: DsCompanion, word: uint16, x, y: int) =
  ## Paint one original UI tile with this frame's flavor and live palette.
  view.image.paintEbTile(view.assets, word, x, y, view.colors, view.flavor)

proc goodsWindow(view: DsCompanion, member: DsMember) =
  ## Draw the original Goods-sized window, small name header and two-column list.
  view.fillBox(GoodsX + TileSize, GoodsY + TileSize,
    (GoodsWidthTiles - 2) * TileSize, (GoodsHeightTiles - 2) * TileSize, view.colors[3])
  let
    name = if member.encodedName.len > 0: member.encodedName else: encoded(member.name)
    header = view.assets.fonts[HeaderFont]
    frame = composeEbGoodsFrame(min(CharNameMaxLen, name.len))
  for row in 0 ..< frame.len:
    for column in 0 ..< frame[row].len:
      let
        word = frame[row][column]
        tile = (word and TileIndexMask).int
      if word != 0 and tile notin HeaderTileFirst ..< HeaderTileEnd:
        view.tile(word, GoodsX + column * TileSize, GoodsY + row * TileSize)
      elif tile in HeaderTileFirst ..< HeaderTileEnd:
        view.fillBox(GoodsX + column * TileSize, GoodsY,
          TileSize, TileSize, view.colors[3])
  view.image.drawEbText(header, name, GoodsX + GoodsTextInset, GoodsY, view.textPalette(0))
  var goodsFont = view.assets.fonts[GoodsFont]
  goodsFont.extraSpacing = view.tracking
  var displayIndex = 0
  for item in member.inventory:
    if item.id == 0: continue
    let
      position = goodsItemPosition(displayIndex)
      name = if item.encodedName.len > 0: item.encodedName else: encoded(item.name)
      inset = if item.equipped: TileSize else: 0
    if item.equipped:
      view.tile(EquipmentTopTile, position.x, position.y)
      view.tile(EquipmentBottomTile, position.x, position.y + TileSize)
    view.image.drawEbText(goodsFont, name, position.x + inset, position.y,
      view.textPalette(0), maxWidth = GoodsTextWidth - inset)
    inc displayIndex

proc statusWindow(view: DsCompanion, member: DsMember, index: int) =
  ## Compose and paint the original status tiles and its fixed-width name font.
  let
    bounds = statusBounds(view.party.len, index, member.id == view.selectedId)
    name = if member.encodedName.len > 0: member.encodedName else: encoded(member.name)
    hp = ebMeterWords(member.hp, member.hpFraction.int)
    pp = if ebPpHidden(member.conditions[PpHideFieldOff - CharConditionsOff]): ebPpHideWords()
      else: ebMeterWords(member.pp, member.ppFraction.int)
    entries = composeEbStatus(view.assets.statuses, view.assets.labels, member.id,
      min(CharNameMaxLen, name.len), member.framePalette, member.conditions, hp, pp)
  for row in 0 ..< entries.len:
    for column in 0 ..< entries[row].len:
      var word = entries[row][column]
      let index = (word and TileIndexMask).int
      if index >= NameTileFirst and index < NameTileEnd:
        word = (word and not TileIndexMask) or EmptyNameTopTile
      view.tile(word, bounds.x + column * TileSize, bounds.y + row * TileSize)
  let palette = (entries[1][1].int shr PaletteShift) and 7
  view.image.drawEbText(view.assets.fonts[NameFont], name,
    bounds.x + TileSize + StatusNameInset, bounds.y + TileSize,
    view.textPalette(palette, true), maxWidth = 32 - StatusNameInset)

proc render(view: DsCompanion) =
  ## Draw native windows at original pixel density on an otherwise black panel.
  view.image.fill(rgbx(0, 0, 0, 255))
  for member in view.party:
    if member.id == view.selectedId: view.goodsWindow(member)
  for index, member in view.party: view.statusWindow(member, index)

proc update*(view: DsCompanion, party: DsParty, buttons: uint16,
    pointer: DsPointer, flavor = 1, flash = false, palette: openArray[uint16] = [],
    tracking = 1) =
  ## Reconcile roster and selection, then redraw only changed display contents.
  var colors = view.assets.uiColors(flavor, flash)
  if palette.len != 0:
    if palette.len != colors.len:
      raise newException(ValueError, "EarthBound UI palette requires 32 colors")
    for index, color in palette: colors[index] = bgr555ToColor(color)
  let
    changed = view.party != party or view.flavor != flavor or view.colors != colors or
      view.tracking != tracking
    previousSelection = view.selectedId
    triggers = buttons and (PreviousMember or NextMember)
    pressed = triggers and not view.lastTriggers
  view.party = party
  view.flavor = flavor
  view.colors = colors
  view.tracking = tracking
  var selected = -1
  for index, member in party:
    if member.id == view.selectedId: selected = index
  if party.len == 0:
    view.selectedId = 0
  else:
    if selected < 0: selected = 0
    if triggers != (PreviousMember or NextMember):
      if (pressed and PreviousMember) != 0:
        selected = (selected + party.len - 1) mod party.len
      elif (pressed and NextMember) != 0:
        selected = (selected + 1) mod party.len
    view.selectedId = party[selected].id
    if pointer.pressed and not view.pointerHeld:
      let
        x = (pointer.x.int + PointerMaximum) * DsPanelWidth div (PointerMaximum * 2)
        combinedY = (pointer.y.int + PointerMaximum) * DsCombinedHeight div (PointerMaximum * 2)
        id = cardAt(party, x, combinedY - DsPanelHeight, view.selectedId)
      if id != 0: view.selectedId = id
  view.lastTriggers = triggers
  view.pointerHeld = pointer.pressed
  if not view.rendered or changed or previousSelection != view.selectedId:
    view.render()
    view.rendered = true

proc update*(view: DsCompanion, wram: openArray[uint8], buttons: uint16,
    pointer: DsPointer, battle = false, palette: openArray[uint16] = []) =
  ## Read the live party and update the companion from one emulated frame.
  var party = readDsParty(wram, view.names, battle)
  for member in party.mitems:
    for item in member.inventory.mitems:
      item.encodedName = view.encodedNames[item.id]
  let flavor = max(1, wram[UiFlavorWram].int)
  view.update(party, buttons, pointer, flavor,
    (wram[UiFrameCounterWram] and 4) != 0, palette, wram[TrackingWram].int)
