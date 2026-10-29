import
  std/[strformat],
  pixie,
  ./[companion_style, item_table, party_sram, party_wram]

type
  DsItem* = object
    id*: int
    name*: string
    equipped*: bool
  DsMember* = object
    id*: int
    name*: string
    hp*, hpMax*, pp*, ppMax*: int
    inventory*: array[CharInventoryLen, DsItem]
  DsParty* = seq[DsMember]
  DsPointer* = object
    x*, y*: int16
    pressed*: bool
  DsCompanion* = ref object
    image*: Image
    context: Context
    font: Font
    names: array[256, string]
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
  CardX = 6
  CardY = 6
  CardWidth = 58
  CardHeight = 60
  CardGap = 4
  ListY = 82
  ListRowHeight = 10
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
      if value >= ord(' ') + EbStorageBias and value <= ord('~') + EbStorageBias:
        member.name.add(char(value - EbStorageBias))
    if member.name.len == 0: continue
    member.hp = word(wram, base + (if battle: CharHpDisplayOff else: CharHpCurOff))
    member.pp = word(wram, base + (if battle: CharPpDisplayOff else: CharPpCurOff))
    member.hpMax = word(wram, base + CharHpMaxOff)
    member.ppMax = word(wram, base + CharPpMaxOff)
    for index in 0 ..< CharInventoryLen:
      let itemId = wram[base + CharInventoryOff + index].int
      member.inventory[index] = DsItem(id: itemId, name: names[itemId])
      for equipment in 0 ..< CharEquipLen:
        if itemId != 0 and wram[base + CharEquipOff + equipment].int == index + 1:
          member.inventory[index].equipped = true
    result.add(member)

proc newDsCompanion*(rom: openArray[uint8]): DsCompanion =
  ## Allocate reusable UI storage and ROM-scoped item labels.
  let image = newImage(DsPanelWidth, DsPanelHeight)
  result = DsCompanion(image: image, context: newContext(image),
    font: newFont(parseTtf(FontData)))
  for id in 1 ..< result.names.len:
    result.names[id] = decodeItemRecord(rom, id).name

proc cardAt*(party: DsParty, x, y: int): int =
  ## Return the character identity under a party card, or zero outside cards.
  if y < CardY or y >= CardY + CardHeight: return 0
  for index, member in party:
    let left = CardX + index * (CardWidth + CardGap)
    if x >= left and x < left + CardWidth: return member.id

proc label(view: DsCompanion, value: string, x, y, size: float32,
    color = Ink) =
  ## Draw companion text using the embedded freely licensed font.
  view.font.size = size
  view.font.paint.color = parseHtmlColor(color)
  view.image.fillText(view.font, value, translate(vec2(x, y)))

proc box(view: DsCompanion, x, y, width, height: float32, color: string) =
  ## Paint a solid rectangular UI element.
  view.context.fillStyle = parseHtmlColor(color)
  view.context.fillRect(rect(x, y, width, height))

proc render(view: DsCompanion) =
  ## Paint the complete companion panel after a visible state change.
  view.image.fill(parseHtmlColor(Background))
  if view.party.len == 0:
    view.label("EARTHBOUND DS", 12, 18, 16, Gold)
    view.label("Your party will appear here.", 12, 48, 11, Cream)
    return
  for index, member in view.party:
    let
      left = (CardX + index * (CardWidth + CardGap)).float32
      selected = member.id == view.selectedId
    view.box(left, CardY.float32, CardWidth.float32, CardHeight.float32,
      if selected: Pink else: Frame)
    view.box(left + 1, CardY.float32 + 1, CardWidth.float32 - 2,
      CardHeight.float32 - 2, Panel)
    view.label(member.name, left + 4, 10, 11, if selected: Pink else: Cream)
    view.label("HP", left + 4, 24, 8, Mint)
    view.label(&"{member.hp}/{member.hpMax}", left + 4, 33, 8)
    view.label("PP", left + 4, 44, 8, Gold)
    view.label(&"{member.pp}/{member.ppMax}", left + 4, 53, 8)
  for member in view.party:
    if member.id != view.selectedId: continue
    view.label(member.name & " / GOODS", 6, 69, 10, Gold)
    view.label("L2 / R2", 211, 71, 8, Muted)
    for index, item in member.inventory:
      let top = (ListY + index * ListRowHeight).float32
      if index mod 2 == 0: view.box(6, top, 244, ListRowHeight.float32, Panel)
      view.label($(index + 1), 9, top, 8, Muted)
      if item.equipped: view.label("E", 23, top, 8, Mint)
      let text = if item.id == 0: "-"
        elif item.name.len > 0: item.name
        else: "ITEM " & $item.id
      view.label(text, 34, top, 9, if item.id == 0: Muted else: Cream)

proc update*(view: DsCompanion, party: DsParty, buttons: uint16,
    pointer: DsPointer) =
  ## Reconcile roster and selection, then redraw only changed display contents.
  let
    changed = view.party != party
    previousSelection = view.selectedId
    triggers = buttons and (PreviousMember or NextMember)
    pressed = triggers and not view.lastTriggers
  view.party = party
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
        id = cardAt(party, x, combinedY - DsPanelHeight)
      if id != 0: view.selectedId = id
  view.lastTriggers = triggers
  view.pointerHeld = pointer.pressed
  if not view.rendered or changed or previousSelection != view.selectedId:
    view.render()
    view.rendered = true

proc update*(view: DsCompanion, wram: openArray[uint8], buttons: uint16,
    pointer: DsPointer, battle = false) =
  ## Read the live party and update the companion from one emulated frame.
  view.update(readDsParty(wram, view.names, battle), buttons, pointer)
