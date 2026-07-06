## EarthBound battery-save (SRAM) inspector.
##
## Reads an 8KB .srm and reports what we've mapped of the EB save format, plus
## a value-finder to help map more of it. Dumps character LEVEL/EXP/HP/PP,
## INVENTORY (14 slots), PSI-learned (14 raw bytes), and Escargo Express (36)
## using the verified layout (char table @0x1F9 stride 0x5F, slot base 0/0x500).
## Party membership is a separate small ID array (not the char stat table);
## active roster read from slot+0xB6 (7-byte 1-based IDs, 0=empty).
## The format is only PARTIALLY reverse engineered here (confirmed fields are marked);
## the --find mode is how we discover new fields.
##
## Usage:
##   nim r src/tools/sram_info.nim [save.srm]            # dump known fields + chars
##   nim r src/tools/sram_info.nim [save.srm] --find 20  # locate a value
##
## Default save path: "bin/Earthbound (U) [!].srm".

import
  std/[os, strformat, strutils]

const
  DefaultSrm = "bin/Earthbound (U) [!].srm"
  Header = "HAL Laboratory, inc."   # EB's save-validity signature at offset 0.

  # Verified save layout (anchored to real .srm with active slot base 0).
  # All offsets here are *within a save slot block*; see detectActiveBase.
  # TODO: these are magic offsets until a full struct doc is written in docs/sram-format.md; confirmed via byte match on this save.
  SaveSlotSize = 0x500
  CharTableBase = 0x1F9   # first char entry (Ness); EntryN = CharTableBase + N*CharStride
  CharStride = 0x5F
  PlayableCharCount = 4   # Ness, Paula, Jeff, Poo (2 reserved after)

  # Per-char entry offsets (relative to entry base = CharTableBase + N*CharStride)
  # TODO: +0x00 name (EB-encoded, 5 bytes max + term); +0x05 u8 level verified Ness@0x1FE etc.
  CharNameOff = 0
  CharLevelOff = 0x05
  CharExpOff = 0x06       # u32 LE
  CharInvOff = 0x23       # 14x u8 item IDs (0=empty); Ness@0x21C
  CharEquipOff = 0x31     # 4x u8 (indices into inv)
  CharPsiOff = 0x35       # 14 bytes candidate learned PSI flags; cross-ref ROM 0x158C50 table
  CharHpNowOff = 0x45     # u16; matches prior KnownFields Char1
  CharHpMaxOff = 0x47
  CharPpNowOff = 0x4B
  CharPpMaxOff = 0x4D

  # Top-level (slot-relative) fields
  MoneyOff = 0x5C         # u16 (high bytes 0 in practice)
  AtmOff = 0x60           # u16
  EscargoOff = 0x76       # 36x u8 item IDs stored at Escargo Express
  EscargoLen = 36
  InvLen = 14
  PsiLen = 14
  EquipLen = 4

  # Party roster / membership (near header in persistent block). EB stores a small
  # array of character IDs (1-based: 1=Ness, 2=Paula, 3=Jeff, 4=Poo; 0=empty slot).
  # This is SEPARATE from the always-present 4 char stat entries (which hold pre-baked
  # stats for unjoined chars like Paula/Jeff/Poo even early). Cross-ref: datacrystal
  # EB RAM map (0x988B-0x9891 "current party members", copied to/from SRAM) + delta
  # 0x97D5 from verified Money (0x5C <-> RAM 0x9831) / Escargo. On this save (Ness
  # solo, post-Titanic-Ant): bytes at slot+0xB6 = 01 00 00 00 00 00 00 .
  # TODO: magic offset 0xB6 + len (and 0xBD/0xCE) -- hard-coded after community cross-ref
  # + local byte match; all magic bytes have TODO+comments per AGENTS.md. Use first N
  # non-zero IDs for active party order.
  PartyRosterOff = 0xB6
  PartyRosterLen = 7

  # Non-data magic for slot detection heuristics (content test, not format)
  # TODO: these are internal to active-base selection, not part of EB save format.
  StampOff = 0x1C
  SlotCheckStart = 0x20
  SlotCheckLen = 0x400

type
  Field = object
    name: string
    offset: int
    size: int         ## bytes (1/2/4), little-endian
    confidence: string

