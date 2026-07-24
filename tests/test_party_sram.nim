## Synthetic SRAM party vitals — no real save bytes in the repo.
import
  std/[os, strformat, strutils],
  ../src/decompbound/party_sram

const
  Header = "HAL Laboratory, inc."
  SramSize = 0x2000
  CharTableBase = 0x1F9
  CharStride = 0x5F
  PartyRosterOff = 0xB6
  CharNameOff = 0x00
  CharLevelOff = 0x05
  CharHpMaxOff = 0x0A
  CharPpMaxOff = 0x0C
  CharHpCurOff = 0x47
  CharPpCurOff = 0x4D

proc putU8(data: var string, off: int, v: uint8) =
  ## Write one byte into a mutable string buffer.
  data[off] = char(v)

proc putU16(data: var string, off: int, v: uint16) =
  ## Write little-endian u16.
  putU8(data, off, (v and 0xFF).uint8)
  putU8(data, off + 1, ((v shr 8) and 0xFF).uint8)

proc putName(data: var string, off: int, name: string) =
  ## Encode ASCII name as EB storage (ASCII + 0x30), null-terminated.
  for i, c in name:
    if i >= 5: break
    putU8(data, off + i, (c.ord + 0x30).uint8)
  if name.len < 5:
    putU8(data, off + name.len, 0)

proc makeSyntheticSrm(): string =
  ## Build an 8KB empty SRAM with one slot and Ness + Paula vitals.
  result = newString(SramSize)
  for i in 0 ..< Header.len:
    result[i] = Header[i]
  # Roster: Ness (1), Paula (2)
  putU8(result, PartyRosterOff, 1)
  putU8(result, PartyRosterOff + 1, 2)
  # Ness
  let ness = CharTableBase
  putName(result, ness + CharNameOff, "Ness")
  putU8(result, ness + CharLevelOff, 12)
  putU16(result, ness + CharHpMaxOff, 97)
  putU16(result, ness + CharPpMaxOff, 40)
  putU16(result, ness + CharHpCurOff, 72)
  putU16(result, ness + CharPpCurOff, 18)
  # Paula
  let paula = CharTableBase + CharStride
  putName(result, paula + CharNameOff, "Paula")
  putU8(result, paula + CharLevelOff, 11)
  putU16(result, paula + CharHpMaxOff, 80)
  putU16(result, paula + CharPpMaxOff, 55)
  putU16(result, paula + CharHpCurOff, 80)
  putU16(result, paula + CharPpCurOff, 30)

proc main() =
  ## Unit test: decode synthetic party HP/PP.
  let data = makeSyntheticSrm()
  let report = readPartyVitalsFromBytes(data, "synthetic.srm")
  doAssert not report.empty, report.note
  doAssert report.members.len >= 2, &"expected 2 members, got {report.members.len}"
  let ness = report.members[0]
  doAssert ness.role == "Ness"
  doAssert ness.name == "Ness"
  doAssert ness.level == 12
  doAssert ness.hp == 72 and ness.hpMax == 97
  doAssert ness.pp == 18 and ness.ppMax == 40
  doAssert ness.inParty
  let paula = report.members[1]
  doAssert paula.role == "Paula"
  doAssert paula.hp == 80 and paula.pp == 30
  doAssert paula.inParty

  let missing = readPartyVitals("/tmp/decompbound_no_such_save.srm")
  doAssert missing.empty
  doAssert "not found" in missing.note

  echo "OK test_party_sram"

main()
