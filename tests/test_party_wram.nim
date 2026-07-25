## Unit test: live WRAM party layout math + synthetic persist-block round trip.
## No ROM / no window — pure buffer logic + optional state load if present.

import
  ../src/decompbound/[party_sram, party_wram]

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

  # Mapping arithmetic used by party_wram (document for RE handoff).
  const
    MoneySlotOff = 0x5C
    MoneyWram = 0x9831
  doAssert MoneyWram == PersistBlockWram + (MoneySlotOff - DataOffset)

  echo "OK test_party_wram"

main()
