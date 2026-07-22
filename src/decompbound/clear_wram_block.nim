## Boot WRAM zero-fill via MVN propagation
## (file 0x000000 / SNES $C00000).
##
## First executable bytes of bank $C0: a short RTS-bounded helper that seeds
## one zero byte then block-moves it forward through a fixed WRAM window.
## ADOPTED into the region registry (adopted.nim); gold-gated by
## tests/test_regions.nim.

import
  ./snes_asm

const
  ClearWramBlock280COffset* = 0x000000
  ClearWramBlock280CSnes* = 0xC00000'u32
  ## First byte of the window (absolute under DBR=$7E; also MVN source).
  WramClearBase* = 0x280C'u32
  ## MVN destination start: one past the seed byte so the zero propagates.
  WramClearDest* = 0x280D'u32
  ## MVN count register: A = bytes_to_move - 1. Hardware moves A+1 bytes.
  ## $003B → $3C (60) bytes copied; plus the STZ seed → $3D (61) bytes total.
  WramClearMvnCount* = 0x003B'u32
  ## Packed MVN bank pair: low = dest bank $7E, high = src bank $7E.
  ## Encodes as MVN $7E,$7E (WRAM-to-WRAM).
  WramToWramBanks* = 0x7E7E'u32
  ## Inclusive end of the cleared window: $280C + $3C = $2848.
  ## Range: $7E:280C .. $7E:2848 ($3D bytes).

proc clearWramBlock280C*(): seq[uint8] =
  ## Zero-fill WRAM `$7E:280C` .. `$7E:2848` via the MVN seed-and-propagate idiom.
  ##
  ## Entry (JSR, RTS return): 16-bit A/X/Y (M/X clear). Absolute STZ uses DBR,
  ## so the caller must have DBR = `$7E` for the seed write to land in WRAM;
  ## the following MVN also forces DBR to the destination bank `$7E`.
  ##
  ## Sequence:
  ## 1. `STZ $280C` — write the seed zero at the window base.
  ## 2. `LDX #$280C` / `LDY #$280D` — MVN source = seed, dest = next byte.
  ## 3. `LDA #$003B` — move A+1 = `$3C` bytes (propagates zero forward).
  ## 4. `MVN $7E,$7E` — WRAM-to-WRAM block move; DBR becomes `$7E`.
  ## 5. `LDA #$280C` — leave the window base in A for the caller; `RTS`.
  ##
  ## Cleared range: `$7E:280C` through `$7E:2848` inclusive (61 / `$3D` bytes).
  snesAsm(ClearWramBlock280CSnes, NativeFlags16):
    stz abs WramClearBase
    ldx WramClearBase
    ldy WramClearDest
    lda WramClearMvnCount
    mvn WramToWramBanks
    lda WramClearBase
    rts
