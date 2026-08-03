; clearWramBlock280C
; Ported from snes_src/clear_wram_block.nim :: clearWramBlock280C (evidence-preserving re-port).
;
; Boot WRAM zero-fill via MVN propagation
; (file 0x000000 / SNES $C00000).
;
; First executable bytes of bank $C0: a short RTS-bounded helper that seeds
; one zero byte then block-moves it forward through a fixed WRAM window.
; ADOPTED into the region registry (adopted.nim); gold-gated by
; tests/test_regions.nim.
;
;
; --- clearWramBlock280C ---
; Zero-fill WRAM `$7E:280C` .. `$7E:2848` via the MVN seed-and-propagate idiom.
;
; Entry (JSR, RTS return): 16-bit A/X/Y (M/X clear). Absolute STZ uses DBR,
; so the caller must have DBR = `$7E` for the seed write to land in WRAM;
; the following MVN also forces DBR to the destination bank `$7E`.
;
; Sequence:
; 1. `STZ $280C` — write the seed zero at the window base.
; 2. `LDX #$280C` / `LDY #$280D` — MVN source = seed, dest = next byte.
; 3. `LDA #$003B` — move A+1 = `$3C` bytes (propagates zero forward).
; 4. `MVN $7E,$7E` — WRAM-to-WRAM block move; DBR becomes `$7E`.
; 5. `LDA #$280C` — leave the window base in A for the caller; `RTS`.
;
; Cleared range: `$7E:280C` through `$7E:2848` inclusive (61 / `$3D` bytes).
;
; Named constants (values inlined below; names preserved as comments):
;   ClearWramBlock280COffset = $00
;   ClearWramBlock280CSnes = $C00000
;   WramClearBase = $280C
;     First byte of the window (absolute under DBR=$7E; also MVN source).
;   WramClearDest = $280D
;     MVN destination start: one past the seed byte so the zero propagates.
;   WramClearMvnCount = $3B
;     MVN count register: A = bytes_to_move - 1. Hardware moves A+1 bytes.
;     $003B → $3C (60) bytes copied; plus the STZ seed → $3D (61) bytes total.
;   WramToWramBanks = $7E7E
;     Packed MVN bank pair: low = dest bank $7E, high = src bank $7E.
;     Encodes as MVN $7E,$7E (WRAM-to-WRAM).
;
.a16
.i16
STZ $280C  ; WramClearBase — First byte of the window (absolute under DBR=$7E; also MVN source).
LDX #$280C  ; WramClearBase — First byte of the window (absolute under DBR=$7E; also MVN source).
LDY #$280D  ; WramClearDest — MVN destination start: one past the seed byte so the zero propagates.
LDA #$3B  ; WramClearMvnCount — MVN count register: A = bytes_to_move - 1. Hardware moves A+1 bytes.
MVN $7E,$7E  ; WramToWramBanks — Packed MVN bank pair: low = dest bank $7E, high = src bank $7E.
LDA #$280C  ; WramClearBase — First byte of the window (absolute under DBR=$7E; also MVN source).
RTS