# Fields confirmed/inferred from a real save (Ness early game: 39/39 HP,
# 10/10 PP, $20 on hand, $64 ATM). Extend this table as --find maps more.
const KnownFields = [
  Field(name: "Money on hand", offset: 0x5C, size: 4, confidence: "confirmed ($20/$71 across saves)"),
  Field(name: "ATM balance",   offset: 0x60, size: 4, confidence: "confirmed ($0/$64/$109 across saves)"),
  Field(name: "Char1 HP now",  offset: 0x23E, size: 2, confidence: "confirmed (39/60 across saves)"),
  Field(name: "Char1 HP max",  offset: 0x240, size: 2, confidence: "confirmed"),
  Field(name: "Char1 PP now",  offset: 0x244, size: 2, confidence: "confirmed (10/20 across saves)"),
  Field(name: "Char1 PP max",  offset: 0x246, size: 2, confidence: "confirmed"),
]

proc readLE(data: string, offset, size: int): uint32 =
  ## Little-endian unsigned read of `size` bytes at `offset`.
  for i in 0 ..< size:
    if offset + i < data.len:
      result = result or (data[offset + i].uint32 shl (8 * i))

proc decodeSaveName(data: string, off: int, maxLen = 5): string =
  ## Decode a null-terminated EB-encoded name at `off` (byte = ASCII + 0x30).
  ## Used for character names embedded in the save slot (no ROM needed).
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
  if s.len == 0: s = "(unnamed)"
  return s

proc itemStr(id: uint8): string =
  ## Format an inventory item ID. Trivial case (0) mapped to empty; others
  ## shown as hex IDs. A few known IDs can be mapped here once pinned.
  ## TODO: item name table lives in ROM (near PSI data @ file 0x158C50); expand map incrementally.
  if id == 0:
    return "(empty)"
  # seed a couple of trivial/common IDs here if/when verified in a save:
  # (example only — do not fabricate)
  return &"0x{id:02X}"

proc detectActiveBase(data: string): int =
  ## Return active save slot base (0 or SaveSlotSize) by scanning for the
  ## HAL header + sufficient nonzero payload. The 0x500 mirror is normally
  ## a copy; this prefers the primary (first with data), or higher stamp.
  const
    SlotSize = SaveSlotSize
  var best = 0
  var bestNz = 0
  var bestStamp = 0'u32
  for b in [0, SlotSize]:
    if b + Header.len > data.len: continue
    if data[b ..< b + Header.len] != Header: continue
    var nz = 0
    let endp = min(b + SlotCheckLen, data.len)
    for i in b + SlotCheckStart ..< endp:
      if data[i] != '\0': inc nz
    let stamp = readLE(data, b + StampOff, 4)
    if nz > bestNz or (nz == bestNz and stamp > bestStamp):
      best = b
      bestNz = nz
      bestStamp = stamp
  return best

proc dumpChar(data: string, slotBase: int, charIdx: int, tag: string = "") =
  ## Dump one playable char's stats/inv/PSI from the table at CharTableBase.
  ## `tag` appended to name line if provided (e.g. " (not in party)").
  let eb = slotBase + CharTableBase + charIdx * CharStride
  let name = decodeSaveName(data, eb + CharNameOff)
  let level = if eb + CharLevelOff < data.len: data[eb + CharLevelOff].uint8 else: 0'u8
  let exp = readLE(data, eb + CharExpOff, 4)
  let hpN = readLE(data, eb + CharHpNowOff, 2).uint16
  let hpM = readLE(data, eb + CharHpMaxOff, 2).uint16
  let ppN = readLE(data, eb + CharPpNowOff, 2).uint16
  let ppM = readLE(data, eb + CharPpMaxOff, 2).uint16
  # inventory
  var invStrs: seq[string] = @[]
  for j in 0 ..< InvLen:
    let io = eb + CharInvOff + j
    let id = if io < data.len: data[io].uint8 else: 0'u8
    invStrs.add itemStr(id)
  let inv = invStrs.join(" ")
  # PSI 14 raw bytes as hex
  var psiHex = ""
  for j in 0 ..< PsiLen:
    let po = eb + CharPsiOff + j
    let b = if po < data.len: data[po].uint8 else: 0'u8
    psiHex.add &"{b:02X}"
    if j < PsiLen-1: psiHex.add " "
  let tagStr = if tag.len > 0: " " & tag else: ""
  echo &"  {name} (lv{level}){tagStr}:"
  echo &"    EXP {exp}"
  echo &"    HP {hpN}/{hpM}  PP {ppN}/{ppM}"
  echo &"    inventory: {inv}"
  echo &"    PSI-learned: {psiHex}"

