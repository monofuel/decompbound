import
  pixie,
  ../src/decompbound/[ds_companion, eb_ui_assets, eb_ui_font, party_sram, party_wram]

proc syntheticAssets(): EbUiAssets =
  ## Supply authored flat tiles and empty glyphs to isolate layout and input tests.
  result = EbUiAssets()
  result.graphics.tiles = newSeq[uint8](0x1A00)
  for index in 0 ..< result.graphics.tiles.len: result.graphics.tiles[index] = 255
  for palette in result.palettes.mitems:
    for color in palette.mitems: color = 0x001F
  for index, font in result.fonts.mpairs:
    let height = if index == 3: 8 else: 16
    font = EbUiFont(fontId: index, height: height, stride: height, cellWidth: 8,
      widths: newSeq[uint8](FontGlyphCount), bitmap: newSeq[uint8](FontGlyphCount * height))
    for width in font.widths.mitems: width = 6
    for value in font.bitmap.mitems: value = 255

proc putWord(data: var seq[uint8], offset, value: int) =
  ## Store a synthetic little-endian party word.
  data[offset] = uint8(value and 255)
  data[offset + 1] = uint8(value shr 8)

proc character(data: var seq[uint8], id: int, name: string) =
  ## Initialize one synthetic playable character record.
  let base = PartyCharTableWram + (id - 1) * CharStride
  for index, value in name:
    data[base + index] = uint8(ord(value) + 0x30)
  data[base + CharLevelOff] = 10
  data.putWord(base + CharHpCurOff, 45)
  data.putWord(base + CharHpMaxOff, 100)
  data.putWord(base + CharPpCurOff, 12)
  data.putWord(base + CharPpMaxOff, 25)

proc pointerAt(x, y: int): DsPointer =
  ## Encode a bottom-panel pixel center in combined-frame pointer coordinates.
  DsPointer(x: int16(((x * 2 + 1) * 32767 div DsPanelWidth) - 32767),
    y: int16((((y + DsPanelHeight) * 2 + 1) * 32767 div DsCombinedHeight) - 32767),
    pressed: true)

