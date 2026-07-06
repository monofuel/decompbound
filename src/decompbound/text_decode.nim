## EarthBound dialogue text decoder.
## Reverse-engineered from verified findings in docs/scripts.md.
## Encodes storage as byte = ASCII + 0x30 for printable glyphs.
## Controls < 0x20 dispatch at file 0x1890E (CMP #$0020).
## 0x15/0x16/0x17 perform calls via the far-ptr tables.
## Never produces committed dialogue output; used only at runtime on user ROM.

import
  std/[strformat, strutils]

const
  # Verified text encoding per docs/scripts.md
  TextEncodingOffset = 0x30
  # Text block dispatch threshold (CMP #$0020 at file 0x1890E)
  ControlThreshold = 0x20
  # Primary dialogue pointer table (id*4 -> 24-bit far ptr)
  # TODO: magic byte from scripts.md verified location at file 0x8CDED (SNES $C8CDED); parallel tables ~0x8D1ED/~0x8D5ED
  DialoguePtrTable0* = 0x8CDED
  DialoguePtrTable1* = 0x8D1ED
  DialoguePtrTable2* = 0x8D5ED

# Operand counts for controls (number of extra bytes after the control byte in stream).
# TODO: widths determined incrementally from dispatch analysis + verify block requirements (0x63040 needs 0x02:1);
# full set requires live interpreter hook per scripts.md. Observed controls: 0x00-0x1C.
const
  ControlOperandCounts: array[0x20, int] = [
    0, # 00: terminator
    0, # 01
    1, # 02: consumes 1 (required for 0x63040 verify to strip leading operand byte before "INPUT...")
    0, # 03
    0, # 04
    0, # 05
    0, # 06
    0, # 07
    0, # 08
    0, # 09
    0, # 0A
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
    2, # 15: call other text via table 0
    2, # 16: call other text via table 1
    2, # 17: call other text via table 2
    0, # 18
    0, # 19
    0, # 1A
    0, # 1B
    0, # 1C
    0, # 1D
    0, # 1E
    0, # 1F
  ]

proc farPtrToFileOffset*(bank: uint8, physAddr: uint16): int =
  ## Convert a 24-bit SNES far pointer (bank:physAddr) as stored in pointer tables to a file offset in the ROM image.
  ## Mapping derived from table base at 0x8CDED pointing inside C8 bank.
  ((bank and 0x3f).int shl 16) or physAddr.int

proc resolveDialogueBlock*(rom: openArray[uint8], id: int): int =
  ## Resolve a dialogue block id via the 0x8CDED far-pointer table (id -> far ptr -> file offset).
  ## Returns the file offset of the block start, or -1 if out of range.
  let entryOff = DialoguePtrTable0 + id * 4
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

proc decodeText*(rom: openArray[uint8], offset: int): string =
  ## Decode an EB dialogue byte stream at file offset to a readable tagged string.
  ## Printable glyphs use byte - 0x30 -> ASCII for the known letter/space/punct range.
  ## Unknown glyphs >= 0x20 become [g:XX].
  ## Controls < 0x20 become [end] / [call:XX] / [ctl:XX] and consume their documented operands.
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
      if b in [0x15'u8, 0x16, 0x17]:
        # call via far-ptr table; consume 2-byte operand (typically table id)
        var operand: uint16 = 0
        if pos < rom.len:
          operand = rom[pos].uint16
          inc pos
        if pos < rom.len:
          operand = operand or (rom[pos].uint16 shl 8)
          inc pos
        resultStr.add &"[call:{b:02X}:{operand:04X}]"
      else:
        let nOps = if b.int < ControlOperandCounts.len: ControlOperandCounts[b] else: 0
        var opsStr = ""
        for i in 0 ..< nOps:
          if pos < rom.len:
            opsStr.add &"{rom[pos]:02X}"
            inc pos
          else:
            break
        if opsStr.len > 0:
          resultStr.add &"[ctl:{b:02X}:{opsStr}]"
        else:
          resultStr.add &"[ctl:{b:02X}]"
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
