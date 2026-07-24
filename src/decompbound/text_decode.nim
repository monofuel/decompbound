## EarthBound dialogue text decoder.
## Reverse-engineered from verified findings in docs/scripts.md.
## Encodes storage as byte = ASCII + 0x30 for printable glyphs.
## Controls < 0x20 dispatch at file 0x1890E (CMP #$0020).
## 0x15/0x16/0x17 perform calls via the far-ptr tables (1-byte index).
## Never produces committed dialogue output; used only at runtime on user ROM.

import
  std/[strformat, strutils]

const
  # Verified text encoding: storage byte = ASCII + 0x30 (docs/scripts.md).
  TextEncodingOffset* = 0x30
  # Text block dispatch threshold (CMP #$0020 at file 0x1890E).
  ControlThreshold* = 0x20
  # Dialogue far-pointer tables: id * 4 -> 24-bit far ptr (bank C8).
  # Verified: handlers at file 0x18815 / 0x1886F / 0x188C8 load these bases.
  # Each table is 0x400 bytes = 256 entries.
  DialoguePtrTable0* = 0x8CDED
  DialoguePtrTable1* = 0x8D1ED
  DialoguePtrTable2* = 0x8D5ED
  DialoguePtrTables* = [DialoguePtrTable0, DialoguePtrTable1, DialoguePtrTable2]

