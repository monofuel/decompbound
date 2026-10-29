## Live party vitals from overworld WRAM (not battery SRAM).
##
## Character table base `$99CE` (Ness), stride `$5F` — same per-char layout as
## `party_sram.nim` / docs/sram-format.md. Evidence (persist block `$97F5`):
##   slot+$05C money  → WRAM `$9831`  (`$97F5 + ($5C-$20)`)
##   slot+$09A roster → WRAM `$986F`  (`$97F5 + ($9A-$20)`)
##   slot+$0CF count  → WRAM `$98A4`  (`$97F5 + ($CF-$20)`)
##   slot+$1F9 char0  → WRAM `$99CE`  (`$97F5 + ($1F9-$20)`)
## Cross-checked: policy `PartyName0Wram = $99CE`; battle ptr table `$4DC8` →
## `$99CE`; ROM uses `ADC #$99CE` for char-table access (bank $C1/$C2).
## Save-to-SRAM copies this persist block into the slot data region (`+$20`).

import
  std/strformat,
  ./[party_sram, snesbus]

const
  ## WRAM base of the battery-save data payload (maps to slot + `$20`).
  PersistBlockWram* = 0x97F5
  PersistBlockLen* = 0x4E0
  ## Ness character struct (name at +0; matches SRAM char table entry).
  PartyCharTableWram* = 0x99CE
  ## Six active identity slots consumed by original $C21034 and $C2109F.
  PartyRosterWram* = 0x986F
  ## Number of active entries, read as one byte by original $C2107A.
  PartyCountWram* = 0x98A4
  WramBase = 0x7E0000

proc readActivePartyIds*(wram: openArray[uint8]): seq[int] =
  ## Read the counted live roster without interpreting unused slots or adjacent flags.
  if wram.len <= PartyCountWram:
    raise newException(ValueError, "WRAM buffer is too short for the active party")
  playablePartyIds(wram.toOpenArray(PartyRosterWram, PartyRosterWram + PartyRosterLen - 1),
    wram[PartyCountWram].int)

proc wramByte(snes: SnesBus, off: int): uint8 {.inline.} =
  ## Read one byte at 16-bit WRAM offset under bank `$7E`.
  let ea = WramBase + (off and 0x1FFFF)
  if ea >= 0 and ea < snes.bus.mem.len:
    result = snes.bus.mem[ea]
  else:
    result = 0

proc wramU16(snes: SnesBus, off: int): int {.inline.} =
  ## Little-endian u16 at 16-bit WRAM offset.
  wramByte(snes, off).int or (wramByte(snes, off + 1).int shl 8)

proc wramU32(snes: SnesBus, off: int): int {.inline.} =
  ## Little-endian u32 at 16-bit WRAM offset.
  wramU16(snes, off) or (wramU16(snes, off + 2) shl 16)

proc wramStats(snes: SnesBus, off: int): CharStats =
  ## 7×u8 stat block (OFF/DEF/SPD/GUT/LUC/VIT/IQ) from live WRAM.
  result.offense = wramByte(snes, off + 0).int
  result.defense = wramByte(snes, off + 1).int
  result.speed = wramByte(snes, off + 2).int
  result.guts = wramByte(snes, off + 3).int
  result.luck = wramByte(snes, off + 4).int
  result.vitality = wramByte(snes, off + 5).int
  result.iq = wramByte(snes, off + 6).int

proc decodeWramName(snes: SnesBus, off: int): string =
  ## Decode EB storage name (ASCII + `$30`) from live WRAM.
  var s = ""
  for i in 0 ..< CharNameMaxLen:
    let b = wramByte(snes, off + i)
    if b == 0: break
    let c = char(b - 0x30)
    if c in ' '..'~':
      s.add c
    else:
      s.add &"[{b:02X}]"
  if s.len == 0: s = "(empty)"
  return s

proc readPartyVitalsFromWram*(snes: SnesBus, frameCount = 0): PartyVitalsReport =
  ## Parse live overworld party vitals from WRAM character table `$99CE`.
  result.source = "live-wram"
  result.frameCount = frameCount
  result.srmPath = ""
  result.slotBase = PartyCharTableWram
  result.members = @[]
  result.modifiedAt = ""

  var inParty: set[0..3] = {}
  for id in readActivePartyIds(snes.bus.mem.toOpenArray(WramBase, WramBase + 0x1FFFF)):
    inParty.incl(id - 1)

  for charIdx in 0 ..< PlayableCharCount:
    let eb = PartyCharTableWram + charIdx * CharStride
    let name = decodeWramName(snes, eb + CharNameOff)
    let level = wramByte(snes, eb + CharLevelOff).int
    let hpMax = wramU16(snes, eb + CharHpMaxOff)
    let ppMax = wramU16(snes, eb + CharPpMaxOff)
    let hpCur = wramU16(snes, eb + CharHpCurOff)
    let ppCur = wramU16(snes, eb + CharPpCurOff)
    let role = CharRoleNames[charIdx]
    let present = charIdx in inParty or level > 0 or name != "(empty)"
    if not present:
      continue
    var itemIds: array[CharInventoryLen, int]
    for i in 0 ..< CharInventoryLen:
      itemIds[i] = wramByte(snes, eb + CharInventoryOff + i).int
    var equipSlots: array[CharEquipLen, int]
    for i in 0 ..< CharEquipLen:
      equipSlots[i] = wramByte(snes, eb + CharEquipOff + i).int
    result.members.add PartyMemberVitals(
      role: role,
      name: name,
      level: level,
      exp: wramU32(snes, eb + CharExpOff),
      hp: hpCur,
      hpMax: hpMax,
      pp: ppCur,
      ppMax: ppMax,
      stats: wramStats(snes, eb + CharStatsOff),
      statsBase: wramStats(snes, eb + CharStatsBaseOff),
      inventory: buildInventory(itemIds, equipSlots, snes.rom),
      inParty: charIdx in inParty
    )

  if result.members.len == 0:
    result.empty = true
    result.note = "No character rows in live WRAM (title / pre-game?)"
  else:
    result.empty = false
    result.note = "Live WRAM overworld stats (not mid-battle battler overlay)."

proc persistBlockToSramBytes*(snes: SnesBus): string =
  ## Build synthetic 8KB SRAM with slot 0A filled from live persist WRAM `$97F5`.
  ## Used to cross-check party_wram vs party_sram on a freshly-copied image.
  result = newString(0x2000)
  const Sig = "HAL Laboratory, inc."
  for i in 0 ..< Sig.len:
    result[i] = Sig[i]
  for i in 0 ..< PersistBlockLen:
    result[DataOffset + i] = char(wramByte(snes, PersistBlockWram + i))
