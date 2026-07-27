## Unit test: live WRAM party layout math + synthetic persist-block round trip.
## No real ROM / no window — pure buffer logic + synthetic item-table bytes.

import
  std/json,
  ../src/decompbound/[item_table, party_sram, party_wram]

proc putU8(data: var string, off: int, v: uint8) =
  ## Write one byte.
  data[off] = char(v)

proc putU16(data: var string, off: int, v: uint16) =
  ## Write little-endian u16.
  putU8(data, off, (v and 0xFF).uint8)
  putU8(data, off + 1, ((v shr 8) and 0xFF).uint8)

proc putU32(data: var string, off: int, v: uint32) =
  ## Write little-endian u32.
  putU16(data, off, (v and 0xFFFF).uint16)
  putU16(data, off + 2, ((v shr 16) and 0xFFFF).uint16)

proc putName(data: var string, off: int, name: string) =
  ## Encode ASCII as EB storage (ASCII + 0x30).
  for i, c in name:
    if i >= CharNameMaxLen: break
    putU8(data, off + i, (c.ord + 0x30).uint8)
  if name.len < CharNameMaxLen:
    putU8(data, off + name.len, 0)

proc putRomItem(rom: var seq[uint8], id: int, name: string, flags: uint8,
                price: uint16) =
  ## Write one synthetic item-table record at the standard base/stride.
  let base = ItemTableBase + id * ItemRecordSize
  let need = base + ItemRecordSize
  if rom.len < need:
    rom.setLen(need)
  for i, c in name:
    if i >= ItemNameMaxLen: break
    rom[base + i] = (c.ord + 0x30).uint8
  rom[base + ItemTypeOff] = flags
  rom[base + ItemPriceOff] = (price and 0xFF).uint8
  rom[base + ItemPriceOff + 1] = ((price shr 8) and 0xFF).uint8

proc main() =
  ## Assert slot↔WRAM base mapping and shared layout constants.
  doAssert PartyCharTableWram == PersistBlockWram + (CharTableBase - DataOffset)
  doAssert PartyRosterWram == PersistBlockWram + (PartyRosterOff - DataOffset)
  doAssert PartyCharTableWram == 0x99CE
  doAssert PartyRosterWram == 0x988B
  doAssert CharStride == 0x5F

  # Synthetic persist payload → SRAM slot → party_sram parse (layout identity).
  var srm = newString(0x2000)
  const Sig = "HAL Laboratory, inc."
  for i in 0 ..< Sig.len:
    srm[i] = Sig[i]
  putU8(srm, PartyRosterOff, 1)
  let ness = CharTableBase
  putName(srm, ness + CharNameOff, "Ness")
  putU8(srm, ness + CharLevelOff, 5)
  putU32(srm, ness + CharExpOff, 1234)
  putU16(srm, ness + CharHpMaxOff, 40)
  putU16(srm, ness + CharPpMaxOff, 12)
  putU16(srm, ness + CharHpCurOff, 33)
  putU16(srm, ness + CharPpCurOff, 8)
  # Stat blocks: OFF/DEF/SPD/GUT/LUC/VIT/IQ (with-equip, then base).
  for i, v in [24'u8, 11, 7, 9, 4, 6, 8]:
    putU8(srm, ness + CharStatsOff + i, v)
  for i, v in [20'u8, 10, 7, 9, 4, 6, 8]:
    putU8(srm, ness + CharStatsBaseOff + i, v)
  # Inventory: item 0x11 in slot 1 (equipped as weapon), 0x54 in slot 3.
  putU8(srm, ness + CharInventoryOff + 0, 0x11)
  putU8(srm, ness + CharInventoryOff + 2, 0x54)
  putU8(srm, ness + CharEquipOff + 0, 1)

  let report = readPartyVitalsFromBytes(srm, "unit.srm")
  doAssert not report.empty
  doAssert report.members.len == 1
  doAssert report.members[0].name == "Ness"
  doAssert report.members[0].level == 5
  doAssert report.members[0].hp == 33 and report.members[0].hpMax == 40
  doAssert report.members[0].pp == 8 and report.members[0].ppMax == 12
  doAssert report.members[0].exp == 1234
  doAssert report.members[0].stats == CharStats(
    offense: 24, defense: 11, speed: 7, guts: 9, luck: 4, vitality: 6, iq: 8)
  doAssert report.members[0].statsBase.offense == 20
  doAssert report.members[0].statsBase.defense == 10
  doAssert report.members[0].inParty
  # Inventory: empty slots omitted, equip index maps to slot, no ROM → name "".
  let inv = report.members[0].inventory
  doAssert inv.len == 2
  doAssert inv[0].slot == 1 and inv[0].id == 0x11 and inv[0].equipped
  doAssert inv[1].slot == 3 and inv[1].id == 0x54 and not inv[1].equipped
  doAssert inv[0].name == ""
  doAssert inv[0].price == 0 and inv[0].sellPrice == 0 and not inv[0].sellable

  # Synthetic ROM: priced weapon id 0x11 ($14) and zero-price key id 0x54.
  var synthRom: seq[uint8]
  putRomItem(synthRom, 0x11, "Test bat", 0x10, 14)
  putRomItem(synthRom, 0x54, "Key item", 0x3B, 0)
  doAssert itemPrice(synthRom, 0x11) == 14
  doAssert itemSellPrice(synthRom, 0x11) == 7
  doAssert itemSellable(synthRom, 0x11)
  doAssert itemFlags(synthRom, 0x11) == 0x10
  doAssert itemPrice(synthRom, 0x54) == 0
  doAssert not itemSellable(synthRom, 0x54)
  doAssert itemSellPrice(synthRom, 0x54) == 0

  let priced = readPartyVitalsFromBytes(srm, "unit.srm", synthRom)
  let pInv = priced.members[0].inventory
  doAssert pInv[0].name == "Test bat"
  doAssert pInv[0].price == 14 and pInv[0].sellPrice == 7 and pInv[0].sellable
  doAssert pInv[1].name == "Key item"
  doAssert pInv[1].price == 0 and pInv[1].sellPrice == 0 and not pInv[1].sellable
  let invJson = memberToJson(priced.members[0])["inventory"]
  doAssert invJson[0]["sellPrice"].getInt() == 7
  doAssert invJson[0]["sellable"].getBool() == true
  doAssert invJson[1]["sellable"].getBool() == false

  # Mapping arithmetic used by party_wram (document for RE handoff).
  const
    MoneySlotOff = 0x5C
    MoneyWram = 0x9831
  doAssert MoneyWram == PersistBlockWram + (MoneySlotOff - DataOffset)

  echo "OK test_party_wram"

main()
