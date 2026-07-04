## Canonical mapping between SNES HiROM addresses and ROM file offsets.
## Code thinks in SNES addresses (JML $C08000); tools think in file offsets
## (0x8000). This module is the single place that converts between them.
##
## Earthbound is a 3MB HiROM cart. HiROM maps the ROM linearly into banks
## $C0-$FF, with mirrors in $40-$7D and in the upper halves ($8000-$FFFF)
## of banks $00-$3F and $80-$BF.

const
  RomBankBase* = 0xC00000'u32  ## Canonical ROM bank window start.

proc snesToFile*(snesAddr: uint32): int =
  ## Convert a SNES address to a ROM file offset.
  ## Returns -1 for addresses that do not map to ROM (WRAM, MMIO, ...).
  let bank = (snesAddr shr 16) and 0xFF
  let offset = snesAddr and 0xFFFF
  if bank >= 0xC0:
    result = ((bank - 0xC0) shl 16 or offset).int
  elif bank >= 0x40 and bank <= 0x7D:
    result = ((bank and 0x3F) shl 16 or offset).int
  elif bank == 0x7E or bank == 0x7F:
    # WRAM banks, never ROM.
    result = -1
  elif offset >= 0x8000:
    # Banks $00-$3F and $80-$BF: upper halves mirror the ROM.
    result = ((bank and 0x3F) shl 16 or offset).int
  else:
    result = -1

proc fileToSnes*(fileOffset: int): uint32 =
  ## Convert a ROM file offset to its canonical SNES address (bank $C0+).
  RomBankBase + fileOffset.uint32
