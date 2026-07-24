## Read party vitals (name, level, HP, PP) from an EarthBound battery save (.srm).
## Offsets match docs/sram-format.md and src/tools/sram_info.nim — confirmed on
## real saves. Used by the Goal 5 playthrough co-pilot MCP server.

import
  std/[os, strformat, times]

const
  DefaultSrmPath* = "bin/Earthbound (U) [!].srm"
  Header = "HAL Laboratory, inc."
  SramSize = 0x2000
  SaveSlotSize = 0x500
  DataOffset = 0x20
  StampOff = 0x1C
  SlotPairBases = [0x0000, 0x0A00, 0x1400]
  MirrorDelta = 0x500
  # TODO: magic offsets — confirmed via sram_info --find on real saves +
  # community cross-ref (datacrystal character table). See docs/sram-format.md.
  PartyRosterOff = 0xB6
  PartyRosterLen = 7
  CharTableBase = 0x1F9
  CharStride = 0x5F
  PlayableCharCount = 4
  CharNameOff = 0x00
  CharLevelOff = 0x05
  CharHpMaxOff = 0x0A
  CharPpMaxOff = 0x0C
  CharHpCurOff = 0x47
  CharPpCurOff = 0x4D
  CharRoleNames* = ["Ness", "Paula", "Jeff", "Poo"]

type
  PartyMemberVitals* = object
    ## One playable character's vitals from a battery-save slot.
    role*: string
    name*: string
    level*: int
    hp*: int
    hpMax*: int
    pp*: int
    ppMax*: int
    inParty*: bool

  PartyVitalsReport* = object
    ## Snapshot of party HP/PP from a .srm file.
    srmPath*: string
    source*: string
    slotBase*: int
    modifiedAt*: string
    members*: seq[PartyMemberVitals]
    empty*: bool
    note*: string

proc readLE(data: string, offset, size: int): uint32 =
  ## Little-endian unsigned read of `size` bytes at `offset`.
  for i in 0 ..< size:
    if offset + i < data.len:
      result = result or (data[offset + i].uint32 shl (8 * i))

proc readU8(data: string, offset: int): uint8 =
  ## Read one byte at `offset`, or 0 if out of range.
  if offset >= 0 and offset < data.len:
    result = data[offset].uint8

proc decodeSaveName(data: string, off: int, maxLen = 5): string =
  ## Decode a null-terminated EB-encoded name at `off` (byte = ASCII + 0x30).
  var s = ""
  for i in 0 ..< maxLen:
    if off + i >= data.len: break
    let b = data[off + i].uint8
    if b == 0: break
    let c = char(b - 0x30)
    if c in ' '..'~':
      s.add c
    else:
      s.add &"[{b:02X}]"
  if s.len == 0: s = "(empty)"
  return s

proc slotHasHeader(data: string, base: int): bool =
  ## True if `base` starts with the HAL Laboratory signature.
  if base + Header.len > data.len: return false
  return data[base ..< base + Header.len] == Header

proc slotNonzero(data: string, base: int): int =
  ## Count non-zero payload bytes in a slot (skips pure signature-only empties).
  let endp = min(base + SaveSlotSize, data.len)
  for i in base + DataOffset ..< endp:
    if data[i] != '\0': inc result

proc detectActiveBase*(data: string): int =
  ## Pick the occupied slot copy with the highest stamp among all A/B mirrors.
  var
    best = 0
    bestNz = 0
    bestStamp = 0'u32
  for pair in SlotPairBases:
    for base in [pair, pair + MirrorDelta]:
      if not slotHasHeader(data, base): continue
      let nz = slotNonzero(data, base)
      if nz == 0: continue
      let stamp = readLE(data, base + StampOff, 4)
      if nz > bestNz or (nz == bestNz and stamp > bestStamp):
        best = base
        bestNz = nz
        bestStamp = stamp
  return best

proc readPartyVitalsFromBytes*(data: string, srmPath = ""): PartyVitalsReport =
  ## Parse party vitals from raw 8KB SRAM bytes.
  result.srmPath = srmPath
  result.source = "battery_sram"
  result.members = @[]
  if data.len < SramSize:
    result.empty = true
    result.note = &"SRAM too short ({data.len} bytes; need {SramSize})"
    return result

  let slotBase = detectActiveBase(data)
  result.slotBase = slotBase
  if not slotHasHeader(data, slotBase) or slotNonzero(data, slotBase) == 0:
    result.empty = true
    result.note = "No occupied save slot in battery SRAM (save in-game, then re-query)"
    return result

  var inParty: set[0..3] = {}
  for j in 0 ..< PartyRosterLen:
    let id = readU8(data, slotBase + PartyRosterOff + j).int
    if id >= 1 and id <= PlayableCharCount:
      inParty.incl(id - 1)

  for charIdx in 0 ..< PlayableCharCount:
    let eb = slotBase + CharTableBase + charIdx * CharStride
    let name = decodeSaveName(data, eb + CharNameOff)
    let level = readU8(data, eb + CharLevelOff).int
    let hpMax = readLE(data, eb + CharHpMaxOff, 2).int
    let ppMax = readLE(data, eb + CharPpMaxOff, 2).int
    let hpCur = readLE(data, eb + CharHpCurOff, 2).int
    let ppCur = readLE(data, eb + CharPpCurOff, 2).int
    let role = CharRoleNames[charIdx]
    let present = charIdx in inParty or level > 0 or name != "(empty)"
    if not present:
      continue
    result.members.add PartyMemberVitals(
      role: role,
      name: name,
      level: level,
      hp: hpCur,
      hpMax: hpMax,
      pp: ppCur,
      ppMax: ppMax,
      inParty: charIdx in inParty
    )

  if result.members.len == 0:
    result.empty = true
    result.note = "Save slot occupied but no character rows decoded"
  else:
    result.empty = false
    result.note = "Battery save only — not live WRAM mid-battle. Save the game for freshest HP/PP."

proc readPartyVitals*(srmPath: string = DefaultSrmPath): PartyVitalsReport =
  ## Load `srmPath` and return party vitals from the active save slot.
  if not fileExists(srmPath):
    result.srmPath = srmPath
    result.source = "battery_sram"
    result.empty = true
    result.note = &"SRAM file not found: {srmPath}"
    return result
  let data = readFile(srmPath)
  result = readPartyVitalsFromBytes(data, srmPath)
  try:
    result.modifiedAt = $getLastModificationTime(srmPath).utc
  except:
    result.modifiedAt = ""