proc main() =
  ## Exercise the live roster reader, complete inventory, and companion input.
  var
    wram = newSeq[uint8](0x20000)
    names: array[256, string]
  doAssert readDsParty(wram, names).len == 0
  wram.character(1, "Alice")
  wram.character(2, "Bob")
  wram.character(3, "Chris")
  wram[PartyRosterWram] = 2
  wram[PartyRosterWram + 1] = 1
  wram[PartyRosterWram + 2] = 2
  wram[PartyRosterWram + 3] = 7
  wram[PartyCountWram] = 4
  let base = PartyCharTableWram
  names[19] = "Synthetic item"
  wram[base + CharInventoryOff + 13] = 19
  wram[base + CharEquipOff] = 14
  wram.putWord(base + CharHpCurOff, 60000)
  wram.putWord(base + CharHpMaxOff, 65535)
  var party = readDsParty(wram, names)
  doAssert party.len == 2
  doAssert party[0].id == 2 and party[1].id == 1
  doAssert party[1].name == "Alice" and party[1].hp == 60000
  doAssert party[1].encodedName == @[0x71'u8, 0x9C, 0x99, 0x93, 0x95]
  doAssert party[1].hpMax == 65535
  doAssert party[1].inventory.len == 14
  doAssert party[1].inventory[0].id == 0
  doAssert party[1].inventory[13] == DsItem(id: 19, name: "Synthetic item", equipped: true)
  doAssert party[0].inventory[13].id == 0
  doAssert wram[base + CharEquipOff] == 14
  wram.putWord(base + CharHpDisplayOff, 25)
  wram.putWord(base + CharHpCurOff, 0)
  wram.putWord(base + CharPpDisplayOff, 12)
  wram.putWord(base + CharPpCurOff, 2)
  wram.putWord(base + CharHpFractionOff, 0xAB01)
  wram.putWord(base + CharPpFractionOff, 0x3401)
  wram[base + CharConditionsOff + 3] = 2
  wram.putWord(base + CharUiPaletteOff, 0x0C00)
  doAssert readDsParty(wram, names, true)[1].hp == 25
  doAssert readDsParty(wram, names, true)[1].pp == 12
  doAssert readDsParty(wram, names, true)[1].hpFraction == 0xAB01
  doAssert readDsParty(wram, names, true)[1].ppFraction == 0x3401
  doAssert readDsParty(wram, names, true)[1].conditions[3] == 2
  doAssert readDsParty(wram, names, true)[1].framePalette == 0x0C00
  doAssert readDsParty(wram, names)[1].hp == 0
  doAssert readDsParty(wram, names)[1].pp == 2
  doAssert readDsParty(wram, names)[1].hpFraction == 0
  doAssert readDsParty(wram, names)[1].ppFraction == 0
  wram.putWord(base + CharHpDisplayOff, 24)
  doAssert readDsParty(wram, names, true)[1].hp == 24
  doAssert not partyBattleVisible(wram, 0)
  wram.putWord(0x4DC8, PartyCharTableWram)
  doAssert partyBattleVisible(wram, 0)
  doAssert not partyBattleVisible(wram, 1)
  wram.putWord(0x4DC8, PartyCharTableWram + 1)
  doAssert not partyBattleVisible(wram, 0)
  doAssert statusBounds(2, 0, false) == (72, 152, 56, 64)
  doAssert statusBounds(2, 1, true) == (128, 144, 56, 64)
  doAssert cardAt(party, 72, 152) == 2
  doAssert cardAt(party, 127, 215) == 2
  doAssert cardAt(party, 128, 152) == 1
  doAssert cardAt(party, 184, 152) == 0
  doAssert cardAt(party, 72, 216) == 0
  doAssert cardAt(party, 72, 144, 2) == 2
  doAssert cardAt(party, 72, 144) == 0
  doAssert cardAt(party, -1, 152) == 0
  let view = newDsCompanion(syntheticAssets())
  view.update(party, 0, DsPointer())
  doAssert view.selectedId == 2
  doAssert view.image.width == 256 and view.image.height == 224
  let cardColor = view.image.data[144 * DsPanelWidth + 72]
  view.update(party, NextMember, DsPointer())
  doAssert view.selectedId == 1
  doAssert view.image.data[144 * DsPanelWidth + 72] != cardColor
  view.update(party, NextMember, DsPointer())
  doAssert view.selectedId == 1
  view.update(party, 0, DsPointer())
  view.update(party, NextMember, DsPointer())
  doAssert view.selectedId == 2
  view.update(party, 0, DsPointer())
  view.update(party, PreviousMember, DsPointer())
  doAssert view.selectedId == 1
  view.update(party, PreviousMember or NextMember, DsPointer())
  doAssert view.selectedId == 1
  view.update(party, 0, DsPointer())
  view.update(party, 0, pointerAt(73, 153))
  doAssert view.selectedId == 2
  view.update(party, 0, pointerAt(129, 153))
  doAssert view.selectedId == 2
  view.update(party, 0, DsPointer())
  view.update(party, 0, pointerAt(129, 153))
  doAssert view.selectedId == 1
  view.update(party, 0, DsPointer())
  view.update(party, 0, pointerAt(255, 223))
  doAssert view.selectedId == 1
  swap(party[0], party[1])
  view.update(party, 0, DsPointer())
  doAssert view.selectedId == 1
  party.delete(0)
  view.update(party, 0, DsPointer())
  doAssert view.selectedId == 2
  view.update(DsParty(@[]), 0, DsPointer())
  doAssert view.selectedId == 0
  wram[PartyRosterWram] = 3
  wram[PartyRosterWram + 1] = 0
  wram[PartyRosterWram + 2] = 0
  doAssert readDsParty(wram, names).len == 1
  wram[PartyCharTableWram + 2 * CharStride + CharLevelOff] = 0
  doAssert readDsParty(wram, names).len == 0
  wram.character(3, "Chris")
  wram[PartyRosterWram] = 3
  wram[PartyRosterWram + 1] = 2
  wram[PartyRosterWram + 2] = 1
  wram[PartyCountWram] = 1
  wram[PartyCountWram + 1] = 4
  wram[0x9891] = 2
  let solo = readDsParty(wram, names)
  doAssert solo.len == 1 and solo[0].id == 3
  wram[PartyCountWram] = 3
  let ordered = readDsParty(wram, names)
  doAssert ordered.len == 3
  doAssert ordered[0].id == 3 and ordered[1].id == 2 and ordered[2].id == 1
  view.update(ordered, 0, DsPointer())
  view.update(ordered, NextMember, DsPointer())
  doAssert view.selectedId == 2
  view.update(solo, 0, DsPointer())
  doAssert view.selectedId == 3
  wram[PartyCountWram] = 0
  doAssert readDsParty(wram, names).len == 0
  let guestOrder = [3'u8, 5, 2, 6, 1, 4, 2]
  doAssert playablePartyIds(guestOrder, 6) == @[3, 2, 1, 4]
  doAssert playablePartyIds(guestOrder, 255) == @[3, 2, 1, 4]
  doAssert playablePartyIds(guestOrder, 1) == @[3]
  let adjacentAttribute = [3'u8, 0, 0, 0, 0, 0, 2]
  doAssert playablePartyIds(adjacentAttribute, 255) == @[3]

main()
