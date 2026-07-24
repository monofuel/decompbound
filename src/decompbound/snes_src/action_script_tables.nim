## Entity action-script VM dispatch tables (bank $C0).
##
## Reverse-engineered structure (docs/scripts.md): low path `$C09558` is 77
## little-endian code pointers (`X = opcode * 2`); high path `$C095E2` overlays
## the last 8 low-path words. Companion tables `$C08C65`, `$C0A1AE`, `$C0A350`
## are additional static jump tables already used as convert_all seeds.
##
## Declared as project data (like header/vectors): pointers into our decompiled
## code, not copyrighted script *content*. Gold-gated via the region registry.

const
  ActionScriptDispatchOffset* = 0x009558
  ActionScriptDispatchSnes* = 0xC09558'u32
  ## 77 entries × 2 bytes (opcodes 0x00–0x4C low path).
  ActionScriptDispatchLen* = 154

  JmpTable8C65Offset* = 0x008C65
  JmpTable8C65Len* = 8

  JmpTableA1AEOffset* = 0x00A1AE
  ## Four word+pad pairs (8 words) = 32 bytes.
  JmpTableA1AELen* = 32

  JmpTableA350Offset* = 0x00A350
  ## Eight code pointers.
  JmpTableA350Len* = 16

proc wordsToLeBytes(words: openArray[uint16]): seq[uint8] =
  ## Pack little-endian 16-bit words into a byte sequence.
  result = newSeq[uint8](words.len * 2)
  for i, w in words:
    result[i * 2] = uint8(w and 0xff)
    result[i * 2 + 1] = uint8(w shr 8)

proc actionScriptDispatchTable*(): seq[uint8] =
  ## Emit the 77-entry action-script low-path dispatch table at file 0x9558.
  ## Targets verified against gold (same list as resolved_entries seeds).
  const words: array[77, uint16] = [
    0x95F2'u16, 0x9603, 0x9627, 0x964D, 0x9685, 0x96AA, 0x96C3, 0x99DD,
    0x9A1A, 0x9A2E, 0x995D, 0x996B, 0x99C3, 0x9A9F, 0x9AE2, 0x9B09,
    0x9979, 0x999E, 0x9B0F, 0x9A0E, 0x9A87, 0x9B1F, 0x9B2C, 0x9B44,
    0x9A5C, 0x9649, 0x9658, 0x966F, 0x9B4D, 0x9B61, 0x9B6B, 0x9B79,
    0x9B91, 0x9BB4, 0x9BE4, 0x9BEE, 0x9620, 0x9BF8, 0x9BCC, 0x9A97,
    0x96E3, 0x96F3, 0x9703, 0x98A0, 0x98AE, 0x98BC, 0x976D, 0x9792,
    0x97B7, 0x97DC, 0x97EF, 0x9802, 0x9826, 0x984A, 0x9875, 0x98CA,
    0x98DE, 0x98F2, 0x991C, 0x96CF, 0x9A38, 0x9A3E, 0x9A44, 0x9713,
    0x9731, 0x974F, 0x993D, 0x9931, 0x9BA9, 0x96CF, 0x9A38, 0x9A3E,
    0x9A44, 0x9713, 0x9731, 0x974F, 0x993D
  ]
  result = wordsToLeBytes(words)

proc jmpTable8C65*(): seq[uint8] =
  ## Emit the 4-entry jump table at file 0x8C65.
  const words: array[4, uint16] = [0x8C6D'u16, 0x8C87, 0x8CA1, 0x8CBB]
  result = wordsToLeBytes(words)

proc jmpTableA1AE*(): seq[uint8] =
  ## Emit the stride-4 word+pad table at file 0xA1AE (32 bytes).
  const words: array[16, uint16] = [
    0xA1D4'u16, 0x0000, 0xA1D2, 0x0000, 0xA1D0, 0x0000, 0xA1CE, 0x0000,
    0xA1D4, 0x0000, 0xA1D2, 0x0000, 0xA1D0, 0x0000, 0xA1CE, 0x0000
  ]
  result = wordsToLeBytes(words)

proc jmpTableA350*(): seq[uint8] =
  ## Emit the 8-entry jump table at file 0xA350.
  const words: array[8, uint16] = [
    0xA2B7'u16, 0xA317, 0xA2E1, 0xA317, 0xA2B7, 0xA317, 0xA2E1, 0xA317
  ]
  result = wordsToLeBytes(words)
