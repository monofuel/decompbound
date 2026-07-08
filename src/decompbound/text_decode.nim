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
# Verified from dispatch/handlers where noted; prefixes (0x18/0x1C) consume a
# 1-byte sub-op as a first-order model — secondary $1E collectors may take more.
# TODO: complete per-sub-op widths via live interpreter hook (docs/scripts.md).
const
  ControlOperandCounts: array[0x20, int] = [
    0, # 00: end (also special-cased as zero-byte in the fetch loop)
    0, # 01: line / window helper (JSR $04B5); no stream operands
    0, # 02: prompt/suspend (RTL out of interpreter at $C18B0A); no stream ops
    0, # 03
    0, # 04
    0, # 05
    0, # 06
    0, # 07
    0, # 08
    0, # 09
    0, # 0A: sets $1E collector (can gather further bytes — TODO)
    0, # 0B
    0, # 0C
    0, # 0D
    0, # 0E
    0, # 0F
    0, # 10
    0, # 11
    0, # 12
    0, # 13
    0, # 14
    1, # 15: call table0[index] — 1-byte index (AND #$00FF; INC once @ 0x18837)
    1, # 16: call table1[index]
    1, # 17: call table2[index]
    1, # 18: multi-byte CC prefix; next byte is sub-op ($1E=$790B @ 0x18AC4)
    0, # 19
    0, # 1A
    0, # 1B
    1, # 1C: multi-byte CC prefix; next byte is sub-op ($1E=$7D94 @ 0x18AE4)
    0, # 1D
    0, # 1E
    0, # 1F
  ]

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
    inc pos
    inc safety
    if b == 0:
      resultStr.add "[end]"
      break
    if b < ControlThreshold:
      let nOps = if b.int < ControlOperandCounts.len: ControlOperandCounts[b] else: 0
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