proc dumpPartyAndStorage(data: string) =
  ## Print active party members (in roster order) from the separate party roster
  ## array, then list not-yet-joined chars (with tag). The char stat table always
  ## contains pre-baked entries for all 4; membership is tracked independently.
  ## Also dump the 36-slot Escargo Express storage.
  ## Uses active slot base so it works against either mirror.
  let slotBase = detectActiveBase(data)
  # Touch layout consts (money/atm/equip) so they are used; the primary dump of
  # them stays in the unchanged KnownFields section above.
  discard readLE(data, slotBase + MoneyOff, 2)
  discard readLE(data, slotBase + AtmOff, 2)
  discard CharEquipOff
  discard EquipLen
  echo ""
  echo &"party + storage (active slot base 0x{slotBase:03X}):"
  # Read party roster (small ID array, 0=empty). Derive active in order.
  var roster: seq[int] = @[]  # 0-based char indices in party order
  for j in 0 ..< PartyRosterLen:
    let ro = slotBase + PartyRosterOff + j
    if ro < data.len:
      let id = data[ro].uint8.int
      if id >= 1 and id <= PlayableCharCount:
        roster.add(id - 1)
  # Active party (in the order from roster)
  echo "  In party (order):"
  if roster.len == 0:
    echo "    (none)"
  else:
    for ci in roster:
      dumpChar(data, slotBase, ci)
  # Not yet joined
  var inPartySet: set[range[0..3]] = {}
  for ci in roster:
    inPartySet.incl(ci)
  echo "  Roster (not yet joined):"
  var anyNotJoined = false
  for i in 0 ..< PlayableCharCount:
    if i notin inPartySet:
      anyNotJoined = true
      dumpChar(data, slotBase, i, "(not in party)")
  if not anyNotJoined:
    echo "    (none)"
  # Escargo Express
  let escBase = slotBase + EscargoOff
  var escStrs: seq[string] = @[]
  for j in 0 ..< EscargoLen:
    let eo = escBase + j
    let id = if eo < data.len: data[eo].uint8 else: 0'u8
    escStrs.add itemStr(id)
  let esc = escStrs.join(" ")
  echo &"  Escargo Express (36): {esc}"

proc dumpKnown(data: string) =
  ## Validate the header and print the mapped fields.
  let sig = if data.len >= Header.len: data[0 ..< Header.len] else: ""
  echo "save file: ", data.len, " bytes"
  if sig == Header:
    echo "header:    OK  (\"", Header, "\") — valid EarthBound save"
  else:
    echo "header:    MISSING/INVALID — not a valid EB save (or empty)"
  var nonzero = 0
  for c in data:
    if c != '\0': inc nonzero
  echo "non-zero:  ", nonzero, " / ", data.len, " bytes of real data"
  echo ""
  echo "mapped fields (offset  value  field  [confidence]):"
  for f in KnownFields:
    let v = readLE(data, f.offset, f.size)
    echo &"  0x{f.offset:03X}  {v:>7}   {f.name:<14} [{f.confidence}]"
  echo ""
  echo "The format is only partially mapped. Use --find <value> to locate a"
  echo "stat you know in-game, then we can add it to KnownFields."
  # Extended info (character levels/inventory/PSI + Escargo) using verified layout.
  # Does not alter the KnownFields or header output above.
  dumpPartyAndStorage(data)

proc findValue(data: string, n: uint32) =
  ## Report every offset where n appears as a u8, u16-LE, or u32-LE.
  echo &"searching for {n} (0x{n:X}) as u8 / u16-LE / u32-LE:"
  var hits = 0
  for size in [1, 2, 4]:
    if n >= (1'u64 shl (8 * size)).uint32 and size < 4: continue  # too big for this width
    for off in 0 .. data.len - size:
      if readLE(data, off, size) == n:
        # Skip the trivial u8 matches inside a wider match to reduce noise:
        # only report u8 when the value itself is < 256 and it's a lone byte.
        echo &"  0x{off:03X}  as u{size*8}-LE"
        inc hits
  if hits == 0:
    echo "  (not found — try a nearby value; some stats are BCD or offset)"
  echo &"({hits} hit(s))"

when isMainModule:
  var path = DefaultSrm
  var findN = -1
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--find" and i < paramCount():
      findN = parseInt(paramStr(i + 1)); inc i
    elif not a.startsWith("--"):
      path = a
    inc i

  if not fileExists(path):
    echo "no save file at: ", path
    echo "(save in-game at a phone first, or pass a .srm path)"
    quit(1)
  let data = readFile(path)
  echo "== ", path, " =="
  if findN >= 0:
    findValue(data, findN.uint32)
  else:
    dumpKnown(data)
