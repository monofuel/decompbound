import
  pixie,
  ../src/decompbound/[ds_companion, party_sram, party_wram]

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
  doAssert readDsParty(wram, names, true)[1].hp == 25
  doAssert readDsParty(wram, names, true)[1].pp == 12
  doAssert readDsParty(wram, names)[1].hp == 0
  doAssert readDsParty(wram, names)[1].pp == 2
  wram.putWord(base + CharHpDisplayOff, 24)
  doAssert readDsParty(wram, names, true)[1].hp == 24
  doAssert not partyBattleVisible(wram, 0)
  wram.putWord(0x4DC8, PartyCharTableWram)
  doAssert partyBattleVisible(wram, 0)
  doAssert not partyBattleVisible(wram, 1)
  wram.putWord(0x4DC8, PartyCharTableWram + 1)
  doAssert not partyBattleVisible(wram, 0)
  doAssert cardAt(party, 6, 6) == 2
  doAssert cardAt(party, 63, 65) == 2
  doAssert cardAt(party, 64, 6) == 0
  doAssert cardAt(party, 68, 6) == 1
  doAssert cardAt(party, 6, 66) == 0
  doAssert cardAt(party, -1, 6) == 0
  let view = newDsCompanion(@[])
  view.update(party, 0, DsPointer())
  doAssert view.selectedId == 2
  doAssert view.image.width == 256 and view.image.height == 224
  let cardColor = view.image.data[6 * DsPanelWidth + 6]
  view.update(party, NextMember, DsPointer())
  doAssert view.selectedId == 1
  doAssert view.image.data[6 * DsPanelWidth + 6] != cardColor
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
  view.update(party, 0, pointerAt(7, 7))
  doAssert view.selectedId == 2
  view.update(party, 0, pointerAt(69, 7))
  doAssert view.selectedId == 2
  view.update(party, 0, DsPointer())
  view.update(party, 0, pointerAt(69, 7))
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

main()