# Operand counts: extra stream bytes after the control opcode itself.
# Primary multi-byte CCs install a $1E collector; $97CA is STZ'd at $C18916
# before each primary dispatch. Counts below are full primary-layer widths from
# code_bank01 collector disasm (collect-N via $97CA / store-then-process).
# Prefixes 0x18/0x1C use per-sub-op tables (controlOperandBytes).
const
  ControlOperandCounts*: array[0x20, int] = [
    0, # 00: end (also special-cased as zero-byte in the fetch loop)
    0, # 01: line / layout helper (JSR $04B5); no stream operands
    0, # 02: prompt/suspend (RTL out of interpreter at $C18B0A); no stream ops
    0, # 03: layout helper; no primary stream operands (handler $8A1D)
    2, # 04: $1E=$4265; collect 2 via $97CA (handler $8A29 / coll $4265)
    2, # 05: $1E=$42AD; collect 2
    2, # 06: $1E=$42F5; collect 2 base (may re-arm $4103 — TODO variable)
    2, # 07: $1E=$435F; collect 2
    3, # 08: $1E=$43D6; collect 3 ($97CA < 3)
    1, # 09: $1E=$41D0; one sub byte (X), then working-ptr logic
    3, # 0A: $1E=$4103; collect 3 ($97CA < 3)
    1, # 0B: $1E=$4558; one sub byte
    1, # 0C: $1E=$4591; one sub byte
    1, # 0D: $1E=$45EF; one sub byte
    1, # 0E: $1E=$461A; one sub byte
    0, # 0F: JSR $042E only; no stream ops
    1, # 10: $1E=$4EAB; one sub byte
    0, # 11: helper chain (JSR $196A); stream ops via helper -- TODO
    0, # 12: JSR $0BD3; no primary stream ops
    0, # 13: window helper; no stream ops
    0, # 14: window helper; no stream ops
    1, # 15: call table0[index] -- 1-byte index (AND #$00FF; INC once @ 0x18837)
    1, # 16: call table1[index]
    1, # 17: call table2[index]
    1, # 18: multi-byte CC prefix; sub-op + optional extras (see Cc18ExtraAfterSub)
    1, # 19: $1E=$79AA; sub-op + optional extras (see Cc19ExtraAfterSub)
    1, # 1A: $1E=$7B56; sub-op + optional extras (see Cc1AExtraAfterSub)
    1, # 1B: $1E=$7C36; first-order 1 sub-op (multi still TODO)
    1, # 1C: multi-byte CC prefix; sub-op + optional extras (see Cc1CExtraAfterSub)
    1, # 1D: $1E=$7F11; sub-op + optional extras (see Cc1DExtraAfterSub)
    1, # 1E: $1E=$811F; first-order 1 (re-arms are 0-extra immediates)
    1, # 1F: $1E=$81BB; first-order 1 (many re-arm collectors; TODO full table)
  ]

  ## Extra stream bytes after the 0x18 sub-op byte (family $790B).
  ## From code_bank01 secondary + collector disasm. 0 = sub-op only.
  Cc18ExtraAfterSub*: array[256, int] = block:
    var e: array[256, int]
    for i in 0..255:
      e[i] = 0
    e[0x01] = 1  # re-arm $43C2 (TXA; JSR $04EE)
    e[0x03] = 1  # re-arm $43CC (TXA; JSR $007E)
    e[0x05] = 1  # re-arm $4509 collect-1
    e[0x07] = 4  # re-arm $528D collect-4
    e[0x08] = 1  # re-arm $5529 (TXA path)
    e[0x09] = 1  # re-arm $554E (TXA path)
    e[0x0D] = 1  # re-arm $5B46 collect-1
    e

  ## Extra stream bytes after the 0x1C sub-op byte (family $7D94).
  Cc1CExtraAfterSub*: array[256, int] = block:
    var e: array[256, int]
    for i in 0..255:
      e[i] = 0
    e[0x00] = 1  # $40F9
    e[0x01] = 1  # $40B0
    e[0x02] = 1  # $4FD7
    e[0x03] = 1  # $488D
    e[0x04] = 0  # JSR $0A04; no re-arm
    e[0x05] = 1  # $46BF
    e[0x06] = 1  # $46DE
    e[0x07] = 1  # $45CA
    e[0x08] = 1  # $43B8
    e[0x09] = 1  # $40EF
    e[0x0A] = 3  # $53AF collect-3
    e[0x0B] = 3  # $5573 collect-3
    e[0x0C] = 1  # $5BA7
    e[0x0D] = 0  # complex; no $1E re-arm
    e[0x0E] = 0
    e[0x0F] = 0
    e[0x11] = 1  # $40CF
    e[0x12] = 1  # $61D1
    e[0x13] = 1  # $73C0
    e[0x14] = 1  # $516B (STX path)
    e[0x15] = 1  # $51FC
    e

  ## Extra stream bytes after the 0x19 sub-op byte (family $79AA).
  ## Most paths re-arm a 1-byte collector; JSR-only paths take 0.
  Cc19ExtraAfterSub*: array[256, int] = block:
    var e: array[256, int]
    for i in 0..255:
      e[i] = 0
    e[0x02] = 1  # $78F7
    e[0x04] = 0  # JSR $1383
    e[0x05] = 1  # $506F
    e[0x10] = 1  # $4723
    e[0x11] = 1  # $47CC
    e[0x14] = 0  # JSR $0400 chain
    e[0x16] = 1  # $5007
    e[0x18] = 1  # $5384
    e[0x19] = 1  # $597F
    e[0x1A] = 1  # $5B0E
    e[0x1B] = 1  # $5C36
    e[0x1C] = 1  # $5FF7
    e[0x1D] = 1  # $6080
    e[0x1E] = 0  # JSR $AD26
    e[0x1F] = 0  # JSR $AD02
    e[0x20] = 0  # working-reg path
    e[0x21] = 1  # $6143
    e[0x22] = 1  # $68A0
    e[0x23] = 1  # $6947
    e[0x24] = 1  # $6A7B
    e[0x25] = 1  # $6F9F
    e[0x26] = 1  # $7037
    e[0x27] = 1  # $776A
    e[0x28] = 1  # $4819
    e

  ## Extra stream bytes after the 0x1A sub-op byte (family $7B56).
  Cc1AExtraAfterSub*: array[256, int] = block:
    var e: array[256, int]
    for i in 0..255:
      e[i] = 0
    e[0x00] = 1  # $463B collect-ish / re-arm
    e[0x01] = 1  # $467D
    e[0x04] = 0  # JSR $196A chain
    e[0x05] = 1  # $549E
    e[0x06] = 1  # $4EB5
    e[0x07] = 0  # JSR $9A43
    e[0x08] = 0  # JSR $196A
    e[0x09] = 0  # JSR $196A
    e[0x0A] = 0  # JSR $AC00
    e[0x0B] = 0  # JSR $AAFA
    e

  ## Extra stream bytes after the 0x1D sub-op byte (family $7F11).
  ## Majority re-arm 1-byte collectors; a few are working-reg only.
  Cc1DExtraAfterSub*: array[256, int] = block:
    var e: array[256, int]
    for i in 0..255:
      e[i] = 1  # default: LDA #imm re-arm 1-byte collector
    e[0x20] = 0  # JSR $ACF2 / $AC9B working path
    e[0x22] = 0  # JSL $C00AA1 working path
    e

proc controlOperandBytes*(rom: openArray[uint8]; opPos: int): int =
  ## Total stream operand bytes after the control opcode at opPos.
  ## Handles 0x18/0x1C/0x19/0x1A/0x1D sub-op extras; others use ControlOperandCounts.
  if opPos < 0 or opPos >= rom.len:
    return 0
  let b = rom[opPos]
  if b >= ControlThreshold:
    return 0
  let base = ControlOperandCounts[b]
  if base < 1:
    return base
  # Prefix / secondary families: 1 sub-op + optional extras from re-armed collectors.
  if b in [0x18'u8, 0x19, 0x1A, 0x1C, 0x1D]:
    if opPos + 1 >= rom.len:
      return 1
    let sub = int(rom[opPos + 1])
    let extra =
      case b
      of 0x18: Cc18ExtraAfterSub[sub]
      of 0x19: Cc19ExtraAfterSub[sub]
      of 0x1A: Cc1AExtraAfterSub[sub]
      of 0x1C: Cc1CExtraAfterSub[sub]
      of 0x1D: Cc1DExtraAfterSub[sub]
      else: 0
    return 1 + extra
  result = base

proc farPtrToFileOffset*(bank: uint8, physAddr: uint16): int =
  ## Convert a 24-bit SNES far pointer (bank:physAddr) as stored in pointer tables to a file offset in the ROM image.
  ## Mapping derived from table base at 0x8CDED pointing inside C8 bank.
  ((bank and 0x3f).int shl 16) or physAddr.int

proc resolveDialogueBlock*(rom: openArray[uint8], id: int, table = 0): int =
  ## Resolve a dialogue block id via a far-pointer table (id -> far ptr -> file offset).
  ## `table` selects 0/1/2 (0x8CDED / 0x8D1ED / 0x8D5ED). Returns -1 if out of range.
  if table < 0 or table > 2:
    return -1
  let entryOff = DialoguePtrTables[table] + id * 4
  if entryOff + 3 >= rom.len:
    return -1
  let lo = rom[entryOff + 0].uint16
  let mi = rom[entryOff + 1].uint16
  let bank = rom[entryOff + 2]
  let addr16 = (mi shl 8) or lo
  let fileOff = farPtrToFileOffset(bank, addr16)
  if fileOff < 0 or fileOff >= rom.len:
    return -1
  return fileOff

proc controlTag(b: uint8, ops: string): string =
  ## Map a control opcode (+ optional operand hex) to a readable tag.
  case b
  of 0x00:
    "[end]"
  of 0x01:
    "[nl]"
  of 0x02:
    "[prompt]"
  of 0x15, 0x16, 0x17:
    let t = int(b) - 0x15
    if ops.len > 0:
      &"[call{t}:{ops}]"
    else:
      &"[call{t}]"
  of 0x18:
    if ops.len > 0: &"[cc18:{ops}]" else: "[cc18]"
  of 0x1C:
    if ops.len > 0: &"[cc1C:{ops}]" else: "[cc1C]"
  else:
    if ops.len > 0: &"[ctl:{b:02X}:{ops}]" else: &"[ctl:{b:02X}]"

proc decodeText*(rom: openArray[uint8], offset: int): string =
  ## Decode an EB dialogue byte stream at file offset to a readable tagged string.
  ## Printable glyphs use byte - 0x30 -> ASCII for the known letter/space/punct range.
  ## Unknown glyphs >= 0x20 become [g:XX].
  ## Controls < 0x20 become tags ([end]/[prompt]/[callN:XX]/[cc18:XX]/[ctl:XX]) and consume operands.
  var pos = offset
  var resultStr = ""
  const MaxBytes = 8192
  var safety = 0
  while pos < rom.len and safety < MaxBytes:
    let b = rom[pos]
    let opPos = pos
    inc pos
    inc safety
    if b == 0:
      resultStr.add "[end]"
      break
    if b < ControlThreshold:
      let nOps = controlOperandBytes(rom, opPos)
      var opsStr = ""
      for i in 0 ..< nOps:
        if pos < rom.len:
          opsStr.add &"{rom[pos]:02X}"
          inc pos
        else:
          break
      resultStr.add controlTag(b, opsStr)
      continue
    # printable glyph path (>= 0x20)
    let chVal = int(b) - TextEncodingOffset
    if chVal >= 0x20 and chVal <= 0x7E:
      resultStr.add char(chVal)
    else:
      resultStr.add &"[g:{b:02X}]"
  if safety >= MaxBytes:
    resultStr.add "[truncated]"
  return resultStr


const
  ## Max single 0x00-terminated stream length for residual script claims.
  ScriptStreamMaxLen* = 512
  ## Quality gates for residual script_stream extract claims (structure only).
  ScriptStreamMinGlyphs* = 4
  ScriptStreamMinLen* = 6
  ScriptStreamMinGlyphRatio* = 0.35

type
  ## One terminator-bounded walk result (no decoded text).
  ScriptStreamWalk* = object
    length*: int
    glyphs*: int
    controls*: int
    badGlyphs*: int
    ended*: bool

proc walkScriptStream*(rom: openArray[uint8]; start, limit: int): ScriptStreamWalk =
  ## Walk one CC-aware text stream from start until 0x00 or limit/max.
  ## Uses controlOperandBytes (primary + sub-op extras); no dialogue text.
  result = ScriptStreamWalk()
  var pos = start
  while pos < limit and (pos - start) < ScriptStreamMaxLen:
    let b = rom[pos]
    let opPos = pos
    inc pos
    if b == 0:
      result.ended = true
      result.length = pos - start
      return
    if b < ControlThreshold:
      result.controls += 1
      let nOps = controlOperandBytes(rom, opPos)
      for i in 0 ..< nOps:
        if pos >= limit:
          result.length = pos - start
          return
        inc pos
    else:
      let chVal = int(b) - TextEncodingOffset
      if chVal >= 0x20 and chVal <= 0x7E:
        result.glyphs += 1
      else:
        result.badGlyphs += 1
  result.length = pos - start

proc isGoodScriptStream*(w: ScriptStreamWalk): bool =
  ## True when a walk is a claimable residual text stream (structure gates).
  if not w.ended or w.length < ScriptStreamMinLen:
    return false
  if w.badGlyphs != 0:
    return false
  if w.glyphs < ScriptStreamMinGlyphs:
    return false
  let total = w.glyphs + w.controls
  if total == 0:
    return false
  if w.glyphs.float / total.float < ScriptStreamMinGlyphRatio:
    return false
  result = true

proc consumeScriptStreamRun*(rom: openArray[uint8]; start, length: int): int =
  ## Cover [start, start+length) with consecutive good streams; return consumed.
  ## Returns length on full cover, else the offset reached relative to start.
  let limit = start + length
  var pos = start
  while pos < limit:
    let w = walkScriptStream(rom, pos, limit)
    if not isGoodScriptStream(w):
      return pos - start
    pos += w.length
  result = pos - start
